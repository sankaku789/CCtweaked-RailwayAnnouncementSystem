local config = require("config")
local announcementPatterns = require("announcement_patterns.main")
local announcementComposites = require("announcement_patterns.composites")
local segmentDefinitions = require("announcement_patterns.segments")
local routeOptions = require("announcement_patterns.route_options")

local log = require("util.log")
local RailwayInput = require("hardware.railway_input")
local Speakers = require("hardware.speakers")
local TrackState = require("core.track_state")
local Queue = require("core.announcement_queue")
local Segment = require("audio.segment")
local Composer = require("core.composer")
local Player = require("audio.player")
local GuidanceBell = require("audio.guidance_bell")
local Cache = require("metadata.cache")
local MetadataProvider = require("metadata.provider")
local Scheduler = require("core.scheduler")

local app = {}

local DFPWM_BYTES_PER_SECOND = 6000
local DEFAULT_DEPARTURE_MELODY_END_LEAD_SECONDS = 3
local SHARED_LOCK_SYSTEM = "railway_announcement_speaker_lock"
local SHARED_LOCK_VERSION = 1
local GUIDANCE_PRESENCE_ACTION = "guidance_presence"
local GUIDANCE_TRACK_STATE_ACTION = "guidance_track_state"
local GUIDANCE_OWNER_HEARTBEAT_SECONDS = 1
local GUIDANCE_OWNER_LEASE_MS = 3500
local GUIDANCE_OWNER_ELECTION_SECONDS = 0.4
local REMOTE_GUIDANCE_INTERRUPT_PRIORITY = 0

-- function: Return the current UTC epoch time in milliseconds.
local function now()
    return os.epoch("utc")
end

-- function: Load the configured metadata adapter with a safe fallback.
local function loadAdapter()
    local name = config.adapter and config.adapter.module or "none"
    local moduleName = "adapter." .. tostring(name)

    local ok, module = pcall(require, moduleName)
    if not ok then
        log.warn(("Failed to load %s; falling back to adapter.none: %s"):format(
            moduleName,
            tostring(module)
        ))
        module = require("adapter.none")
    end

    if type(module.new) == "function" then
        return module.new(config.adapter or {})
    end

    return module
end

-- function: Return the duration and path of the configured departure melody.
local function departureMelodyDurationSeconds(resolver)
    local ok, paths, reason = pcall(resolver.resolve, resolver, "departure_melody", nil, true)
    if not ok then
        return nil, nil, paths
    end

    if type(paths) ~= "table" or #paths ~= 1 or type(paths[1]) ~= "string" then
        return nil, nil, reason or "departure melody did not resolve to exactly one audio file"
    end

    local path = paths[1]
    return fs.getSize(path) / DFPWM_BYTES_PER_SECOND, path, nil
end

-- function: Return the configured gap between melody end and scheduled departure.
local function departureMelodyEndLeadSeconds()
    local departureConfig = type(config.announcement) == "table" and config.announcement.departure or nil
    local leadSeconds = type(departureConfig) == "table" and tonumber(departureConfig.melodyEndLeadSeconds) or nil

    if leadSeconds == nil then
        leadSeconds = DEFAULT_DEPARTURE_MELODY_END_LEAD_SECONDS
    end

    return math.max(0, leadSeconds)
end

-- function: Build the startup departure timing profile.
local function buildDepartureTiming(adapter, resolver)
    local fallbackDelaySeconds = math.max(0, tonumber(config.TIMEOUT_TIMING) or 0)
    local melodySeconds, melodyPath, melodyError = departureMelodyDurationSeconds(resolver)
    local leadSeconds = departureMelodyEndLeadSeconds()

    local timing = {
        dynamic = false,
        candidateCount = nil,
        dwellTimeMs = nil,
        melodySeconds = melodySeconds,
        melodyPath = melodyPath,
        leadSeconds = leadSeconds,
        fallbackDelaySeconds = fallbackDelaySeconds,
        staticDelaySeconds = fallbackDelaySeconds,
    }

    if not melodySeconds then
        log.warn("Departure timing melody unavailable: " .. tostring(melodyError))
    end

    if not adapter then
        return timing
    end

    if type(adapter.getPlatformDwellTiming) == "function" then
        local ok, profile = pcall(adapter.getPlatformDwellTiming, adapter, {
            track = config.trackNumber,
        })

        if not ok then
            log.warn("MTR departure timing unavailable: " .. tostring(profile))
            return timing
        end

        if type(profile) == "table" then
            timing.dynamic = profile.dynamic == true
            timing.candidateCount = tonumber(profile.candidateCount)
            timing.dwellTimeMs = tonumber(profile.dwellTimeMs)
        end
    elseif type(adapter.getPlatformDwellTimeMs) == "function" then
        local ok, dwellTimeMs = pcall(adapter.getPlatformDwellTimeMs, adapter, {
            track = config.trackNumber,
        })

        if not ok then
            log.warn("MTR departure timing unavailable: " .. tostring(dwellTimeMs))
            return timing
        end

        timing.dwellTimeMs = tonumber(dwellTimeMs)
    end

    if timing.dynamic then
        log.event("Departure timing", ("dynamic candidates=%s"):format(
            timing.candidateCount and tostring(timing.candidateCount) or "?"
        ))
        return timing
    end

    if timing.dwellTimeMs and timing.dwellTimeMs >= 0 and melodySeconds then
        local dwellSeconds = timing.dwellTimeMs / 1000
        timing.staticDelaySeconds = math.max(0, dwellSeconds - melodySeconds - leadSeconds)

        log.event("Departure timing", ("static candidates=%s dwell=%.1fs delay=%.1fs"):format(
            timing.candidateCount and tostring(timing.candidateCount) or "1",
            dwellSeconds,
            timing.staticDelaySeconds
        ))
    end

    return timing
end

-- function: Return whether this computer participates in shared guidance coordination.
local function sharedCoordinationEnabled(speakers)
    return speakers.sharedNetworkReady == true
end

-- function: Return the computer ID from one valid message for this shared speaker set.
local function sharedMessageComputerId(speakers, senderId, message, protocol)
    if protocol ~= speakers.lockProtocol
        or type(message) ~= "table"
        or message.system ~= SHARED_LOCK_SYSTEM
        or message.version ~= SHARED_LOCK_VERSION
        or message.key ~= speakers.lockKey
    then
        return nil
    end

    return tonumber(message.computerId) or tonumber(senderId)
end

-- function: Return whether this computer may be elected as the guidance-bell owner.
local function localGuidanceCandidate()
    local bell = type(config.guidanceBell) == "table" and config.guidanceBell or nil
    return bell ~= nil and bell.enabled == true
end

-- function: Broadcast this computer's liveness, owner eligibility, and current local track state.
local function broadcastGuidancePresence(scheduler, speakers)
    local message = {
        system = SHARED_LOCK_SYSTEM,
        version = SHARED_LOCK_VERSION,
        key = speakers.lockKey,
        action = GUIDANCE_PRESENCE_ACTION,
        computerId = os.getComputerID(),
        guidanceCandidate = localGuidanceCandidate(),
        trackState = scheduler.trackState:get(),
    }

    return pcall(rednet.broadcast, message, speakers.lockProtocol)
end

-- function: Broadcast an immediate local track-state change without changing another computer's TrackState.
local function broadcastGuidanceTrackState(speakers, state)
    local message = {
        system = SHARED_LOCK_SYSTEM,
        version = SHARED_LOCK_VERSION,
        key = speakers.lockKey,
        action = GUIDANCE_TRACK_STATE_ACTION,
        computerId = os.getComputerID(),
        trackState = state,
    }

    return pcall(rednet.broadcast, message, speakers.lockProtocol)
end

-- function: Apply one remote computer's state only to the guidance-bell suppression map.
local function updateRemotePlatform(remotePlatforms, computerId, state, scheduler)
    computerId = tonumber(computerId)
    if not computerId or computerId == os.getComputerID() then
        return
    end

    if state == "PLATFORM" then
        remotePlatforms[computerId] = true
    elseif state == "IDLE" then
        remotePlatforms[computerId] = nil
    else
        return
    end

    scheduler:setRemoteGuidanceBlocked(next(remotePlatforms) ~= nil)
end

-- function: Elect one guidance-bell owner and remove stale remote platform blocks.
local function updateGuidanceOwner(peers, remotePlatforms, electionReadyAt, scheduler, player, speakers)
    local currentTime = now()

    for computerId, peer in pairs(peers) do
        if currentTime - (tonumber(peer.lastSeen) or 0) > GUIDANCE_OWNER_LEASE_MS then
            peers[computerId] = nil
            remotePlatforms[computerId] = nil
        end
    end
    scheduler:setRemoteGuidanceBlocked(next(remotePlatforms) ~= nil)

    if currentTime < electionReadyAt then
        return
    end

    local ownerId = nil
    for computerId, peer in pairs(peers) do
        computerId = tonumber(computerId)
        if computerId
            and peer.guidanceCandidate == true
            and (ownerId == nil or computerId < ownerId)
        then
            ownerId = computerId
        end
    end

    local localId = os.getComputerID()
    local wasOwner = speakers.guidanceOwnerReady == true
        and tonumber(speakers.guidanceOwnerId) == localId
    local changed = speakers.guidanceOwnerReady ~= (ownerId ~= nil)
        or tonumber(speakers.guidanceOwnerId) ~= ownerId

    speakers.guidanceOwnerReady = ownerId ~= nil
    speakers.guidanceOwnerId = ownerId

    if wasOwner
        and ownerId ~= localId
        and scheduler.currentRequestType == "guidance_bell"
    then
        player:interruptBelow(REMOTE_GUIDANCE_INTERRUPT_PRIORITY)
    end

    if changed and ownerId then
        if ownerId == localId then
            log.info(("Guidance bell owner elected: computer %d (local)."):format(ownerId))
        else
            log.info(("Guidance bell owner elected: computer %d."):format(ownerId))
        end
    end
end

-- function: Coordinate automatic bell ownership and remote platform-state suppression.
local function monitorGuidanceOwnership(scheduler, player, speakers)
    local localId = os.getComputerID()
    local peers = {
        [localId] = {
            lastSeen = now(),
            guidanceCandidate = localGuidanceCandidate(),
        },
    }
    local remotePlatforms = {}
    local electionReadyAt = now() + (GUIDANCE_OWNER_ELECTION_SECONDS * 1000)

    speakers.guidanceOwnerReady = false
    speakers.guidanceOwnerId = nil
    broadcastGuidancePresence(scheduler, speakers)

    local heartbeatTimer = os.startTimer(GUIDANCE_OWNER_HEARTBEAT_SECONDS)
    local electionTimer = os.startTimer(GUIDANCE_OWNER_ELECTION_SECONDS)

    while true do
        local event, first, second, third = os.pullEvent()

        if event == "rednet_message" then
            local senderId = first
            local message = second
            local protocol = third
            local computerId = sharedMessageComputerId(speakers, senderId, message, protocol)

            if computerId then
                if type(speakers.observeSharedMessage) == "function" then
                    speakers:observeSharedMessage(senderId, message, protocol)
                end

                if message.action == GUIDANCE_PRESENCE_ACTION then
                    peers[computerId] = {
                        lastSeen = now(),
                        guidanceCandidate = message.guidanceCandidate == true,
                    }
                    updateRemotePlatform(remotePlatforms, computerId, message.trackState, scheduler)
                    updateGuidanceOwner(
                        peers,
                        remotePlatforms,
                        electionReadyAt,
                        scheduler,
                        player,
                        speakers
                    )
                elseif message.action == GUIDANCE_TRACK_STATE_ACTION then
                    peers[computerId] = peers[computerId] or {
                        lastSeen = now(),
                        guidanceCandidate = false,
                    }
                    peers[computerId].lastSeen = now()
                    updateRemotePlatform(remotePlatforms, computerId, message.trackState, scheduler)
                elseif message.action == "request"
                    and computerId ~= localId
                    and speakers.guidanceOwnerReady == true
                    and tonumber(speakers.guidanceOwnerId) == localId
                    and scheduler.currentRequestType == "guidance_bell"
                then
                    player:interruptBelow(REMOTE_GUIDANCE_INTERRUPT_PRIORITY)
                end
            end
        elseif event == "timer" and first == heartbeatTimer then
            peers[localId] = {
                lastSeen = now(),
                guidanceCandidate = localGuidanceCandidate(),
            }
            broadcastGuidancePresence(scheduler, speakers)
            updateGuidanceOwner(
                peers,
                remotePlatforms,
                electionReadyAt,
                scheduler,
                player,
                speakers
            )
            heartbeatTimer = os.startTimer(GUIDANCE_OWNER_HEARTBEAT_SECONDS)
        elseif event == "timer" and first == electionTimer then
            updateGuidanceOwner(
                peers,
                remotePlatforms,
                electionReadyAt,
                scheduler,
                player,
                speakers
            )
            electionTimer = nil
        end
    end
end

-- function: Start and run the railway announcement application.
function app.run()
    log.info("Railway Announcement System starting.")

    local input = RailwayInput.new(config.input)
    local speakers = Speakers.connect(config.speaker, log)
    local trackState = TrackState.new(config.state)
    local queue = Queue.new()
    local resolver = Segment.new(config, segmentDefinitions)
    local composer = Composer.new(announcementPatterns, resolver, announcementComposites, routeOptions)
    local player = Player.new(speakers, log, config.guidanceBell)
    local guidanceBell = GuidanceBell.new(config.guidanceBell, log)

    local adapter = loadAdapter()
    local departureTiming = buildDepartureTiming(adapter, resolver)

    local cache = Cache.new(config.adapter.cacheTtlMs)
    local metadataProvider = MetadataProvider.new(adapter, cache, log)

    local scheduler = Scheduler.new({
        config = config,
        logger = log,
        input = input,
        speakers = speakers,
        trackState = trackState,
        queue = queue,
        metadataProvider = metadataProvider,
        composer = composer,
        player = player,
        guidanceBell = guidanceBell,
        departureTiming = departureTiming,
        departureTimingAdapter = adapter,
        sharedTrackNotifier = speakers.sharedNetworkReady and function(state)
            broadcastGuidanceTrackState(speakers, state)
        end or nil,
    })

    if sharedCoordinationEnabled(speakers) then
        parallel.waitForAll(
            function()
                scheduler:run()
            end,
            function()
                monitorGuidanceOwnership(scheduler, player, speakers)
            end
        )
    else
        speakers.guidanceOwnerReady = true
        speakers.guidanceOwnerId = os.getComputerID()
        scheduler:run()
    end
end

return app
