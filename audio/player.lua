local dfpwm = require("cc.audio.dfpwm")

local Player = {}
Player.__index = Player

local CHUNK_SIZE = 16 * 1024

function Player.new(speakers, logger)
    return setmetatable({
        speakers = speakers,
        logger = logger,
    }, Player)
end

function Player:_validFile(path)
    return type(path) == "string"
        and path ~= ""
        and fs.exists(path)
        and not fs.isDir(path)
end

function Player:playFile(path)
    if not self:_validFile(path) then
        if self.logger then
            self.logger.warn("Audio file was not found: " .. tostring(path))
        end
        return false
    end

    local decoder = dfpwm.make_decoder()

    for input in io.lines(path, CHUNK_SIZE) do
        local decoded = decoder(input)

        -- All speakers receive the same decoded chunk before any speaker advances.
        self.speakers:playChunk(decoded)
        self.speakers:waitUntilAllReady()
    end

    return true
end

function Player:playSegments(segments)
    for _, path in ipairs(segments) do
        self:playFile(path)
    end
end

return Player
