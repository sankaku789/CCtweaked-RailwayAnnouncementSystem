local dfpwm = require("cc.audio.dfpwm")

local Player = {}
Player.__index = Player

local DFPWM_READ_SIZE = 4 * 1024
local PCM_CHUNK_SIZE = 128 * 1024
local PLAYBACK_COMPLETION_BARRIER = { 0 }
local INTERRUPT_EVENT = "railway_player_interrupt"

local function isPause(item)
    return type(item) == "table" and item.kind == "pause"
end

local function audioPath(item)
    if type(item) == "string" then
        return item
    end
    if type(item) == "table" and item.kind == "audio" then
        return item.path
    end
    return nil
end

-- function: Create an audio player for the server-owned speakers.
function Player.new(speakers, logger)
    return setmetatable({
        speakers = speakers,
        logger = logger,
        currentPriority = nil,
        interruptRequested = false,
    }, Player)
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

function Player:_playAudioRun(paths, onAudioStarted)
    local pcm = {}
    local pcmCount = 0
    local submittedAudio = false

    local function markStarted()
        if onAudioStarted then
            local callback = onAudioStarted
            onAudioStarted = nil
            callback(os.epoch("utc"))
        end
    end

    for _, path in ipairs(paths) do
        if self.interruptRequested then
            return false, "interrupted"
        end

        if not self:_validFile(path) then
            if self.logger then
                self.logger.warn("Audio file was not found: " .. tostring(path))
            end
        else
            local decoder = dfpwm.make_decoder()

            for input in io.lines(path, DFPWM_READ_SIZE) do
                if self.interruptRequested then
                    return false, "interrupted"
                end

                local decoded = decoder(input)
                for sampleIndex = 1, #decoded do
                    pcmCount = pcmCount + 1
                    pcm[pcmCount] = decoded[sampleIndex]

                    if pcmCount == PCM_CHUNK_SIZE then
                        local accepted = self.speakers:playChunk(pcm, INTERRUPT_EVENT)
                        if not accepted or self.interruptRequested then
                            return false, "interrupted"
                        end

                        markStarted()
                        submittedAudio = true
                        pcm = {}
                        pcmCount = 0
                    end
                end
            end
        end
    end

    if pcmCount > 0 then
        local accepted = self.speakers:playChunk(pcm, INTERRUPT_EVENT)
        if not accepted or self.interruptRequested then
            return false, "interrupted"
        end

        markStarted()
        submittedAudio = true
    end

    if submittedAudio then
        local accepted = self.speakers:playChunk(PLAYBACK_COMPLETION_BARRIER, INTERRUPT_EVENT)
        if not accepted or self.interruptRequested then
            return false, "interrupted"
        end
    end

    return true
end

function Player:playFile(path, onAudioStarted)
    return self:_playAudioRun({ path }, onAudioStarted)
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
            local paths = {}

            while index <= #segments and not isPause(segments[index]) do
                local path = audioPath(segments[index])
                if not path then
                    error("unknown playback item kind")
                end
                paths[#paths + 1] = path
                index = index + 1
            end

            local ok, reason = self:_playAudioRun(paths, markPlaybackStarted)
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

    local completed = self:_playSegments(segments, onAudioStarted)

    self.currentPriority = nil
    self.interruptRequested = false
    return completed
end

return Player
