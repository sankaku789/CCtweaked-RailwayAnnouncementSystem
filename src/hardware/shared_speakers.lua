local Speakers = require("hardware.speakers")

local LOCK_SYSTEM = "railway_announcement_speaker_lock"
local LOCK_VERSION = 1
local MAX_SPEAKER_RESYNC_ATTEMPTS = 5

local originalAcquirePlayback = Speakers.acquirePlayback
local originalReleasePlayback = Speakers.releasePlayback
local originalStop = Speakers.stop

-- function: Compare shared requests by priority, then FCFS timestamp, then computer ID.
local function requestBefore(left, right)
    if not right then
        return true
    end

    local leftPriority = tonumber(left.priority) or 0
    local rightPriority = tonumber(right.priority) or 0
    if leftPriority ~= rightPriority then
        return leftPriority > rightPriority
    end

    local leftAt = tonumber(left.requestedAt) or math.huge
    local rightAt = tonumber(right.requestedAt) or math.huge
    if leftAt ~= rightAt then
        return leftAt < rightAt
    end

    return (tonumber(left.computerId) or math.huge)
        < (tonumber(right.computerId) or math.huge)
end

-- function: Return the speaker list currently participating in this playback.
local function playbackDevices(self)
    if type(self.degradedPlaybackDevices) == "table" and #self.degradedPlaybackDevices > 0 then
        return self.degradedPlaybackDevices
    end

    return self.devices
end

-- function: Return whether a peripheral name belongs to one playback device list.
local function hasPlaybackDevice(devices, name)
    for _, device in ipairs(devices or {}) do
        if device.name == name then
            return true
        end
    end

    return false
end

-- function: Broadcast shared lock state with announcement type and queue priority.
function Speakers:_broadcastLock(action)
    if not self:_ensureSharedNetwork() then
        return false
    end

    local request = self.lockRequest
    if request and request.priority == nil then
        request.priority = tonumber(self.sharedAnnouncementPriority) or 0
    end

    if self.lockOwner
        and self.lockOwner.computerId == self.computerId
        and self.lockOwner.priority == nil
    then
        self.lockOwner.priority = request and request.priority
            or tonumber(self.sharedAnnouncementPriority)
            or 0
    end

    local message = {
        system = LOCK_SYSTEM,
        version = LOCK_VERSION,
        key = self.lockKey,
        action = action,
        computerId = self.computerId,
        requestedAt = request and request.requestedAt or nil,
        announcementType = self.sharedAnnouncementType,
        priority = request and request.priority
            or tonumber(self.sharedAnnouncementPriority)
            or 0,
    }

    local ok = pcall(rednet.broadcast, message, self.lockProtocol)
    return ok
end

-- function: Remember one pending shared request including its priority.
function Speakers:_rememberRequest(computerId, requestedAt, priority)
    computerId = tonumber(computerId)
    requestedAt = tonumber(requestedAt)
    if not computerId or not requestedAt then
        return
    end

    self.lockRequests[computerId] = {
        computerId = computerId,
        requestedAt = requestedAt,
        priority = tonumber(priority) or 0,
        lastSeen = os.epoch("utc"),
    }
end

-- function: Apply shared lock messages using priority first and FCFS as the tie-breaker.
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
        self:_rememberRequest(computerId, message.requestedAt, message.priority)
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

    local priority = tonumber(message.priority) or 0
    self:_rememberRequest(computerId, requestedAt, priority)

    local candidate = {
        computerId = computerId,
        requestedAt = requestedAt,
        priority = priority,
        lastSeen = os.epoch("utc"),
    }

    if action == "heartbeat"
        and self.lockOwner
        and self.lockOwner.computerId == computerId
    then
        self.lockOwner.lastSeen = candidate.lastSeen
        self.lockOwner.priority = priority
        return
    end

    -- Acquire messages may race during the bounded arbitration window. Resolve
    -- that race with priority/FCFS ordering. Once playback is established, a
    -- later requester cannot acquire until the current owner releases.
    if not self.lockOwner or requestBefore(candidate, self.lockOwner) then
        self.lockOwner = candidate
    end
end

-- function: Return the highest-priority pending request, FCFS within one priority.
function Speakers:_earliestRequest()
    local earliest = nil
    for _, request in pairs(self.lockRequests) do
        if requestBefore(request, earliest) then
            earliest = request
        end
    end
    return earliest
end

-- function: Acquire normal-announcement arbitration while retaining type and priority.
-- When sharing is disabled the original implementation still returns immediately,
-- so single-computer playback behavior is unchanged.
function Speakers:acquirePlayback(interruptEventName, announcementType, priority)
    self.sharedAnnouncementType = type(announcementType) == "string"
        and announcementType
        or nil
    self.sharedAnnouncementPriority = tonumber(priority) or 0
    self.degradedPlaybackDevices = nil

    local acquired = originalAcquirePlayback(self, interruptEventName)
    if not acquired then
        self.sharedAnnouncementType = nil
        self.sharedAnnouncementPriority = nil
    end
    return acquired
end

-- function: Release arbitration and clear per-playback shared state.
function Speakers:releasePlayback()
    originalReleasePlayback(self)
    self.sharedAnnouncementType = nil
    self.sharedAnnouncementPriority = nil
    self.degradedPlaybackDevices = nil
end

-- function: Stop all visible speakers and reset any degraded playback subset.
function Speakers:stop()
    local stopped = originalStop(self)
    self.degradedPlaybackDevices = nil
    return stopped
end

-- function: Wait until every speaker participating in this playback is ready.
-- Keep a degraded subset across intermediate buffer waits; finishPlayback clears it.
function Speakers:waitUntilAllReady(interruptEventName)
    if self.needsReconnect then
        self:_reconnect("Speaker connection changed. Reconnecting...")
        self.degradedPlaybackDevices = nil
        return false
    end

    local devices = playbackDevices(self)
    local pending = {}
    local count = 0

    for _, device in ipairs(devices) do
        pending[device.name] = true
        count = count + 1
    end

    while count > 0 do
        local event, name = os.pullEvent()

        if interruptEventName and event == interruptEventName then
            return false
        end

        if event == "peripheral_detach" and hasPlaybackDevice(devices, name) then
            self:_reconnect("Speaker detached: " .. tostring(name))
            self.degradedPlaybackDevices = nil
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

-- function: Drain the final playback buffer and then allow all speakers next time.
function Speakers:finishPlayback(interruptEventName)
    if not self.audioOutstanding then
        self.degradedPlaybackDevices = nil
        return true
    end

    local finished = self:waitUntilAllReady(interruptEventName)
    self.degradedPlaybackDevices = nil
    return finished
end

-- function: Submit one PCM chunk, attempting to restore synchronized speaker playback first.
function Speakers:playChunk(audio, interruptEventName)
    if self.needsReconnect then
        self:_reconnect("Speaker connection changed. Reconnecting...")
        self.degradedPlaybackDevices = nil
    end

    self:renewPlayback()

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
                ):format(
                    reason,
                    resyncAttempts,
                    MAX_SPEAKER_RESYNC_ATTEMPTS
                ))
            end

            if acceptedCount > 0 then
                originalStop(self)
                self:drainEvents()
            end

            self:_reconnect()
            self.degradedPlaybackDevices = nil
            self:renewPlayback()
        end
    end
end

return Speakers
