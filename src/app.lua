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

-- function: Calculate the internal departure delay from MTR dwell time and melody duration.
local function configureDepartureTiming(adapter, resolver)
    config.TIMEOUT_TIMING = 0

    if not adapter or type(adapter.getPlatformDwellTimeMs) ~= "function" then
        return
    end

    local melodySeconds, melodyPath, melodyError = departureMelodyDurationSeconds(resolver)
    if not melodySeconds then
        log.warn("Departure timing calculation skipped: " .. tostring(melodyError))
        return
    end

    local departureConfig = type(config.announcement) == "table" and config.announcement.departure or nil
    local leadSeconds = type(departureConfig) == "table" and tonumber(departureConfig.melodyEndLeadSeconds) or nil
    if leadSeconds == nil then
        leadSeconds = DEFAULT_DEPARTURE_MELODY_END_LEAD_SECONDS
    end
    leadSeconds = math.max(0, leadSeconds)

    local ok, dwellTimeMs = pcall(adapter.getPlatformDwellTimeMs, adapter, {
        track = config.trackNumber,
    })
    if not ok then
        log.warn("Departure timing calculation skipped: " .. tostring(dwellTimeMs))
        return
    end

    dwellTimeMs = tonumber(dwellTimeMs)
    if not dwellTimeMs or dwellTimeMs < 0 then
        log.warn("Departure timing calculation skipped: invalid MTR dwell time")
        return
    end

    local dwellSeconds = dwellTimeMs / 1000
    local delaySeconds = math.max(0, dwellSeconds - melodySeconds - leadSeconds)
    config.TIMEOUT_TIMING = delaySeconds

    log.event("Departure timing", ("track=%s dwell=%.3fs melody=%.3fs lead=%.3fs delay=%.3fs file=%s"):format(
        tostring(config.trackNumber),
        dwellSeconds,
        melodySeconds,
        leadSeconds,
        delaySeconds,
        melodyPath
    ))
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

    local adapter = loadAdapter()
    configureDepartureTiming(adapter, resolver)

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
    })

    scheduler:run()
end

return app
