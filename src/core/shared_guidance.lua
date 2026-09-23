local SharedGuidance = {}
SharedGuidance.__index = SharedGuidance

local LOCK_SYSTEM = "railway_announcement_speaker_lock"
local LOCK_VERSION = 1
local PRESENCE_ACTION = "guidance_presence"
local TRACK_STATE_ACTION = "guidance_track_state"
local HEARTBEAT_SECONDS = 1
local PEER_LEASE_MS = 3500
local ELECTION_SECONDS = 0.4
local GUIDANCE_INTERRUPT_PRIORITY = 0
local DEFAULT_GUIDANCE_INTERVAL_SECONDS = 10

-- function: Return the current UTC epoch time in milliseconds.
local function now()
    return os.epoch("utc")
end

-- function: Keep the later of two optional epoch timestamps.
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

-- function: Return guidance timing settings even on computers where the bell is disabled.
local function guidanceSettings(config)
    local cfg = type(config.guidanceBell) == "table" and config.guidanceBell or {}
    local intervalSeconds = tonumber(cfg.intervalSeconds)
    if not intervalSeconds or intervalSeconds <= 0 then
        intervalSeconds = DEFAULT_GUIDANCE_INTERVAL_SECONDS
    end

    return {
        candidate = cfg.enabled == true,
        initialDelayMs = math.max(0, tonumber(cfg.initialDelaySeconds) or 0) * 1000,
        intervalMs = intervalSeconds * 1000,
    }
end

-- function: Create one coordinator for a shared speaker set.
function SharedGuidance.new(options)
    options = options or {}
    local settings = guidanceSettings(options.config or {})
    local localId = os.getComputerID()
    local currentTime = now()

    return setmetatable({
        config = options.config or {},
        logger = options.logger,
        speakers = options.speakers,
        scheduler = options.scheduler,
        player = options.player,
        localId = localId,
        guidanceCandidate = settings.candidate,
        initialDelayMs = settings.initialDelayMs,
        intervalMs = settings.intervalMs,
        peers = {
            [localId] = {
                lastSeen = currentTime,
                guidanceCandidate = settings.candidate,
            },
        },
        -- These maps are shared-guidance state only. They must never mutate the
        -- scheduler's local TrackState for this computer/track.
        remotePlatforms = {},
        remoteBusy = {},
        remoteResumeAt = {},
        electionReadyAt = currentTime + (ELECTION_SECONDS * 1000),
    }, SharedGuidance)
end

-- function: Return whether rednet coordination is available for this speaker set.
function SharedGuidance:isEnabled()
    return self.speakers ~= nil and self.speakers.sharedNetworkReady == true
end

-- function: Return the computer ID from one valid message for this speaker set.
function SharedGuidance:_messageComputerId(senderId, message, protocol)
    if not self:isEnabled()
        or protocol ~= self.speakers.lockProtocol
        or type(message) ~= "table"
        or message.system ~= LOCK_SYSTEM
        or message.version ~= LOCK_VERSION
        or message.key ~= self.speakers.lockKey
    then
        return nil
    end

    return tonumber(message.computerId) or tonumber(senderId)
end

-- function: Broadcast one coordination message on the shared-speaker protocol.
function SharedGuidance:_broadcast(action, fields)
    if not self:isEnabled() then
        return false
    end

    local message = {
        system = LOCK_SYSTEM,
        version = LOCK_VERSION,
        key = self.speakers.lockKey,
        action = action,
        computerId = self.localId,
    }

    for key, value in pairs(fields or {}) do
        message[key] = value
    end

    return pcall(rednet.broadcast, message, self.speakers.lockProtocol)
end

-- function: Broadcast liveness, owner eligibility, and the local platform state.
function SharedGuidance:_broadcastPresence()
    return self:_broadcast(PRESENCE_ACTION, {
        guidanceCandidate = self.guidanceCandidate,
        trackState = self.scheduler.trackState:get(),
        guidanceResumeAt = self.scheduler:getSharedGuidanceResumeAt(),
    })
end

-- function: Publish an immediate local state change without mutating any remote TrackState.
function SharedGuidance:notifyTrackState(state, guidanceResumeAt)
    return self:_broadcast(TRACK_STATE_ACTION, {
        trackState = state,
        guidanceResumeAt = tonumber(guidanceResumeAt),
    })
end

-- function: Remember that a peer is still alive and optionally update owner eligibility.
function SharedGuidance:_touchPeer(computerId, guidanceCandidate)
    computerId = tonumber(computerId)
    if not computerId then
        return
    end

    local peer = self.peers[computerId] or {
        guidanceCandidate = false,
    }
    peer.lastSeen = now()

    if guidanceCandidate ~= nil then
        peer.guidanceCandidate = guidanceCandidate == true
    end

    self.peers[computerId] = peer
end

-- function: Apply a remote platform state only to guidance suppression state.
function SharedGuidance:_applyRemoteTrackState(computerId, state, guidanceResumeAt)
    computerId = tonumber(computerId)
    if not computerId or computerId == self.localId then
        return
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
    if resumeAt and resumeAt > now() then
        self.remoteResumeAt[computerId] = laterEpoch(self.remoteResumeAt[computerId], resumeAt)
    end
end

-- function: Return the post-announcement guidance delay matching local behavior.
function SharedGuidance:_releaseDelayMs(announcementType)
    if announcementType == "next_train" then
        return self.initialDelayMs
    end

    if announcementType == "passing" then
        return self.intervalMs
    end

    if announcementType == "departure"
        or announcementType == "approach"
        or announcementType == "stopped"
    then
        return 0
    end

    return self.initialDelayMs
end

-- function: Track remote normal announcements from request through release.
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

        local delayMs = self:_releaseDelayMs(announcementType)
        if delayMs > 0 then
            self.remoteResumeAt[computerId] = laterEpoch(
                self.remoteResumeAt[computerId],
                now() + delayMs
            )
        end
        return
    end

    if action == "cancel" then
        self.remoteBusy[computerId] = nil
    end
end

-- function: Remove peers, busy requests, and resume deadlines that have gone stale.
function SharedGuidance:_prune()
    local currentTime = now()

    for computerId, peer in pairs(self.peers) do
        if computerId ~= self.localId
            and currentTime - (tonumber(peer.lastSeen) or 0) > PEER_LEASE_MS
        then
            self.peers[computerId] = nil
            self.remotePlatforms[computerId] = nil
            self.remoteBusy[computerId] = nil
            self.remoteResumeAt[computerId] = nil
        end
    end

    for computerId, active in pairs(self.remoteBusy) do
        if currentTime - (tonumber(active.lastSeen) or 0) > PEER_LEASE_MS then
            self.remoteBusy[computerId] = nil
        end
    end

    for computerId, resumeAt in pairs(self.remoteResumeAt) do
        if tonumber(resumeAt) == nil or tonumber(resumeAt) <= currentTime then
            self.remoteResumeAt[computerId] = nil
        end
    end
end

-- function: Apply the aggregate remote guidance gate to the local scheduler.
function SharedGuidance:_updateGate()
    local blocked = next(self.remotePlatforms) ~= nil or next(self.remoteBusy) ~= nil
    local resumeAt = nil

    for _, candidate in pairs(self.remoteResumeAt) do
        resumeAt = laterEpoch(resumeAt, candidate)
    end

    self.scheduler:setRemoteGuidanceGate(blocked, resumeAt)
end

-- function: Elect the lowest active candidate without changing any local track state.
function SharedGuidance:_updateOwner()
    if now() < self.electionReadyAt then
        return
    end

    local ownerId = nil
    for computerId, peer in pairs(self.peers) do
        computerId = tonumber(computerId)
        if computerId
            and peer.guidanceCandidate == true
            and (ownerId == nil or computerId < ownerId)
        then
            ownerId = computerId
        end
    end

    local wasLocalOwner = self.speakers.guidanceOwnerReady == true
        and tonumber(self.speakers.guidanceOwnerId) == self.localId
    local changed = self.speakers.guidanceOwnerReady ~= (ownerId ~= nil)
        or tonumber(self.speakers.guidanceOwnerId) ~= ownerId

    self.speakers.guidanceOwnerReady = ownerId ~= nil
    self.speakers.guidanceOwnerId = ownerId

    if wasLocalOwner
        and ownerId ~= self.localId
        and self.scheduler.currentRequestType == "guidance_bell"
    then
        self.player:interruptBelow(GUIDANCE_INTERRUPT_PRIORITY)
    end

    if changed and self.logger then
        if ownerId == nil then
            self.logger.info("Guidance bell owner unavailable.")
        elseif ownerId == self.localId then
            self.logger.info(("Guidance bell owner elected: computer %d (local)."):format(ownerId))
        else
            self.logger.info(("Guidance bell owner elected: computer %d."):format(ownerId))
        end
    end
end

-- function: Refresh stale state, bell suppression, and owner election together.
function SharedGuidance:_refresh()
    self:_prune()
    self:_updateGate()
    self:_updateOwner()
end

-- function: Process one shared-speaker or guidance coordination message.
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
            message.guidanceResumeAt
        )
    elseif message.action == TRACK_STATE_ACTION then
        self:_touchPeer(computerId, nil)
        self:_applyRemoteTrackState(
            computerId,
            message.trackState,
            message.guidanceResumeAt
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

-- function: Run owner election, presence heartbeats, and remote guidance gating.
function SharedGuidance:run()
    if not self:isEnabled() then
        return
    end

    self.speakers.guidanceOwnerReady = false
    self.speakers.guidanceOwnerId = nil
    self:_broadcastPresence()

    local heartbeatTimer = os.startTimer(HEARTBEAT_SECONDS)
    local electionTimer = os.startTimer(ELECTION_SECONDS)

    while true do
        local event, first, second, third = os.pullEvent()

        if event == "rednet_message" then
            self:_handleMessage(first, second, third)
        elseif event == "timer" and first == heartbeatTimer then
            self.peers[self.localId] = {
                lastSeen = now(),
                guidanceCandidate = self.guidanceCandidate,
            }
            self:_broadcastPresence()
            self:_refresh()
            heartbeatTimer = os.startTimer(HEARTBEAT_SECONDS)
        elseif event == "timer" and first == electionTimer then
            self:_refresh()
            electionTimer = nil
        end
    end
end

return SharedGuidance
