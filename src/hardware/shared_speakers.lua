local Speakers = require("hardware.speakers")

local LOCK_SYSTEM = "railway_announcement_speaker_lock"
local LOCK_VERSION = 1

local originalAcquirePlayback = Speakers.acquirePlayback
local originalReleasePlayback = Speakers.releasePlayback

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

    local acquired = originalAcquirePlayback(self, interruptEventName)
    if not acquired then
        self.sharedAnnouncementType = nil
    end
    return acquired
end

-- function: Release FCFS and clear the announcement type after release is broadcast.
function Speakers:releasePlayback()
    originalReleasePlayback(self)
    self.sharedAnnouncementType = nil
end

return Speakers
