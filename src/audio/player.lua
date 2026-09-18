local dfpwm = require("cc.audio.dfpwm")

local Player = {}
Player.__index = Player

local SAMPLE_RATE = 48000
local DFPWM_READ_SIZE = 4 * 1024
local PCM_CHUNK_SIZE = 128 * 1024
local INTERRUPT_EVENT = "railway_player_interrupt"

-- function: Check whether a playback item is an explicit pause directive.
local function isPause(item)
    return type(item) == "table" and item.kind == "pause"
end

-- function: Check whether a playback item is a two-file overlap directive.
local function isOverlap(item)
    return type(item) == "table" and item.kind == "overlap"
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

-- function: Decode one DFPWM file completely for an overlap operation.
function Player:_decodeFile(path)
    if self.interruptRequested then
        return nil, "interrupted"
    end

    if not self:_validFile(path) then
        if self.logger then
            self.logger.warn("Audio file was not found: " .. tostring(path))
        end
        return nil, "missing"
    end

    local decoder = dfpwm.make_decoder()
    local output = {}
    local outputCount = 0

    for input in io.lines(path, DFPWM_READ_SIZE) do
        if self.interruptRequested then
            return nil, "interrupted"
        end

        local decoded = decoder(input)
        for sampleIndex = 1, #decoded do
            outputCount = outputCount + 1
            output[outputCount] = decoded[sampleIndex]
        end
    end

    return output
end

-- function: Decode adjacent DFPWM files and overlap groups into one continuous PCM stream.
function Player:_playAudioRun(items)
    local pcm = {}
    local pcmCount = 0
    local submittedAudio = false

    -- function: Submit the currently buffered PCM samples to all speakers.
    local function submitBufferedAudio()
        if pcmCount == 0 then
            return true
        end

        local accepted = self.speakers:playChunk(pcm, INTERRUPT_EVENT)
        if not accepted or self.interruptRequested then
            return false
        end

        submittedAudio = true
        pcm = {}
        pcmCount = 0
        return true
    end

    -- function: Append one PCM sample and flush when the speaker chunk limit is reached.
    local function appendSample(sample)
        pcmCount = pcmCount + 1
        pcm[pcmCount] = sample

        if pcmCount == PCM_CHUNK_SIZE then
            return submitBufferedAudio()
        end

        return true
    end

    -- function: Append a range of PCM samples to the continuous output stream.
    local function appendSamples(samples, firstIndex, lastIndex)
        firstIndex = firstIndex or 1
        lastIndex = lastIndex or #samples

        for sampleIndex = firstIndex, lastIndex do
            if self.interruptRequested or not appendSample(samples[sampleIndex]) then
                return false
            end
        end

        return true
    end

    -- function: Decode and append one ordinary DFPWM file without waiting at its boundary.
    local function appendFile(path)
        if self.interruptRequested then
            return false, "interrupted"
        end

        if not self:_validFile(path) then
            if self.logger then
                self.logger.warn("Audio file was not found: " .. tostring(path))
            end
            return true
        end

        local decoder = dfpwm.make_decoder()

        for input in io.lines(path, DFPWM_READ_SIZE) do
            if self.interruptRequested then
                return false, "interrupted"
            end

            local decoded = decoder(input)
            if not appendSamples(decoded) then
                return false, "interrupted"
            end
        end

        return true
    end

    -- function: Decode two DFPWM files and linearly crossfade their boundary by the requested duration.
    local function appendOverlap(item)
        local left, leftReason = self:_decodeFile(item.left)
        if leftReason == "interrupted" then
            return false, "interrupted"
        end

        local right, rightReason = self:_decodeFile(item.right)
        if rightReason == "interrupted" then
            return false, "interrupted"
        end

        if not left and not right then
            return true
        elseif not left then
            return appendSamples(right)
        elseif not right then
            return appendSamples(left)
        end

        local seconds = math.max(tonumber(item.seconds) or 0, 0)
        local overlapSamples = math.floor(seconds * SAMPLE_RATE + 0.5)
        overlapSamples = math.min(overlapSamples, #left, #right)

        if overlapSamples <= 0 then
            return appendSamples(left) and appendSamples(right)
        end

        local leftOverlapStart = #left - overlapSamples + 1
        if not appendSamples(left, 1, leftOverlapStart - 1) then
            return false, "interrupted"
        end

        for overlapIndex = 1, overlapSamples do
            if self.interruptRequested then
                return false, "interrupted"
            end

            local progress
            if overlapSamples == 1 then
                progress = 0.5
            else
                progress = (overlapIndex - 1) / (overlapSamples - 1)
            end

            local leftSample = left[leftOverlapStart + overlapIndex - 1]
            local rightSample = right[overlapIndex]
            local mixed = leftSample * (1 - progress) + rightSample * progress

            if mixed >= 0 then
                mixed = math.floor(mixed + 0.5)
            else
                mixed = math.ceil(mixed - 0.5)
            end

            if not appendSample(mixed) then
                return false, "interrupted"
            end
        end

        if not appendSamples(right, overlapSamples + 1, #right) then
            return false, "interrupted"
        end

        return true
    end

    for _, item in ipairs(items) do
        if self.interruptRequested then
            return false, "interrupted"
        end

        local ok, reason
        if isOverlap(item) then
            ok, reason = appendOverlap(item)
        else
            local path = audioPath(item)
            if not path then
                error("unknown playback item kind")
            end
            ok, reason = appendFile(path)
        end

        if not ok then
            return false, reason or "interrupted"
        end
    end

    if pcmCount > 0 and not submitBufferedAudio() then
        return false, "interrupted"
    end

    if submittedAudio then
        local ready = self.speakers:waitUntilAllReady(INTERRUPT_EVENT)
        if not ready or self.interruptRequested then
            return false, "interrupted"
        end
    end

    return true
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
            local run = {}

            while index <= #segments and not isPause(segments[index]) do
                local current = segments[index]
                if not audioPath(current) and not isOverlap(current) then
                    error("unknown playback item kind")
                end

                run[#run + 1] = current
                index = index + 1
            end

            local ok, reason = self:_playAudioRun(run)
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
