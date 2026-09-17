local config = require("config")
local announcementPatterns = require("announcement_patterns.main")
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

-- function: Start and run the railway announcement application.
function app.run()
    log.info("Railway Announcement System starting.")

    local input = RailwayInput.new(config.input)
    local speakers = Speakers.connect(config.speaker, log)
    local trackState = TrackState.new(config.state)
    local queue = Queue.new()
    local resolver = Segment.new(config, segmentDefinitions, routeOptions)
    local composer = Composer.new(announcementPatterns, resolver)
    local player = Player.new(speakers, log)

    local adapter = loadAdapter()
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
