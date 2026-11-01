local dfpwm = require("cc.audio.dfpwm")

local Player = {}
Player.__index = Player

-- One DFPWM byte holds 8 samples and speaker.playAudio accepts 128*1024
-- samples per call, so one read fills exactly one speaker buffer.
local PCM_CHUNK_SIZE = 128 * 1024
local DFPWM_READ_SIZE = PCM_CHUNK_SIZE / 8
local PLAYBACK_COMPLETION_BARRIER = { 0 }
local INTERRUPT_EVENT = "railway_player_interrupt"

-- Defaults for the decoded PCM cache for short, frequently replayed assets.
local DEFAULT_PCM_CACHE_MAX_SAMPLES = 65536
local DEFAULT_PCM_CACHE_MAX_FILE_BYTES = 4 * 1024
local DEFAULT_PCM_CACHE_PROMOTE_AFTER_PLAYS = 2

local function isPause(item)
    return type(item) == "table" and item.kind == "pause"
end

local function audioSource(item)
    if type(item) == "string" then
        return "file", item
    end
    if type(item) == "table" and item.kind == "audio" then
        return "file", item.path
    end
    if type(item) == "table" and item.kind == "dfpwm_chunks" then
        return "chunks", item.chunks
    end
    return nil, nil
end

-- function: Create an audio player for the server-owned speakers.
function Player.new(speakers, logger, options)
    options = type(options) == "table" and options or {}

    return setmetatable({
        speakers = speakers,
        logger = logger,
        currentPriority = nil,
        interruptRequested = false,
        pcmCacheMaxSamples = tonumber(options.pcmCacheMaxSamples)
            or DEFAULT_PCM_CACHE_MAX_SAMPLES,
        pcmCacheMaxFileBytes = tonumber(options.pcmCacheMaxFileBytes)
            or DEFAULT_PCM_CACHE_MAX_FILE_BYTES,
        pcmCachePromoteAfterPlays = tonumber(options.pcmCachePromoteAfterPlays)
            or DEFAULT_PCM_CACHE_PROMOTE_AFTER_PLAYS,
        pcmCache = {},
        pcmCacheSamples = 0,
        pcmCacheTick = 0,
        pcmPlayCounts = {},
    }, Player)
end

-- function: Read attributes for cache validation; nil when fs.attributes is unavailable.
function Player:_fileAttributes(path)
    if type(fs.attributes) ~= "function" then
        return nil
    end

    local ok, attributes = pcall(fs.attributes, path)
    if not ok or type(attributes) ~= "table" then
        return nil
    end

    return attributes
end

function Player:_dropPcmCacheEntry(path)
    local entry = self.pcmCache[path]
    if not entry then
        return
    end

    self.pcmCache[path] = nil
    self.pcmCacheSamples = self.pcmCacheSamples - entry.sampleCount
end

function Player:_evictOldestPcmCacheEntry()
    local oldestPath = nil
    local oldestTick = nil

    for path, entry in pairs(self.pcmCache) do
        if oldestTick == nil or entry.tick < oldestTick then
            oldestPath = path
            oldestTick = entry.tick
        end
    end

    if not oldestPath then
        return false
    end

    self:_dropPcmCacheEntry(oldestPath)
    return true
end

-- function: Keep one decoded small file only after it has been played repeatedly.
function Player:_rememberPcmCache(path, attributes, samples)
    local plays = (self.pcmPlayCounts[path] or 0) + 1
    self.pcmPlayCounts[path] = plays

    if plays < self.pcmCachePromoteAfterPlays then
        return
    end

    local sampleCount = #samples
    if sampleCount == 0 or sampleCount > self.pcmCacheMaxSamples then
        return
    end

    self:_dropPcmCacheEntry(path)
    while self.pcmCacheSamples + sampleCount > self.pcmCacheMaxSamples do
        if not self:_evictOldestPcmCacheEntry() then
            return
        end
    end

    self.pcmCacheTick = self.pcmCacheTick + 1
    self.pcmCache[path] = {
        samples = samples,
        sampleCount = sampleCount,
        size = attributes.size,
        modification = attributes.modification,
        tick = self.pcmCacheTick,
    }
    self.pcmCacheSamples = self.pcmCacheSamples + sampleCount
end

function Player:_validFile(path)
    return type(path) == "string"
        and path ~= ""
        and fs.exists(path)
        and not fs.isDir(path)
end

-- function: Interrupt the current playback unconditionally.
function Player:interrupt()
    if self.currentPriority == nil then
        return false
    end

    if self.interruptRequested then
        return true
    end

    self.interruptRequested = true
    self.speakers:stop()
    os.queueEvent(INTERRUPT_EVENT)
    return true
end

-- function: Interrupt the current playback only when a strictly higher priority arrives.
function Player:interruptBelow(priority)
    priority = tonumber(priority) or 0
    if self.currentPriority == nil or priority <= self.currentPriority then
        return false
    end

    if self.logger then
        self.logger.info(("Playback interrupted: %s -> %s"):format(
            tostring(self.currentPriority),
            tostring(priority)
        ))
    end

    return self:interrupt()
end

function Player:_playAudioRun(items, onAudioStarted)
    local submittedAudio = false

    local function markStarted()
        if onAudioStarted then
            local callback = onAudioStarted
            onAudioStarted = nil
            callback(os.epoch("utc"))
        end
    end

    -- function: Submit one decoded PCM table directly, without copying its samples.
    local function submitDecoded(decoded)
        if type(decoded) ~= "table" or #decoded == 0 then
            return true
        end

        local accepted = self.speakers:playChunk(decoded, INTERRUPT_EVENT)
        if not accepted or self.interruptRequested then
            return false, "interrupted"
        end

        markStarted()
        submittedAudio = true
        return true
    end

    local function playFile(path)
        local attributes = self:_fileAttributes(path)
        local cacheable = attributes ~= nil
            and type(attributes.size) == "number"
            and self.pcmCacheMaxFileBytes > 0
            and attributes.size <= self.pcmCacheMaxFileBytes
            and attributes.size <= DFPWM_READ_SIZE

        local entry = self.pcmCache[path]
        if entry then
            if cacheable
                and entry.size == attributes.size
                and entry.modification == attributes.modification
            then
                self.pcmCacheTick = self.pcmCacheTick + 1
                entry.tick = self.pcmCacheTick
                return submitDecoded(entry.samples)
            end

            self:_dropPcmCacheEntry(path)
        end

        local decoder = dfpwm.make_decoder()
        local cacheCandidate = nil
        local chunkCount = 0

        for input in io.lines(path, DFPWM_READ_SIZE) do
            if self.interruptRequested then
                return false, "interrupted"
            end

            if type(input) == "string" and input ~= "" then
                local decoded = decoder(input)
                local ok, reason = submitDecoded(decoded)
                if not ok then
                    return false, reason
                end

                if cacheable and type(decoded) == "table" and #decoded > 0 then
                    chunkCount = chunkCount + 1
                    cacheCandidate = decoded
                end
            end
        end

        -- A cache entry always holds the single chunk produced by one read.
        if cacheable and chunkCount == 1 then
            self:_rememberPcmCache(path, attributes, cacheCandidate)
        end

        return true
    end

    for _, item in ipairs(items) do
        if self.interruptRequested then
            return false, "interrupted"
        end

        local sourceKind, source = audioSource(item)
        if sourceKind == "file" then
            if not self:_validFile(source) then
                if self.logger then
                    self.logger.warn("Audio file was not found: " .. tostring(source))
                end
            else
                local ok, reason = playFile(source)
                if not ok then
                    return false, reason
                end
            end
        elseif sourceKind == "chunks" then
            if type(source) ~= "table" then
                error("invalid RAM DFPWM chunks")
            end

            local decoder = dfpwm.make_decoder()
            for _, input in ipairs(source) do
                if self.interruptRequested then
                    return false, "interrupted"
                end

                if type(input) == "string" and input ~= "" then
                    local ok, reason = submitDecoded(decoder(input))
                    if not ok then
                        return false, reason
                    end
                end
            end
        else
            error("unknown playback item kind")
        end
    end

    if submittedAudio then
        local accepted = self.speakers:playChunk(PLAYBACK_COMPLETION_BARRIER, INTERRUPT_EVENT)
        if not accepted or self.interruptRequested then
            return false, "interrupted"
        end
    end

    return true
end

function Player:_waitPause(seconds)
    if self.interruptRequested then
        return false, "interrupted"
    end

    seconds = tonumber(seconds) or 0
    if seconds <= 0 then
        return true
    end

    local timerId = os.startTimer(seconds)
    while true do
        local event, value = os.pullEvent()

        if event == INTERRUPT_EVENT then
            if type(os.cancelTimer) == "function" then
                os.cancelTimer(timerId)
            end
            return false, "interrupted"
        end

        if event == "timer" and value == timerId then
            return true
        end
    end
end

function Player:_playSegments(segments, onAudioStarted)
    local startedCallback = onAudioStarted
    local started = false

    local function markPlaybackStarted(epoch)
        if started then
            return
        end
        started = true

        if startedCallback then
            local callback = startedCallback
            startedCallback = nil
            callback(tonumber(epoch) or os.epoch("utc"))
        end
    end

    local completed = true
    local index = 1

    while index <= #segments do
        local item = segments[index]

        if isPause(item) then
            local ok, reason = self:_waitPause(item.seconds)
            if not ok and reason == "interrupted" then
                completed = false
                break
            end
            index = index + 1
        else
            local audioItems = {}

            while index <= #segments and not isPause(segments[index]) do
                local sourceKind = audioSource(segments[index])
                if not sourceKind then
                    error("unknown playback item kind")
                end
                audioItems[#audioItems + 1] = segments[index]
                index = index + 1
            end

            local ok, reason = self:_playAudioRun(audioItems, markPlaybackStarted)
            if not ok and reason == "interrupted" then
                completed = false
                break
            end
        end
    end

    if self.interruptRequested or not completed then
        self.speakers:stop()
        self.speakers:drainEvents()
        return false
    end

    return self.speakers:finishPlayback(INTERRUPT_EVENT)
end

-- function: Play one complete server-selected request without distributed locking.
function Player:playSegments(segments, priority, onAudioStarted)
    self.currentPriority = tonumber(priority) or 0
    self.interruptRequested = false

    if type(self.speakers.preparePlayback) == "function" then
        self.speakers:preparePlayback()
    end

    local completed = self:_playSegments(segments, onAudioStarted)

    self.currentPriority = nil
    self.interruptRequested = false
    return completed
end

return Player
