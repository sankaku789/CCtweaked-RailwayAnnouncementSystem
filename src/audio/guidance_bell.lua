local GuidanceBell = {}
GuidanceBell.__index = GuidanceBell

local REQUEST_TYPE = "guidance_bell"
local DEFAULT_PATH = "audio/guidance/bell.dfpwm"
local DEFAULT_INTERVAL_SECONDS = 5
local DEFAULT_PRIORITY = -1

-- function: Create a periodic guidance bell controller.
function GuidanceBell.new(options, logger)
    options = options or {}

    local intervalSeconds = tonumber(options.intervalSeconds) or DEFAULT_INTERVAL_SECONDS
    if intervalSeconds < 0 then
        intervalSeconds = DEFAULT_INTERVAL_SECONDS
    end

    local initialDelaySeconds = tonumber(options.initialDelaySeconds) or 0
    if initialDelaySeconds < 0 then
        initialDelaySeconds = 0
    end

    local path = type(options.path) == "string" and options.path or DEFAULT_PATH
    if path == "" then
        path = DEFAULT_PATH
    end

    return setmetatable({
        enabled = options.enabled == true,
        path = path,
        intervalSeconds = intervalSeconds,
        initialDelaySeconds = initialDelaySeconds,
        priority = tonumber(options.priority) or DEFAULT_PRIORITY,
        logger = logger,
    }, GuidanceBell)
end

-- function: Return whether the configured guidance bell audio file can be played.
function GuidanceBell:_validFile()
    return type(self.path) == "string"
        and self.path ~= ""
        and fs.exists(self.path)
        and not fs.isDir(self.path)
end

-- function: Return the playback items for one guidance bell request.
function GuidanceBell:compose()
    if not self:_validFile() then
        return {}, { "missing audio: " .. tostring(self.path) }
    end

    return { self.path }, {}
end

-- function: Periodically enqueue the lowest-priority guidance bell request.
function GuidanceBell:run(enqueue)
    if not self.enabled then
        return
    end

    if not self:_validFile() then
        if self.logger then
            self.logger.warn("Guidance bell disabled because audio was not found: " .. tostring(self.path))
        end
        return
    end

    if self.logger then
        self.logger.info(("Guidance bell enabled: interval=%.3fs priority=%s file=%s"):format(
            self.intervalSeconds,
            tostring(self.priority),
            self.path
        ))
    end

    if self.initialDelaySeconds > 0 then
        sleep(self.initialDelaySeconds)
    end

    while true do
        enqueue(REQUEST_TYPE, self.priority)
        sleep(self.intervalSeconds)
    end
end

return GuidanceBell
