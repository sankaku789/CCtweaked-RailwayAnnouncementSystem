local dfpwm = require("cc.audio.dfpwm")

local Player = {}
Player.__index = Player

local DFPWM_READ_SIZE = 4 * 1024
local PCM_CHUNK_SIZE = 128 * 1024
local PCM_SAMPLES_PER_SECOND = 48000
local PLAYBACK_FINISH_MARGIN_SECONDS = 0.05
local INTERRUPT_EVENT = "railway_player_interrupt"

-- function: Return the current UTC epoch time in milliseconds.
local function now()
    return os.epoch("utc")
end

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
function Player.new(speakers, logger)
    return setmetatable({
        speakers = speakers,
        logger = logger,
        currentPriority = nil,
        interruptRequested = false,
    }, Player)
end

-- function: Check whether an audio path points to a playable file.
function Player:_validFile(path)
    return type(path) == "string"
        and path ~= ""
        and fs.exists(path)
        and not fs.isDir(path)
end

-- function: Extend the estimated audible playback deadline after one accepted PCM chunk.
function Player:_extendPlaybackDeadline(deadlineMs, sampleCount)
    local acceptedAt = now()
    local baseMs = deadlineMs

    if baseMs == nil or baseMs < acceptedAt then
        baseMs = acceptedAt
    end

    local durationMs = (math.max(0, tonumber(sampleCount) or 0) / PCM_SAMPLES_PER_SECOND) * 1000
    return baseMs + durationMs
end

-- function: Wait until submitted PCM should have finished audibly while remaining interruptible.
function Player:_waitUntilPlaybackDeadline(deadlineMs)
    if deadlineMs == nil then
        return true
    end

    local finishAt = deadlineMs + (PLAYBACK_FINISH_MARGIN_SECONDS * 1000)

    while true do
        if self.interruptRequested then
            return false, "interrupted"
        end

        local remainingMs = finishAt - now()
        if remainingMs <= 0 then
            return true
        end

        local timerId = os.startTimer(remainingMs / 1000)

        while true do
            local event, value = os.pullEvent()

            if event == INTERRUPT_EVENT then
                if type(os.cancelTimer) == "function" then
                    os.cancelTimer(timerId)
                end
                return false, "interrupted"
            end

            if event == "timer" and value == timerId then
                break
            end
        end
    end
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
    self.speakers:stop()
    os.queueEvent(INTERRUPT_EVENT)

    if self.logger then
        self.logger.info(("Interrupted priority %s announcement for priority %s request."):format(
            tostring(self.currentPriority),
            tostring(priority)
        ))
    end

    return true
end

-- function: Decode adjacent DFPWM files into one continuous PCM stream and play it without file-boundary waits.
function Player:_playAudioRun(paths)
    local pcm = {}
    local pcmCount = 0
    local playbackDeadlineMs = nil

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

                        playbackDeadlineMs = self:_extendPlaybackDeadline(playbackDeadlineMs, pcmCount)
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

        playbackDeadlineMs = self:_extendPlaybackDeadline(playbackDeadlineMs, pcmCount)
    end

    return self:_waitUntilPlaybackDeadline(playbackDeadlineMs)
end

-- function: Decode and play one DFPWM audio file with interrupt support.
function Player:playFile(path)
    return self:_playAudioRun({ path })
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

-- function: Play an ordered list of audio and pause items at one announcement priority.
function Player:playSegments(segments, priority)
    self.currentPriority = tonumber(priority) or 0
    self.interruptRequested = false

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

            local ok, reason = self:_playAudioRun(paths)
            if not ok and reason == "interrupted" then
                completed = false
                break
            end
        end
    end

    if self.interruptRequested or not completed then
        self.speakers:stop()
        self.speakers:drainEvents()
        completed = false
    end

    self.currentPriority = nil
    self.interruptRequested = false

    return completed
end

return Player
