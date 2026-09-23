local SharedGuidance = require("core.shared_guidance")

local PRESENCE_ACTION = "guidance_presence"
local TRACK_STATE_ACTION = "guidance_track_state"

local function now()
    return os.epoch("utc")
end

local function laterEpoch(left, right)
    left = tonumber(left)
    right = tonumber(right)

    if not left then
        return right
    end
    if not right then
        return left
    end
    return math.max(left, right)
end

local originalNew = SharedGuidance.new
local originalPrune = SharedGuidance._prune

-- function: Create shared-guidance state with a separate per-peer hard-hold map.
function SharedGuidance.new(options)
    local self = originalNew(options)
    self.remoteHolds = {}
    return self
end

-- function: Broadcast liveness plus the local track, deadline, and explicit hold.
function SharedGuidance:_broadcastPresence()
    local hold = nil
    if type(self.scheduler.getSharedGuidanceHold) == "function" then
        hold = self.scheduler:getSharedGuidanceHold()
    end

    return self:_broadcast(PRESENCE_ACTION, {
        guidanceCandidate = self.guidanceCandidate,
        trackState = self.scheduler.trackState:get(),
        guidanceResumeAt = self.scheduler:getSharedGuidanceResumeAt(),
        guidanceHold = hold,
    })
end

-- function: Publish one immediate local guidance-policy state change.
function SharedGuidance:notifyTrackState(state, guidanceResumeAt, guidanceHold)
    return self:_broadcast(TRACK_STATE_ACTION, {
        trackState = state,
        guidanceResumeAt = tonumber(guidanceResumeAt),
        guidanceHold = guidanceHold == true,
    })
end

-- function: Apply remote track state without ever changing the local TrackState.
function SharedGuidance:_applyRemoteTrackState(computerId, state, guidanceResumeAt, guidanceHold)
    computerId = tonumber(computerId)
    if not computerId or computerId == self.localId then
        return
    end

    local explicitHold = guidanceHold ~= nil
    if explicitHold then
        if guidanceHold == true then
            self.remoteHolds[computerId] = true
        else
            self.remoteHolds[computerId] = nil
        end
    end

    if state == "PLATFORM" then
        self.remotePlatforms[computerId] = true
        self.remoteResumeAt[computerId] = nil
        return
    end

    if state ~= "IDLE" then
        return
    end

    self.remotePlatforms[computerId] = nil

    local resumeAt = tonumber(guidanceResumeAt)
    if explicitHold then
        if resumeAt and resumeAt > now() then
            self.remoteResumeAt[computerId] = resumeAt
        else
            self.remoteResumeAt[computerId] = nil
        end
        return
    end

    -- Compatibility with older peers which do not publish guidanceHold.
    if resumeAt and resumeAt > now() then
        self.remoteResumeAt[computerId] = laterEpoch(
            self.remoteResumeAt[computerId],
            resumeAt
        )
    end
end

-- function: Track remote normal announcements while explicit holds own exact delays.
function SharedGuidance:_applyLockMessage(computerId, message)
    computerId = tonumber(computerId)
    if not computerId or computerId == self.localId then
        return
    end

    local action = message.action
    if action == "request" or action == "acquire" or action == "heartbeat" then
        self.remoteBusy[computerId] = {
            announcementType = message.announcementType,
            lastSeen = now(),
        }
        return
    end

    local active = self.remoteBusy[computerId]
    local announcementType = message.announcementType
        or (active and active.announcementType)

    if action == "release" then
        self.remoteBusy[computerId] = nil

        -- New peers keep guidanceHold asserted until their actual playback end
        -- has been observed locally and an exact resumeAt is published. Retain
        -- the older owner-side delay only as a rolling-upgrade fallback.
        if self.remoteHolds[computerId] ~= true then
            local delayMs = self:_releaseDelayMs(announcementType)
            if delayMs > 0 then
                self.remoteResumeAt[computerId] = laterEpoch(
                    self.remoteResumeAt[computerId],
                    now() + delayMs
                )
            end
        end
        return
    end

    if action == "cancel" then
        self.remoteBusy[computerId] = nil
    end
end

-- function: Remove explicit holds when their peer lease expires.
function SharedGuidance:_prune()
    originalPrune(self)

    for computerId in pairs(self.remoteHolds) do
        if self.peers[computerId] == nil then
            self.remoteHolds[computerId] = nil
        end
    end
end

-- function: Aggregate platform, playback, explicit hold, and exact deadline gates.
function SharedGuidance:_updateGate()
    local blocked = next(self.remotePlatforms) ~= nil
        or next(self.remoteBusy) ~= nil
        or next(self.remoteHolds) ~= nil
    local resumeAt = nil

    for _, candidate in pairs(self.remoteResumeAt) do
        resumeAt = laterEpoch(resumeAt, candidate)
    end

    self.scheduler:setRemoteGuidanceGate(blocked, resumeAt)
end

-- function: Process one shared message with explicit per-peer guidance policy state.
function SharedGuidance:_handleMessage(senderId, message, protocol)
    local computerId = self:_messageComputerId(senderId, message, protocol)
    if not computerId then
        return
    end

    if type(self.speakers.observeSharedMessage) == "function" then
        self.speakers:observeSharedMessage(senderId, message, protocol)
    end

    if message.action == PRESENCE_ACTION then
        self:_touchPeer(computerId, message.guidanceCandidate)
        self:_applyRemoteTrackState(
            computerId,
            message.trackState,
            message.guidanceResumeAt,
            message.guidanceHold
        )
    elseif message.action == TRACK_STATE_ACTION then
        self:_touchPeer(computerId, nil)
        self:_applyRemoteTrackState(
            computerId,
            message.trackState,
            message.guidanceResumeAt,
            message.guidanceHold
        )
    elseif message.action == "request"
        or message.action == "acquire"
        or message.action == "heartbeat"
        or message.action == "release"
        or message.action == "cancel"
    then
        self:_touchPeer(computerId, nil)
        self:_applyLockMessage(computerId, message)
    else
        return
    end

    self:_refresh()
end

return SharedGuidance
