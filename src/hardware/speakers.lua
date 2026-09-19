local Speakers = {}
Speakers.__index = Speakers

local DRAIN_EVENT = "railway_speaker_drain_complete"

-- function: Discover all currently attached speaker peripherals.
local function discover()
    local wrapped = { peripheral.find("speaker") }
    local result = {}

    for _, speaker in ipairs(wrapped) do
        local ok, name = pcall(peripheral.getName, speaker)
        if ok and name then
            result[#result + 1] = {
                name = name,
                peripheral = speaker,
            }
        end
    end

    return result
end

-- function: Return whether one peripheral name belongs to the current speaker set.
function Speakers:_hasDevice(name)
    for _, device in ipairs(self.devices) do
        if device.name == name then
            return true
        end
    end

    return false
end

-- function: Wait until at least one speaker is available and replace the active speaker set.
function Speakers:_waitForDevices(reason)
    if reason and self.logger then
        self.logger.warn(reason)
    end

    local warned = false
    while true do
        local devices = discover()
        if #devices > 0 then
            self.devices = devices
            self.needsReconnect = false

            if self.logger then
                self.logger.info(("Connected %d speaker(s)."):format(#devices))
            end

            return
        end

        if not warned and self.logger then
            self.logger.warn("No speaker found. Retrying...")
            warned = true
        end

        sleep(self.reconnectDelay)
    end
end

-- function: Re-discover speakers after a peripheral connection failure.
function Speakers:_reconnect(reason)
    self:_waitForDevices(reason or "Speaker connection lost. Reconnecting...")
end

-- function: Create and connect a speaker group with automatic re-discovery support.
function Speakers.connect(options, logger)
    options = options or {}

    local reconnectDelay = tonumber(options.reconnectDelay) or 1
    if reconnectDelay < 0 then
        reconnectDelay = 0
    end

    local self = setmetatable({
        devices = {},
        volume = options.volume or 3,
        reconnectDelay = reconnectDelay,
        logger = logger,
        needsReconnect = false,
    }, Speakers)

    self:_waitForDevices()
    return self
end

-- function: Stop audio playback on every connected speaker without failing on detached peripherals.
function Speakers:stop()
    local failed = false

    for _, device in ipairs(self.devices) do
        local ok, err = pcall(device.peripheral.stop)
        if not ok then
            failed = true
            if self.logger then
                self.logger.warn(("Speaker stop failed (%s): %s"):format(
                    tostring(device.name),
                    tostring(err)
                ))
            end
        end
    end

    if failed then
        self.needsReconnect = true
    end

    return not failed
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

-- function: Wait until every speaker has emptied its current audio buffer or playback must stop.
function Speakers:waitUntilAllReady(interruptEventName)
    if self.needsReconnect then
        self:_reconnect("Speaker connection changed. Reconnecting...")
        return false
    end

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

        if event == "peripheral_detach" and self:_hasDevice(name) then
            self:_reconnect("Speaker detached: " .. tostring(name))
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
    if self.needsReconnect then
        self:_reconnect("Speaker connection changed. Reconnecting...")
    end

    while true do
        local acceptedCount = 0
        local retry = false

        for _, device in ipairs(self.devices) do
            local ok, accepted = pcall(device.peripheral.playAudio, audio, self.volume)
            if not ok then
                if acceptedCount > 0 then
                    self:stop()
                    self:drainEvents()
                end

                self:_reconnect(("Speaker playback failed (%s). Reconnecting..."):format(
                    tostring(device.name)
                ))
                return false
            end

            if accepted then
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
