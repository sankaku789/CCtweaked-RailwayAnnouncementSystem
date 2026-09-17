local dfpwm = require("cc.audio.dfpwm")

local Player = {}
Player.__index = Player

local CHUNK_SIZE = 16 * 1024
local INTERRUPT_EVENT = "railway_player_interrupt"

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

-- function: Decode and play one DFPWM audio file with interrupt support.
function Player:playFile(path)
    if self.interruptRequested then
        return false, "interrupted"
    end

    if not self:_validFile(path) then
        if self.logger then
            self.logger.warn("Audio file was not found: " .. tostring(path))
        end
        return false, "missing"
    end

    local decoder = dfpwm.make_decoder()

    for input in io.lines(path, CHUNK_SIZE) do
        if self.interruptRequested then
            return false, "interrupted"
        end

        local decoded = decoder(input)

        -- All speakers receive the same decoded chunk before any speaker advances.
        self.speakers:playChunk(decoded)

        local ready = self.speakers:waitUntilAllReady(INTERRUPT_EVENT)
        if not ready or self.interruptRequested then
            return false, "interrupted"
        end
    end

    return true
end

-- function: Play an ordered list of audio segment files at one announcement priority.
function Player:playSegments(segments, priority)
    self.currentPriority = tonumber(priority) or 0
    self.interruptRequested = false

    local completed = true

    for _, path in ipairs(segments) do
        local ok, reason = self:playFile(path)
        if not ok and reason == "interrupted" then
            completed = false
            break
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
