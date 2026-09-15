local Speakers = {}
Speakers.__index = Speakers

local function discover()
    local wrapped = { peripheral.find("speaker") }
    local result = {}

    for _, speaker in ipairs(wrapped) do
        result[#result + 1] = {
            name = peripheral.getName(speaker),
            peripheral = speaker,
        }
    end

    return result
end

function Speakers.connect(options, logger)
    options = options or {}
    local reconnectDelay = options.reconnectDelay or 1

    while true do
        local devices = discover()
        if #devices > 0 then
            if logger then
                logger.info(("Connected %d speaker(s)."):format(#devices))
            end

            return setmetatable({
                devices = devices,
                volume = options.volume or 3,
                logger = logger,
            }, Speakers)
        end

        if logger then
            logger.warn("No speaker found. Retrying...")
        end
        sleep(reconnectDelay)
    end
end

function Speakers:stop()
    for _, device in ipairs(self.devices) do
        device.peripheral.stop()
    end
end

function Speakers:playChunk(audio)
    -- The player calls this only after the previous chunk reached the barrier,
    -- so every speaker should be ready. If a speaker unexpectedly rejects the
    -- chunk, stop all speakers and retry the same chunk from a clean boundary.
    for attempt = 1, 3 do
        local acceptedAll = true

        for _, device in ipairs(self.devices) do
            if not device.peripheral.playAudio(audio, self.volume) then
                acceptedAll = false
                break
            end
        end

        if acceptedAll then
            return true
        end

        if self.logger then
            self.logger.warn(("Speaker buffer was unexpectedly busy; resync attempt %d/3."):format(attempt))
        end

        self:stop()
        sleep(0)
    end

    error("Failed to enqueue audio chunk to all speakers after resync attempts")
end

function Speakers:waitUntilAllReady()
    local pending = {}
    local count = 0

    for _, device in ipairs(self.devices) do
        pending[device.name] = true
        count = count + 1
    end

    while count > 0 do
        local _, name = os.pullEvent("speaker_audio_empty")

        if pending[name] then
            pending[name] = nil
            count = count - 1
        end
    end
end

return Speakers
