local dfpwm = require("cc.audio.dfpwm")

local Player = {}
Player.__index = Player

local DFPWM_READ_SIZE = 4 * 1024
local PCM_CHUNK_SIZE = 128 * 1024
local PLAYBACK_COMPLETION_BARRIER = { 0 }
local INTERRUPT_EVENT = "railway_player_interrupt"
local SHARED_LOCK_HEARTBEAT_SECONDS = 0.1

-- function: Check whether a playback item is an explicit pause directive.
local function isPause(item)
    return type(item) == "table" and item.kind == "pause"
end

-- function: Return the audio path represented by one composed playback item.
local function audioPath(item)
    if type(item) == "string" then
        return item
    end

    if type(item) == "table" and item.kind == "audio" then
        return item.path
    end

    return nil
end

-- function: Create an audio player for the connected speakers.
function Player.new(speakers, logger, guidanceOptions)
    guidanceOptions = type(guidanceOptions) == "table" and guidanceOptions or {}

    return setmetatable({
        speakers = speakers,
        logger = logger,
        currentPriority = nil,
        interruptRequested = false,
        playbackAcquired = false,
        guidancePlaybackActive = false,
        guidancePath = type(guidanceOptions.path) == "string" and guidanceOptions.path or nil,
        guidancePriority = tonumber(guidanceOptions.priority),
    }, Player)
end

-- function: Check whether an audio path points to a playable file.
function Player:_validFile(path)
    return type(path) == "string"
        and path ~= ""
        and fs.exists(path)
        and not fs.isDir(path)
end

-- function: Return whether this exact playback request is the configured guidance bell.
function Player:_isGuidancePlayback(segments, priority)
    if not self.guidancePath or self.guidancePriority == nil then
        return false
    end

    if tonumber(priority) ~= self.guidancePriority or #segments ~= 1 then
        return false
    end

    return audioPath(segments[1]) == self.guidancePath
end

-- function: Return whether the local computer currently owns shared guidance-bell playback.
function Player:_mayPlayGuidance()
    if not self.speakers.sharedNetworkReady then
        return true
    end

    return self.speakers.guidanceOwnerReady == true
        and tonumber(self.speakers.guidanceOwnerId) == os.getComputerID()
end

-- function: Interrupt the current announcement when a higher-priority request arrives.
function Player:interruptBelow(priority)
    priority = tonumber(priority) or 0

    if self.currentPriority == nil or priority <= self.currentPriority then
        return false
    end

    if self.interruptRequested then
        return true
    end

    self.interruptRequested = true

    -- A request waiting for another computer's shared-speaker lock must never
    -- stop that other computer's playback. Guidance does not hold FCFS, so its
    -- elected owner must still stop its local speaker stream when yielding.
    if self.playbackAcquired or self.guidancePlaybackActive then
        self.speakers:stop()
    end
    os.queueEvent(INTERRUPT_EVENT)

    if self.logger then
        self.logger.info(("Playback interrupted: %s -> %s"):format(
            tostring(self.currentPriority),
            tostring(priority)
        ))
    end

    return true
end

-- function: Decode adjacent DFPWM files into one continuous PCM stream and play it without file-boundary waits.
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

-- function: Decode and play one DFPWM audio file with interrupt support.
function Player:playFile(path, onAudioStarted)
    return self:_playAudioRun({ path }, onAudioStarted)
end

-- function: Wait for a pattern pause while remaining responsive to announcement interrupts.
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

-- function: Run the actual audio after any required shared-speaker arbitration.
function Player:_playAcquiredSegments(segments, onAudioStarted)
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

-- function: Play the elected guidance bell without entering normal-announcement FCFS.
function Player:_playGuidance(segments, onAudioStarted)
    if not self:_mayPlayGuidance() then
        return false
    end

    self.guidancePlaybackActive = true
    local completed = self:_playAcquiredSegments(segments, onAudioStarted)
    self.guidancePlaybackActive = false
    return completed
end

-- function: Play an ordered list of audio and pause items at one announcement priority.
function Player:playSegments(segments, priority, onAudioStarted, announcementType)
    self.currentPriority = tonumber(priority) or 0
    self.interruptRequested = false
    self.playbackAcquired = false
    self.guidancePlaybackActive = false

    local isGuidance = self:_isGuidancePlayback(segments, self.currentPriority)
    if isGuidance then
        -- Guidance ownership is separate from normal FCFS. Only the elected
        -- owner plays it, and shared guidance coordination may interrupt it.
        local completed = self:_playGuidance(segments, onAudioStarted)
        self.guidancePlaybackActive = false
        self.currentPriority = nil
        self.interruptRequested = false
        return completed
    end

    local acquired = self.speakers:acquirePlayback(
        INTERRUPT_EVENT,
        announcementType,
        self.currentPriority
    )
    if not acquired or self.interruptRequested then
        self.currentPriority = nil
        self.interruptRequested = false
        self.playbackAcquired = false
        return false
    end

    self.playbackAcquired = true

    local completed = false
    local function playback()
        completed = self:_playAcquiredSegments(segments, onAudioStarted)
    end

    if self.speakers.sharedNetworkReady then
        -- Keep announcing ownership even when decoding, pausing, or waiting for
        -- the speaker buffer, so a late-arriving computer cannot mistake silence
        -- on the lock protocol for an idle speaker set.
        parallel.waitForAny(
            playback,
            function()
                while true do
                    self.speakers:renewPlayback()
                    sleep(SHARED_LOCK_HEARTBEAT_SECONDS)
                end
            end
        )
    else
        playback()
    end

    self.speakers:releasePlayback()
    self.playbackAcquired = false
    self.currentPriority = nil
    self.interruptRequested = false

    return completed
end

return Player
