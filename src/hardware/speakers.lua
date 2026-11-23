local Speakers = {}
Speakers.__index = Speakers

local DRAIN_EVENT = "railway_speaker_drain_complete"
local MAX_SPEAKER_RESYNC_ATTEMPTS = 5
local SPEAKER_READY_TIMEOUT_SECONDS = 10

-- function: Build a lookup set of configured speaker peripheral names, or nil if unrestricted.
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

-- function: Discover attached speaker peripherals matching the allowed name filter.
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

-- function: Create a shallow copy of a speaker device list.
local function copyDevices(devices)
    local copy = {}
    for index, device in ipairs(devices or {}) do
        copy[index] = device
    end
    return copy
end

-- function: Check whether a named speaker exists in a device list.
local function hasPlaybackDevice(devices, name)
    for _, device in ipairs(devices or {}) do
        if device.name == name then
            return true
        end
    end
    return false
end

-- function: Cancel an active ComputerCraft timer if supported by the runtime.
local function cancelTimer(timerId)
    if timerId and type(os.cancelTimer) == "function" then
        pcall(os.cancelTimer, timerId)
    end
end

-- function: Refresh wrapped speaker peripherals from the current attachment state.
function Speakers:_refreshDevices()
    local devices = discover(self.allowedNames)
    if #devices == 0 then
        self.devices = {}
        self.activeDevices = {}
        self.needsReconnect = true
        self.audioOutstanding = false
        self.pendingEmpty = {}
        return false, false
    end

    local wasDisconnected = self.needsReconnect == true or #self.devices == 0
    self.devices = devices
    self.activeDevices = copyDevices(devices)
    self.needsReconnect = false
    self.warnedUnavailable = false
    return true, wasDisconnected
end

-- function: Block during startup until at least one speaker peripheral is connected.
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

-- function: Reconnect by waiting for at least one speaker peripheral to become available.
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
        activeDevices = {},
        pendingEmpty = {},
        volume = options.volume or 3,
        reconnectDelay = reconnectDelay,
        logger = logger,
        needsReconnect = false,
        audioOutstanding = false,
        warnedUnavailable = false,
        allowedNames = configuredNames(options),
    }, Speakers)

    self:_waitForDevices()
    return self
end

-- function: Stop playback on all speakers in the given device list.
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

-- function: Stop all connected speakers and clear active playback state.
function Speakers:stop()
    local stopped = self:_stopDevices(self.devices)
    self.pendingEmpty = {}
    self.activeDevices = nil
    return stopped
end

-- function: Drain queued peripheral and speaker events before starting playback.
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
    self.pendingEmpty = {}
    self:drainEvents()

    local ok, wasDisconnected = self:_refreshDevices()
    if ok then
        if wasDisconnected and self.logger then
            self.logger.info(("Reconnected %d speaker(s)."):format(#self.devices))
        end
        return true
    end

    if not self.warnedUnavailable and self.logger then
        self.logger.warn(self.allowedNames
            and "No configured speaker available; skipping announcement."
            or "No speaker available; skipping announcement.")
        self.warnedUnavailable = true
    end
    return false
end

-- function: Return the active speaker list for the current announcement.
function Speakers:_activePlaybackDevices()
    if type(self.activeDevices) ~= "table" then
        self.activeDevices = copyDevices(self.devices)
    end
    return self.activeDevices
end

-- function: Drop a failed, detached, or timed-out speaker for the remainder of this announcement.
function Speakers:_dropActiveDevice(name, reason)
    local active = self:_activePlaybackDevices()
    for index, device in ipairs(active) do
        if device.name == name then
            table.remove(active, index)
            self.pendingEmpty[name] = nil
            self.needsReconnect = true
            if self.logger and reason then
                self.logger.warn(("%s (%d speaker(s) remaining)."):format(reason, #active))
            end
            return true
        end
    end
    return false
end

-- function: Wait for target active speakers to emit speaker_audio_empty without stopping healthy peers.
function Speakers:_waitForDevicesReady(targetDevices, interruptEventName)
    local active = self:_activePlaybackDevices()
    local waiting = {}
    local waitingCount = 0

    for _, device in ipairs(targetDevices or {}) do
        if hasPlaybackDevice(active, device.name) and not waiting[device.name] then
            waiting[device.name] = true
            waitingCount = waitingCount + 1
        end
    end

    if waitingCount == 0 then
        return true, nil
    end

    local readyTimer = type(os.startTimer) == "function"
        and os.startTimer(SPEAKER_READY_TIMEOUT_SECONDS)
        or nil

    while waitingCount > 0 do
        local event, name = os.pullEvent()

        if interruptEventName and event == interruptEventName then
            cancelTimer(readyTimer)
            return false, "interrupted"
        end

        if readyTimer and event == "timer" and name == readyTimer then
            local timedOut = {}
            for deviceName in pairs(waiting) do
                timedOut[#timedOut + 1] = deviceName
            end
            for _, deviceName in ipairs(timedOut) do
                self:_dropActiveDevice(
                    deviceName,
                    ("Speaker audio-ready timeout (%s)"):format(tostring(deviceName))
                )
                waiting[deviceName] = nil
            end
            waitingCount = 0
            self.audioOutstanding = next(self.pendingEmpty) ~= nil

            if #self:_activePlaybackDevices() == 0 then
                self.audioOutstanding = false
                return false, "no_speakers"
            end

            return true, "degraded"
        end

        if event == "peripheral_detach" and hasPlaybackDevice(self:_activePlaybackDevices(), name) then
            self:_dropActiveDevice(name, "Speaker detached: " .. tostring(name))
            if waiting[name] then
                waiting[name] = nil
                waitingCount = waitingCount - 1
            end

            if #self:_activePlaybackDevices() == 0 then
                cancelTimer(readyTimer)
                self.audioOutstanding = false
                return false, "no_speakers"
            end
        end

        if event == "speaker_audio_empty" then
            self.pendingEmpty[name] = nil
            if waiting[name] then
                waiting[name] = nil
                waitingCount = waitingCount - 1
            end
        end
    end

    cancelTimer(readyTimer)
    self.audioOutstanding = next(self.pendingEmpty) ~= nil
    return true, nil
end

-- function: Wait until all active speakers with pending audio report empty.
function Speakers:waitUntilAllReady(interruptEventName)
    local active = self:_activePlaybackDevices()
    local targets = {}

    for _, device in ipairs(active) do
        if self.pendingEmpty[device.name] == true then
            targets[#targets + 1] = device
        end
    end

    if #targets == 0 and next(self.pendingEmpty) == nil and self.audioOutstanding then
        targets = copyDevices(active)
    end

    local ok = self:_waitForDevicesReady(targets, interruptEventName)
    return ok == true
end

-- function: Wait for any outstanding speaker buffers to drain at the end of an announcement.
function Speakers:finishPlayback(interruptEventName)
    if not self.audioOutstanding then
        self.pendingEmpty = {}
        return true
    end

    local targets = {}
    for _, device in ipairs(self:_activePlaybackDevices()) do
        if self.pendingEmpty[device.name] == true then
            targets[#targets + 1] = device
        end
    end

    if #targets == 0 then
        self.audioOutstanding = false
        return #self:_activePlaybackDevices() > 0
    end

    local ok = self:_waitForDevicesReady(targets, interruptEventName)
    if ok then
        self.audioOutstanding = false
        self.pendingEmpty = {}
        return true
    end

    return false
end

-- function: Submit one PCM chunk to active speakers, isolating failures and buffer skew per speaker.
function Speakers:playChunk(audio, interruptEventName)
    local active = self:_activePlaybackDevices()
    if #active == 0 then
        self.audioOutstanding = false
        return false
    end

    local remaining = copyDevices(active)
    local acceptedAny = false
    local waitAttempts = 0

    while #remaining > 0 do
        local busyDevices = {}

        for _, device in ipairs(remaining) do
            if hasPlaybackDevice(self:_activePlaybackDevices(), device.name) then
                local ok, accepted = pcall(device.peripheral.playAudio, audio, self.volume)
                if not ok then
                    self:_dropActiveDevice(
                        device.name,
                        ("Speaker playback failed (%s): %s"):format(
                            tostring(device.name),
                            tostring(accepted)
                        )
                    )
                elseif accepted then
                    acceptedAny = true
                    self.pendingEmpty[device.name] = true
                else
                    self.pendingEmpty[device.name] = true
                    busyDevices[#busyDevices + 1] = device
                end
            end
        end

        if #busyDevices == 0 then
            if acceptedAny and #self:_activePlaybackDevices() > 0 then
                self.audioOutstanding = next(self.pendingEmpty) ~= nil
                return true
            end
            self.audioOutstanding = false
            return false
        end

        waitAttempts = waitAttempts + 1
        if waitAttempts > MAX_SPEAKER_RESYNC_ATTEMPTS then
            for _, device in ipairs(busyDevices) do
                self:_dropActiveDevice(
                    device.name,
                    ("Speaker remained busy (%s)"):format(tostring(device.name))
                )
            end

            if acceptedAny and #self:_activePlaybackDevices() > 0 then
                self.audioOutstanding = next(self.pendingEmpty) ~= nil
                return true
            end
            self.audioOutstanding = false
            return false
        end

        local ready = self:_waitForDevicesReady(busyDevices, interruptEventName)
        if not ready then
            return false
        end

        local nextRemaining = {}
        local currentActive = self:_activePlaybackDevices()
        for _, device in ipairs(busyDevices) do
            if hasPlaybackDevice(currentActive, device.name) then
                nextRemaining[#nextRemaining + 1] = device
            end
        end
        remaining = nextRemaining
    end

    if acceptedAny and #self:_activePlaybackDevices() > 0 then
        self.audioOutstanding = next(self.pendingEmpty) ~= nil
        return true
    end

    self.audioOutstanding = false
    return false
end

return Speakers
