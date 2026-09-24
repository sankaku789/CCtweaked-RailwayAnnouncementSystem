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
local Cache = require("metadata.cache")
local MetadataProvider = require("metadata.provider")
local Scheduler = require("core.client.scheduler")
local Coordinator = require("core.client.coordinator")
local AssetClient = require("core.client.assets")
local PlaybackClient = require("core.client.playback")
local GuidanceClient = require("core.client.guidance")
local AssetServer = require("core.server.assets")
local PlaybackServer = require("core.server.playback")
local GuidanceServer = require("core.server.guidance")

local app = {}

local DFPWM_BYTES_PER_SECOND = 6000
local DEFAULT_DEPARTURE_END_LEAD_SECONDS = 3

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

local function localAudioPath(item)
    if type(item) == "string" then
        return item
    end

    if type(item) == "table"
        and (item.kind == "audio" or item.kind == "client_asset")
        and type(item.path) == "string"
    then
        return item.path
    end

    return nil
end

local function departureDurationSeconds(composer)
    local ok, items, diagnostics = pcall(composer.compose, composer, {
        type = "departure",
        track = config.trackNumber,
    }, nil)
    if not ok then
        return nil, items
    end

    local duration = 0
    local started = false
    for _, item in ipairs(items or {}) do
        local path = localAudioPath(item)
        if path and fs.exists(path) and not fs.isDir(path) then
            started = true
            duration = duration + (fs.getSize(path) / DFPWM_BYTES_PER_SECOND)
        elseif type(item) == "table" and item.kind == "pause" and started then
            duration = duration + math.max(0, tonumber(item.seconds) or 0)
        end
    end

    if not started then
        local reason = type(diagnostics) == "table" and diagnostics[1] or nil
        return nil, reason or "departure announcement did not resolve to playable audio"
    end

    return duration, nil
end

local function departureEndLeadSeconds()
    local departureConfig = type(config.announcement) == "table" and config.announcement.departure or nil
    local leadSeconds = nil

    if type(departureConfig) == "table" then
        leadSeconds = tonumber(departureConfig.departureEndLeadSeconds)
        if leadSeconds == nil then
            leadSeconds = tonumber(departureConfig.melodyEndLeadSeconds)
        end
    end

    if leadSeconds == nil then
        leadSeconds = DEFAULT_DEPARTURE_END_LEAD_SECONDS
    end

    return math.max(0, leadSeconds)
end

local function buildDepartureTiming(adapter, composer)
    local fallbackDelaySeconds = math.max(0, tonumber(config.TIMEOUT_TIMING) or 0)
    local departureSeconds, departureError = departureDurationSeconds(composer)
    local leadSeconds = departureEndLeadSeconds()

    local timing = {
        dynamic = false,
        candidateCount = nil,
        dwellTimeMs = nil,
        departureSeconds = departureSeconds,
        leadSeconds = leadSeconds,
        fallbackDelaySeconds = fallbackDelaySeconds,
        staticDelaySeconds = fallbackDelaySeconds,
    }

    if not departureSeconds then
        log.warn("Departure timing announcement unavailable: " .. tostring(departureError))
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

    if timing.dwellTimeMs and timing.dwellTimeMs >= 0 and departureSeconds then
        local dwellSeconds = timing.dwellTimeMs / 1000
        timing.staticDelaySeconds = math.max(0, dwellSeconds - departureSeconds - leadSeconds)

        log.event("Departure timing", ("static candidates=%s dwell=%.1fs delay=%.1fs"):format(
            timing.candidateCount and tostring(timing.candidateCount) or "1",
            dwellSeconds,
            timing.staticDelaySeconds
        ))
    end

    return timing
end

local function syncStaticClientAssets(resolver, assetClient)
    for _, asset in ipairs(resolver:staticClientAssets()) do
        local ok, reason = assetClient:sync(asset.key, asset.path)
        if not ok then
            error(("Client asset synchronization failed (%s): %s"):format(
                tostring(asset.key),
                tostring(reason)
            ))
        end
    end
end

-- function: Start the unified Client/Server railway announcement application.
function app.run()
    log.info("Railway Announcement System starting.")

    local coordinator = Coordinator.new(config, log)
    coordinator:initialize()

    local speakers = nil
    local player = nil
    local assetServer = nil
    local playbackServer = nil
    local guidanceServer = nil

    if coordinator:ownsServer() then
        speakers = Speakers.connect(config.speaker, log)
        player = Player.new(speakers, log)
        assetServer = AssetServer.new({
            logger = log,
            groupId = coordinator:getGroupId(),
            instanceId = coordinator:getInstanceId(),
        })
        guidanceServer = GuidanceServer.new(config.guidanceBell, log)
        playbackServer = PlaybackServer.new({
            player = player,
            assets = assetServer,
            guidance = guidanceServer,
            logger = log,
            groupId = coordinator:getGroupId(),
            instanceId = coordinator:getInstanceId(),
        })
        coordinator:setLocalServer(playbackServer)
    end

    local assetClient = AssetClient.new({
        groupId = coordinator:getGroupId(),
        serverId = coordinator:getServerId(),
        instanceId = coordinator:getInstanceId(),
        localAssetServer = assetServer,
        logger = log,
    })

    local playbackClient = PlaybackClient.new({
        groupId = coordinator:getGroupId(),
        serverId = coordinator:getServerId(),
        instanceId = coordinator:getInstanceId(),
        localServer = playbackServer,
        assets = assetClient,
        logger = log,
    })

    local guidanceClient = GuidanceClient.new({
        groupId = coordinator:getGroupId(),
        serverId = coordinator:getServerId(),
        instanceId = coordinator:getInstanceId(),
        localServer = playbackServer,
        logger = log,
    })

    coordinator:setGuidanceProvider(function()
        return guidanceClient:snapshot()
    end)

    local input = RailwayInput.new(config.input)
    local trackState = TrackState.new(config.state)
    local queue = Queue.new()
    local resolver = Segment.new(config, segmentDefinitions)
    local composer = Composer.new(announcementPatterns, resolver, announcementComposites, routeOptions)

    local adapter = loadAdapter()
    local departureTiming = buildDepartureTiming(adapter, composer)
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
        player = playbackClient,
        departureTiming = departureTiming,
        departureTimingAdapter = adapter,
    })

    scheduler.sharedTrackNotifier = function(state, guidanceResumeAt, guidanceHold)
        guidanceClient:updateFromTrack(state, guidanceResumeAt, guidanceHold)
    end

    guidanceClient:updateFromTrack(trackState:get(), nil, false)

    local tasks = {
        function()
            -- Do not start accepting railway input until static Client-owned audio
            -- is known to the Server. Coordinator/server tasks run in parallel so
            -- failure detection and incoming transfer handling remain live here.
            syncStaticClientAssets(resolver, assetClient)
            scheduler:run()
        end,
        function()
            coordinator:run()
        end,
    }

    if playbackServer then
        tasks[#tasks + 1] = function()
            playbackServer:run()
        end
    end

    parallel.waitForAll(table.unpack(tasks))
end

app._departureDurationSeconds = departureDurationSeconds

return app
