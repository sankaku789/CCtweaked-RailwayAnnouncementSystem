local Speakers = {}
Speakers.__index = Speakers

local DRAIN_EVENT = "railway_speaker_drain_complete"

-- function: Discover all currently attached speaker peripherals.
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

-- function: Wait for and connect to one or more speaker peripherals.
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

-- function: Stop audio playback on every connected speaker.
function Speakers:stop()
    for _, device in ipairs(self.devices) do
        device.peripheral.stop()
    end
end

-- function: Drain already-queued speaker events before starting a clean playback boundary.
function Speakers:drainEvents()
    sleep(0)
    os.queueEvent(DRAIN_EVENT)

    while true do
        local event = os.pullEvent()
        if event == DRAIN_EVENT then
            return
        end
    end
end

-- function: Wait until every speaker has emptied its current audio buffer or playback is interrupted.
function Speakers:waitUntilAllReady(interruptEventName)
    local pending = {}
    local count = 0

    for _, device in ipairs(self.devices) do
        pending[device.name] = true
        count = count + 1
    end

    while count > 0 do
        local event, name = os.pullEvent()

        if interruptEventName and event == interruptEventName then
            return false
        end

        if event == "speaker_audio_empty" and pending[name] then
            pending[name] = nil
            count = count - 1
        end
    end

    return true
end

-- function: Submit one prepared PCM chunk without creating an artificial playback boundary.
function Speakers:playChunk(audio, interruptEventName)
    while true do
        local acceptedCount = 0
        local retry = false

        for _, device in ipairs(self.devices) do
            if device.peripheral.playAudio(audio, self.volume) then
                acceptedCount = acceptedCount + 1
            else
                if acceptedCount > 0 then
                    self:stop()
                    self:drainEvents()
                    error("Speaker buffers lost synchronization during continuous playback")
                end

                local ready = self:waitUntilAllReady(interruptEventName)
                if not ready then
                    return false
                end

                retry = true
                break
            end
        end

        if acceptedCount == #self.devices then
            return true
        end

        if not retry then
            error("Failed to enqueue audio chunk to all speakers")
        end
    end
end

return Speakers
