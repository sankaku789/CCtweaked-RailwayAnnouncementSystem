local Speakers = require("hardware.speakers")

local LOCK_SYSTEM = "railway_announcement_speaker_lock"
local LOCK_VERSION = 1
local MAX_SPEAKER_RESYNC_ATTEMPTS = 5

local originalAcquirePlayback = Speakers.acquirePlayback
local originalReleasePlayback = Speakers.releasePlayback
local originalStop = Speakers.stop

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

-- function: Broadcast the shared lock state with the active announcement type.
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
        announcementType = self.sharedAnnouncementType,
    }

    local ok = pcall(rednet.broadcast, message, self.lockProtocol)
    return ok
end

-- function: Acquire normal-announcement FCFS while retaining its semantic type.
-- When sharing is disabled the original implementation still returns immediately,
-- so single-computer playback behavior is unchanged.
function Speakers:acquirePlayback(interruptEventName, announcementType)
    self.sharedAnnouncementType = type(announcementType) == "string"
        and announcementType
        or nil
    self.degradedPlaybackDevices = nil

    local acquired = originalAcquirePlayback(self, interruptEventName)
    if not acquired then
        self.sharedAnnouncementType = nil
    end
    return acquired
end

-- function: Release FCFS and clear per-playback degradation state after release is broadcast.
function Speakers:releasePlayback()
    originalReleasePlayback(self)
    self.sharedAnnouncementType = nil
    self.degradedPlaybackDevices = nil
end

-- function: Stop all visible speakers and reset any degraded playback subset.
function Speakers:stop()
    local stopped = originalStop(self)
    self.degradedPlaybackDevices = nil
    return stopped
end

-- function: Wait until every speaker participating in this playback is ready.
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
    self.degradedPlaybackDevices = nil
    return true
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
