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
        platformCount = nil,
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
            timing.platformCount = tonumber(profile.platformCount) or tonumber(profile.candidateCount)
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
        log.event("Departure timing", ("dynamic platforms=%s"):format(
            timing.platformCount and tostring(timing.platformCount) or "?"
        ))
        return timing
    end

    if timing.dwellTimeMs and timing.dwellTimeMs >= 0 and melodySeconds then
        local dwellSeconds = timing.dwellTimeMs / 1000
        timing.staticDelaySeconds = math.max(0, dwellSeconds - melodySeconds - leadSeconds)

        log.event("Departure timing", ("static platforms=%s dwell=%.1fs delay=%.1fs"):format(
            timing.platformCount and tostring(timing.platformCount) or "1",
            dwellSeconds,
            timing.staticDelaySeconds
        ))
    end

    return timing
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
    local player = Player.new(speakers, log)
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
    })

    scheduler:run()
end

return app
