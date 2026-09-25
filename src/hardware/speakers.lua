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

local function deviceNames(devices)
    local names = {}
    for _, device in ipairs(devices or {}) do
        names[#names + 1] = tostring(device.name)
    end
    table.sort(names)
    return table.concat(names, ",")
end

local function pendingNames(pending)
    local names = {}
    for name, waiting in pairs(pending or {}) do
        if waiting then
            names[#names + 1] = tostring(name)
        end
    end
    table.sort(names)
    return table.concat(names, ",")
end

local function cancelTimer(timerId)
    if timerId and type(os.cancelTimer) == "function" then
        pcall(os.cancelTimer, timerId)
    end
end

function Speakers:_hasDevice(name)
    return hasPlaybackDevice(self.devices, name)
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
                self.logger.info(("Connected %d speaker(s): %s"):format(
                    #self.devices,
                    deviceNames(self.devices)
                ))
            end
            return
        end

        if not warned and self.logger then
            if self.allowedNames then
                self.logger.warn("No configured speaker found. Retrying...")
            else
                self.logger.warn("No speaker found. Retrying...")
            end
            warned = true
        end

        sleep(self.reconnectDelay)
    end
end

function Speakers:_reconnect(reason)
    self.acceptedThisPlayback = {}
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
        acceptedThisPlayback = {},
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
        local event = os.pullEvent()
        if event == DRAIN_EVENT then
            return
        end
    end
end

-- function: Clear stale speaker events and refresh wrappers before a new announcement starts.
function Speakers:preparePlayback()
    self.audioOutstanding = false
    self.degradedPlaybackDevices = nil
    self.acceptedThisPlayback = {}
    self:drainEvents()

    if not self:_refreshDevices() then
        self:_reconnect("Speaker unavailable before playback. Reconnecting...")
    elseif self.logger then
        self.logger.info(("Speaker playback prepared: %s"):format(deviceNames(self.devices)))
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

    local readyTimer = nil
    if type(os.startTimer) == "function" then
        readyTimer = os.startTimer(SPEAKER_READY_TIMEOUT_SECONDS)
    end

    while count > 0 do
        local event, name = os.pullEvent()

        if interruptEventName and event == interruptEventName then
            cancelTimer(readyTimer)
            if self.logger then
                self.logger.info("Speaker wait interrupted")
            end
            return false
        end

        if readyTimer and event == "timer" and name == readyTimer then
            if self.logger then
                self.logger.warn(("Speaker audio-ready timeout; pending=%s"):format(
                    pendingNames(pending)
                ))
            end
            self.needsReconnect = true
            self.audioOutstanding = false
            self:_reconnect("Speaker audio-ready wait timed out. Reconnecting...")
            self.degradedPlaybackDevices = nil
            return false
        end

        if event == "peripheral_detach" and hasPlaybackDevice(devices, name) then
            cancelTimer(readyTimer)
            if self.logger then
                self.logger.warn("Speaker -> detached: " .. tostring(name))
            end
            self.needsReconnect = true
            self.audioOutstanding = false
            self:_reconnect("Speaker detached: " .. tostring(name))
            self.degradedPlaybackDevices = nil
            return false
        end

        if event == "speaker_audio_empty" and pending[name] then
            pending[name] = nil
            count = count - 1
            if self.logger then
                self.logger.info(("Speaker -> audio_empty: %s pending=%d"):format(
                    tostring(name),
                    count
                ))
            end
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
                if self.logger then
                    self.logger.warn(("Speaker -> error: %s %s"):format(
                        tostring(device.name),
                        tostring(accepted)
                    ))
                end
                break
            end

            if accepted then
                acceptedCount = acceptedCount + 1
                acceptedDevices[#acceptedDevices + 1] = device
                if not self.acceptedThisPlayback[device.name] then
                    self.acceptedThisPlayback[device.name] = true
                    if self.logger then
                        self.logger.info("Speaker -> accepted: " .. tostring(device.name))
                    end
                end
            else
                rejectedCount = rejectedCount + 1
                if self.logger then
                    self.logger.info("Speaker -> busy: " .. tostring(device.name))
                end
            end
        end

        if playbackError == nil and acceptedCount == #devices then
            self.audioOutstanding = true
            return true
        end

        if playbackError == nil and acceptedCount == 0 then
            local ready = self:waitUntilAllReady(interruptEventName)
            if not ready then
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
                            "Speaker synchronization still unstable after %d attempt(s); "
                            .. "continuing this playback on %d/%d speaker(s)."
                        ):format(
                            MAX_SPEAKER_RESYNC_ATTEMPTS,
                            acceptedCount,
                            #devices
                        ))
                    end
                    return true
                end

                if self.logger then
                    self.logger.warn((
                        "Speaker reconnection failed after %d attempt(s); skipping this audio chunk."
                    ):format(MAX_SPEAKER_RESYNC_ATTEMPTS))
                end
                return false
            end

            if self.logger then
                local reason = playbackError or ("buffer mismatch (%d accepted, %d busy)"):format(
                    acceptedCount,
                    rejectedCount
                )
                self.logger.warn((
                    "Speaker synchronization lost: %s. Reconnecting (%d/%d)..."
                ):format(reason, resyncAttempts, MAX_SPEAKER_RESYNC_ATTEMPTS))
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
