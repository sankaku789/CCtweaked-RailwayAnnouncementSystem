local Speakers = {}
Speakers.__index = Speakers

local DRAIN_EVENT = "railway_speaker_drain_complete"
local LOCK_SYSTEM = "railway_announcement_speaker_lock"
local LOCK_VERSION = 1

-- function: Return the current UTC epoch time in milliseconds.
local function now()
    return os.epoch("utc")
end

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

-- function: Build a stable shared-lock key from the currently visible speaker names.
local function speakerKey(devices)
    local names = {}
    for _, device in ipairs(devices or {}) do
        names[#names + 1] = tostring(device.name)
    end
    table.sort(names)
    return table.concat(names, "\31")
end

-- function: Compare two FCFS requests by timestamp, then computer ID.
local function requestBefore(left, right)
    if not right then
        return true
    end

    local leftAt = tonumber(left.requestedAt) or math.huge
    local rightAt = tonumber(right.requestedAt) or math.huge
    if leftAt ~= rightAt then
        return leftAt < rightAt
    end

    return (tonumber(left.computerId) or math.huge) < (tonumber(right.computerId) or math.huge)
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
            self.lockKey = speakerKey(devices)
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

-- function: Open every attached modem for rednet-based shared-speaker arbitration.
function Speakers:_ensureSharedNetwork()
    if not self.sharedEnabled then
        return false
    end

    if self.sharedNetworkReady then
        return true
    end

    if type(rednet) ~= "table" or type(rednet.open) ~= "function" then
        if self.logger and not self.sharedNetworkWarned then
            self.logger.warn("Shared speaker FCFS disabled: rednet is unavailable")
            self.sharedNetworkWarned = true
        end
        self.sharedEnabled = false
        return false
    end

    local opened = false
    local modems = { peripheral.find("modem") }
    for _, modem in ipairs(modems) do
        local okName, name = pcall(peripheral.getName, modem)
        if okName and name then
            local alreadyOpen = type(rednet.isOpen) == "function" and rednet.isOpen(name)
            if alreadyOpen then
                opened = true
            else
                local ok = pcall(rednet.open, name)
                opened = opened or ok
            end
        end
    end

    if not opened then
        if self.logger and not self.sharedNetworkWarned then
            self.logger.warn("Shared speaker FCFS disabled: no usable modem found")
            self.sharedNetworkWarned = true
        end
        self.sharedEnabled = false
        return false
    end

    self.sharedNetworkReady = true
    if self.logger then
        self.logger.info("Shared speaker FCFS enabled.")
    end
    return true
end

-- function: Broadcast one shared-speaker lock message.
function Speakers:_broadcastLock(action)
    if not self:_ensureSharedNetwork() then
        return false
    end

    local request = self.lockRequest
    local message = {
        system = LOCK_SYSTEM,
        version = LOCK_VERSION,
        key = self.lockKey,
        action = action,
        computerId = self.computerId,
        requestedAt = request and request.requestedAt or nil,
    }

    local ok = pcall(rednet.broadcast, message, self.lockProtocol)
    return ok
end

-- function: Remember a pending FCFS request seen on the shared network.
function Speakers:_rememberRequest(computerId, requestedAt)
    computerId = tonumber(computerId)
    requestedAt = tonumber(requestedAt)
    if not computerId or not requestedAt then
        return
    end

    self.lockRequests[computerId] = {
        computerId = computerId,
        requestedAt = requestedAt,
        lastSeen = now(),
    }
end

-- function: Remove stale waiters and a stale playback owner.
function Speakers:_pruneLockState()
    local current = now()

    for computerId, request in pairs(self.lockRequests) do
        if current - (tonumber(request.lastSeen) or 0) > self.lockRequestLeaseMs then
            self.lockRequests[computerId] = nil
        end
    end

    if self.lockOwner
        and current - (tonumber(self.lockOwner.lastSeen) or 0) > self.lockLeaseMs
    then
        self.lockOwner = nil
    end
end

-- function: Apply one lock protocol message to local arbitration state.
function Speakers:_handleLockMessage(senderId, message)
    if type(message) ~= "table"
        or message.system ~= LOCK_SYSTEM
        or message.version ~= LOCK_VERSION
        or message.key ~= self.lockKey
    then
        return
    end

    local computerId = tonumber(message.computerId) or tonumber(senderId)
    if not computerId then
        return
    end

    local action = message.action
    if action == "request" then
        self:_rememberRequest(computerId, message.requestedAt)
        return
    end

    if action == "cancel" then
        self.lockRequests[computerId] = nil
        return
    end

    if action == "release" then
        self.lockRequests[computerId] = nil
        if self.lockOwner and self.lockOwner.computerId == computerId then
            self.lockOwner = nil
        end
        return
    end

    if action ~= "acquire" and action ~= "heartbeat" then
        return
    end

    local requestedAt = tonumber(message.requestedAt)
    if not requestedAt then
        return
    end

    self:_rememberRequest(computerId, requestedAt)
    local candidate = {
        computerId = computerId,
        requestedAt = requestedAt,
        lastSeen = now(),
    }

    if action == "heartbeat"
        and self.lockOwner
        and self.lockOwner.computerId == computerId
    then
        self.lockOwner.lastSeen = candidate.lastSeen
        return
    end

    if not self.lockOwner or requestBefore(candidate, self.lockOwner) then
        self.lockOwner = candidate
    end
end

-- function: Receive one lock message while remaining responsive to a local playback interrupt.
function Speakers:_receiveLockMessage(timeoutSeconds, interruptEventName)
    local result = nil

    local function receive()
        local senderId, message = rednet.receive(self.lockProtocol, timeoutSeconds)
        result = {
            senderId = senderId,
            message = message,
        }
    end

    if not interruptEventName then
        receive()
        return result, false
    end

    local function interrupt()
        os.pullEvent(interruptEventName)
        result = nil
    end

    local winner = parallel.waitForAny(receive, interrupt)
    return result, winner == 2
end

-- function: Collect lock traffic for a bounded arbitration window.
function Speakers:_collectLockMessages(seconds, interruptEventName)
    local deadline = now() + math.max(0, tonumber(seconds) or 0) * 1000

    while true do
        local remaining = (deadline - now()) / 1000
        if remaining <= 0 then
            return true
        end

        local received, interrupted = self:_receiveLockMessage(remaining, interruptEventName)
        if interrupted then
            return false
        end

        if not received or received.senderId == nil then
            return true
        end

        self:_handleLockMessage(received.senderId, received.message)
    end
end

-- function: Return the earliest pending FCFS request.
function Speakers:_earliestRequest()
    local earliest = nil
    for _, request in pairs(self.lockRequests) do
        if requestBefore(request, earliest) then
            earliest = request
        end
    end
    return earliest
end

-- function: Acquire the shared speaker set for one complete announcement.
function Speakers:acquirePlayback(interruptEventName)
    if not self:_ensureSharedNetwork() then
        return true
    end

    if self.lockOwner and self.lockOwner.computerId == self.computerId then
        return true
    end

    local request = {
        computerId = self.computerId,
        requestedAt = now(),
        lastSeen = now(),
    }
    self.lockRequest = request
    self.lockRequests[self.computerId] = request
    self:_broadcastLock("request")

    while true do
        local collected = self:_collectLockMessages(self.lockArbitrationWindowSeconds, interruptEventName)
        if not collected then
            self:_broadcastLock("cancel")
            self.lockRequests[self.computerId] = nil
            self.lockRequest = nil
            return false
        end

        self:_pruneLockState()

        if self.lockOwner and self.lockOwner.computerId == self.computerId then
            return true
        end

        if not self.lockOwner then
            local earliest = self:_earliestRequest()
            if earliest and earliest.computerId == self.computerId then
                self.lockOwner = {
                    computerId = self.computerId,
                    requestedAt = request.requestedAt,
                    lastSeen = now(),
                }
                self:_broadcastLock("acquire")

                local confirmed = self:_collectLockMessages(
                    self.lockArbitrationWindowSeconds,
                    interruptEventName
                )
                if not confirmed then
                    self:_broadcastLock("cancel")
                    self.lockRequests[self.computerId] = nil
                    self.lockOwner = nil
                    self.lockRequest = nil
                    return false
                end

                self:_pruneLockState()
                if self.lockOwner and self.lockOwner.computerId == self.computerId then
                    if self.logger then
                        self.logger.info("Shared speaker lock acquired.")
                    end
                    return true
                end
            end
        end

        self.lockRequest.lastSeen = now()
        self.lockRequests[self.computerId] = self.lockRequest
        self:_broadcastLock("request")

        local waited = self:_collectLockMessages(self.lockRetrySeconds, interruptEventName)
        if not waited then
            self:_broadcastLock("cancel")
            self.lockRequests[self.computerId] = nil
            self.lockRequest = nil
            return false
        end
    end
end

-- function: Refresh the shared-speaker owner lease during playback.
function Speakers:renewPlayback()
    if not self.sharedNetworkReady
        or not self.lockOwner
        or self.lockOwner.computerId ~= self.computerId
    then
        return
    end

    self.lockOwner.lastSeen = now()
    self:_broadcastLock("heartbeat")
end

-- function: Release the shared speaker set after a complete announcement.
function Speakers:releasePlayback()
    if not self.sharedNetworkReady then
        return
    end

    if self.lockOwner and self.lockOwner.computerId == self.computerId then
        self:_broadcastLock("release")
    else
        self:_broadcastLock("cancel")
    end

    self.lockRequests[self.computerId] = nil
    self.lockOwner = nil
    self.lockRequest = nil

    if self.logger then
        self.logger.info("Shared speaker lock released.")
    end
end

-- function: Create and connect a speaker group with automatic re-discovery support.
function Speakers.connect(options, logger)
    options = options or {}
    local shared = type(options.shared) == "table" and options.shared or {}

    local reconnectDelay = tonumber(options.reconnectDelay) or 1
    if reconnectDelay < 0 then
        reconnectDelay = 0
    end

    local arbitrationWindowSeconds = tonumber(shared.arbitrationWindowSeconds) or 0.2
    if arbitrationWindowSeconds < 0.05 then
        arbitrationWindowSeconds = 0.05
    end

    local retrySeconds = tonumber(shared.retrySeconds) or 0.25
    if retrySeconds < 0.05 then
        retrySeconds = 0.05
    end

    local leaseMs = tonumber(shared.leaseMs) or 300000
    if leaseMs < 1000 then
        leaseMs = 1000
    end

    local requestLeaseMs = tonumber(shared.requestLeaseMs) or 5000
    if requestLeaseMs < 1000 then
        requestLeaseMs = 1000
    end

    local self = setmetatable({
        devices = {},
        volume = options.volume or 3,
        reconnectDelay = reconnectDelay,
        logger = logger,
        needsReconnect = false,
        audioOutstanding = false,

        sharedEnabled = shared.enabled == true,
        sharedNetworkReady = false,
        sharedNetworkWarned = false,
        lockProtocol = type(shared.protocol) == "string" and shared.protocol ~= ""
            and shared.protocol
            or "railway_announcement_speaker_fcfs",
        lockArbitrationWindowSeconds = arbitrationWindowSeconds,
        lockRetrySeconds = retrySeconds,
        lockLeaseMs = leaseMs,
        lockRequestLeaseMs = requestLeaseMs,
        lockKey = "",
        lockRequests = {},
        lockOwner = nil,
        lockRequest = nil,
        computerId = os.getComputerID(),
    }, Speakers)

    self:_waitForDevices()
    self:_ensureSharedNetwork()
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

    self.audioOutstanding = false

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

    self.audioOutstanding = false
    return true
end

-- function: Wait for all submitted audio to become inaudible before releasing a shared lock.
function Speakers:finishPlayback(interruptEventName)
    if not self.audioOutstanding then
        return true
    end

    return self:waitUntilAllReady(interruptEventName)
end

-- function: Submit one prepared PCM chunk without creating an artificial playback boundary.
function Speakers:playChunk(audio, interruptEventName)
    if self.needsReconnect then
        self:_reconnect("Speaker connection changed. Reconnecting...")
    end

    self:renewPlayback()

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
            self.audioOutstanding = true
            return true
        end

        if not retry then
            error("Failed to enqueue audio chunk to all speakers")
        end
    end
end

return Speakers
