local Speakers = {}
Speakers.__index = Speakers

local DRAIN_EVENT = "railway_speaker_drain_complete"
local MAX_SPEAKER_RESYNC_ATTEMPTS = 5
local SPEAKER_READY_TIMEOUT_SECONDS = 10

local function configuredNames(options)
    if type(options.peripherals) ~= "table" then
        return nil
    end

    local lookup = {}
    for _, name in ipairs(options.peripherals) do
        if type(name) == "string" and name ~= "" then
            lookup[name] = true
        end
    end

    if next(lookup) == nil then
        return nil
    end
    return lookup
end

local function discover(allowedNames)
    local wrapped = { peripheral.find("speaker") }
    local result = {}

    for _, speaker in ipairs(wrapped) do
        local ok, name = pcall(peripheral.getName, speaker)
        if ok and name and (allowedNames == nil or allowedNames[name]) then
            result[#result + 1] = {
                name = name,
                peripheral = speaker,
            }
        end
    end

    return result
end

local function playbackDevices(self)
    if type(self.degradedPlaybackDevices) == "table" and #self.degradedPlaybackDevices > 0 then
        return self.degradedPlaybackDevices
    end
    return self.devices
end

local function hasPlaybackDevice(devices, name)
    for _, device in ipairs(devices or {}) do
        if device.name == name then
            return true
        end
    end
    return false
end

local function cancelTimer(timerId)
    if timerId and type(os.cancelTimer) == "function" then
        pcall(os.cancelTimer, timerId)
    end
end

-- function: Refresh wrapped speaker peripherals from the current attachment state.
function Speakers:_refreshDevices()
    local devices = discover(self.allowedNames)
    if #devices == 0 then
        return false
    end

    self.devices = devices
    self.needsReconnect = false
    self.degradedPlaybackDevices = nil
    return true
end

function Speakers:_waitForDevices(reason)
    if reason and self.logger then
        self.logger.warn(reason)
    end

    local warned = false
    while true do
        if self:_refreshDevices() then
            if self.logger then
                self.logger.info(("Connected %d speaker(s)."):format(#self.devices))
            end
            return
        end

        if not warned and self.logger then
            self.logger.warn(self.allowedNames
                and "No configured speaker found. Retrying..."
                or "No speaker found. Retrying...")
            warned = true
        end

        sleep(self.reconnectDelay)
    end
end

function Speakers:_reconnect(reason)
    self:_waitForDevices(reason or "Speaker connection lost. Reconnecting...")
end

-- function: Create and connect the physical speaker set owned by the server.
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
        audioOutstanding = false,
        degradedPlaybackDevices = nil,
        allowedNames = configuredNames(options),
    }, Speakers)

    self:_waitForDevices()
    return self
end

function Speakers:_stopDevices(devices)
    local failed = false

    for _, device in ipairs(devices or {}) do
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

    self.audioOutstanding = false
    if failed then
        self.needsReconnect = true
    end
    return not failed
end

function Speakers:stop()
    local stopped = self:_stopDevices(self.devices)
    self.degradedPlaybackDevices = nil
    return stopped
end

function Speakers:drainEvents()
    sleep(0)
    os.queueEvent(DRAIN_EVENT)

    while true do
        if os.pullEvent() == DRAIN_EVENT then
            return
        end
    end
end

-- function: Clear stale speaker events and refresh wrappers before a new announcement starts.
function Speakers:preparePlayback()
    self.audioOutstanding = false
    self.degradedPlaybackDevices = nil
    self:drainEvents()

    if not self:_refreshDevices() then
        self:_reconnect("Speaker unavailable before playback. Reconnecting...")
    end
end

function Speakers:waitUntilAllReady(interruptEventName)
    if self.needsReconnect then
        self:_reconnect("Speaker connection changed. Reconnecting...")
        return false
    end

    local devices = playbackDevices(self)
    local pending = {}
    local count = 0

    for _, device in ipairs(devices) do
        pending[device.name] = true
        count = count + 1
    end

    local readyTimer = type(os.startTimer) == "function"
        and os.startTimer(SPEAKER_READY_TIMEOUT_SECONDS)
        or nil

    while count > 0 do
        local event, name = os.pullEvent()

        if interruptEventName and event == interruptEventName then
            cancelTimer(readyTimer)
            return false
        end

        if readyTimer and event == "timer" and name == readyTimer then
            self.needsReconnect = true
            self.audioOutstanding = false
            self:_reconnect("Speaker audio-ready timeout. Reconnecting...")
            self.degradedPlaybackDevices = nil
            return false
        end

        if event == "peripheral_detach" and hasPlaybackDevice(devices, name) then
            cancelTimer(readyTimer)
            self.needsReconnect = true
            self.audioOutstanding = false
            self:_reconnect("Speaker detached: " .. tostring(name))
            self.degradedPlaybackDevices = nil
            return false
        end

        if event == "speaker_audio_empty" and pending[name] then
            pending[name] = nil
            count = count - 1
        end
    end

    cancelTimer(readyTimer)
    self.audioOutstanding = false
    return true
end

function Speakers:finishPlayback(interruptEventName)
    if not self.audioOutstanding then
        self.degradedPlaybackDevices = nil
        return true
    end

    local finished = self:waitUntilAllReady(interruptEventName)
    self.degradedPlaybackDevices = nil
    return finished
end

-- function: Submit one PCM chunk, preserving multi-speaker resync/degraded behavior.
function Speakers:playChunk(audio, interruptEventName)
    if self.needsReconnect then
        self:_reconnect("Speaker connection changed. Reconnecting...")
        self.degradedPlaybackDevices = nil
    end

    local resyncAttempts = 0

    while true do
        local devices = playbackDevices(self)
        local acceptedDevices = {}
        local acceptedCount = 0
        local rejectedCount = 0
        local playbackError = nil

        for _, device in ipairs(devices) do
            local ok, accepted = pcall(device.peripheral.playAudio, audio, self.volume)
            if not ok then
                playbackError = ("Speaker playback failed (%s): %s"):format(
                    tostring(device.name),
                    tostring(accepted)
                )
                break
            end

            if accepted then
                acceptedCount = acceptedCount + 1
                acceptedDevices[#acceptedDevices + 1] = device
            else
                rejectedCount = rejectedCount + 1
            end
        end

        if playbackError == nil and acceptedCount == #devices then
            self.audioOutstanding = true
            return true
        end

        if playbackError == nil and acceptedCount == 0 then
            if not self:waitUntilAllReady(interruptEventName) then
                return false
            end
        else
            resyncAttempts = resyncAttempts + 1

            if resyncAttempts >= MAX_SPEAKER_RESYNC_ATTEMPTS then
                if acceptedCount > 0 then
                    self.degradedPlaybackDevices = acceptedDevices
                    self.audioOutstanding = true
                    if self.logger then
                        self.logger.warn((
                            "Speaker synchronization unstable; continuing on %d/%d speaker(s)."
                        ):format(acceptedCount, #devices))
                    end
                    return true
                end

                if self.logger then
                    self.logger.warn("Speaker reconnection failed; skipping audio chunk.")
                end
                return false
            end

            if self.logger then
                self.logger.warn(("Speaker resync %d/%d: %s"):format(
                    resyncAttempts,
                    MAX_SPEAKER_RESYNC_ATTEMPTS,
                    playbackError or ("%d accepted, %d busy"):format(
                        acceptedCount,
                        rejectedCount
                    )
                ))
            end

            if acceptedCount > 0 then
                self:_stopDevices(self.devices)
                self:drainEvents()
            end

            self:_reconnect()
            self.degradedPlaybackDevices = nil
        end
    end
end

return Speakers
