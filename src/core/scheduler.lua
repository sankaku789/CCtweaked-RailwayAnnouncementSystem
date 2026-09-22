local Scheduler = {}
Scheduler.__index = Scheduler

local GUIDANCE_CHECK_SECONDS = 0.05
local DEFAULT_GUIDANCE_PATH = "audio/guidance/bell.dfpwm"
local DEFAULT_GUIDANCE_INTERVAL_SECONDS = 10
local DEFAULT_GUIDANCE_PRIORITY = -1

-- function: Return the current UTC epoch time in milliseconds.
local function now()
    return os.epoch("utc")
end

-- function: Return the configured priority for an announcement type.
local function priorityFor(config, typeName)
    local queue = config.queue or {}
    local priorities = queue.priorities or {}
    return tonumber(priorities[typeName]) or 0
end

-- function: Return the configured TTL in milliseconds for an announcement type.
local function ttlFor(config, typeName)
    local queue = config.queue or {}
    local ttlMs = queue.ttlMs or {}
    return tonumber(ttlMs[typeName])
end

-- function: Create a scheduler from the application components.
function Scheduler.new(options)
    options.periodicNextAt = {}
    options.currentRequestType = nil

    options.guidanceConfig = nil
    options.guidanceAvailable = false
    options.guidanceQueued = false
    options.guidanceNextAt = nil
    options.guidanceWaitingForDeparture = false
    options.guidanceGeneration = 0

    return setmetatable(options, Scheduler)
end

-- function: Return the priority threshold that may preempt periodic announcements.
function Scheduler:_preemptPriority()
    local queue = self.config.queue or {}
    return tonumber(queue.preemptPriority) or 100
end

-- function: Return normalized guidance bell settings.
function Scheduler:_readGuidanceConfig()
    local cfg = self.config.guidanceBell
    if type(cfg) ~= "table" then
        return { enabled = false }
    end

    local path = type(cfg.path) == "string" and cfg.path or DEFAULT_GUIDANCE_PATH
    if path == "" then
        path = DEFAULT_GUIDANCE_PATH
    end

    local intervalSeconds = tonumber(cfg.intervalSeconds)
    if not intervalSeconds or intervalSeconds <= 0 then
        intervalSeconds = DEFAULT_GUIDANCE_INTERVAL_SECONDS
    end

    return {
        enabled = cfg.enabled == true,
        path = path,
        initialDelaySeconds = math.max(0, tonumber(cfg.initialDelaySeconds) or 0),
        intervalSeconds = intervalSeconds,
        priority = tonumber(cfg.priority) or DEFAULT_GUIDANCE_PRIORITY,
    }
end

-- function: Return whether one file can be used as guidance bell audio.
function Scheduler:_guidanceAudioAvailable(path)
    return type(path) == "string"
        and path ~= ""
        and fs.exists(path)
        and not fs.isDir(path)
end

-- function: Set the next guidance bell deadline from the current time.
function Scheduler:_scheduleGuidance(delaySeconds, reason)
    if not self.guidanceAvailable then
        self.guidanceNextAt = nil
        return
    end

    local delay = math.max(0, tonumber(delaySeconds) or 0)
    self.guidanceNextAt = now() + (delay * 1000)

    if self.logger then
        self.logger.event("Guidance timer", ("%s %.3fs"):format(
            tostring(reason or "scheduled"),
            delay
        ))
    end
end

-- function: Remove queued guidance work and invalidate older guidance playback callbacks.
function Scheduler:_resetGuidanceCycle()
    self.guidanceGeneration = self.guidanceGeneration + 1
    self.guidanceNextAt = nil
    self.queue:removeTypes({ guidance_bell = true })
    self.guidanceQueued = false
end

-- function: Initialize guidance bell scheduling.
function Scheduler:_initializeGuidance()
    self.guidanceConfig = self:_readGuidanceConfig()

    if not self.guidanceConfig.enabled then
        return
    end

    if not self:_guidanceAudioAvailable(self.guidanceConfig.path) then
        if self.logger then
            self.logger.warn("Guidance bell disabled because audio is unavailable: " .. tostring(self.guidanceConfig.path))
        end
        return
    end

    self.guidanceAvailable = true
    self:_scheduleGuidance(self.guidanceConfig.initialDelaySeconds, "startup initial")

    if self.logger then
        self.logger.info(("Guidance bell enabled: initialDelay=%.3fs interval=%.3fs priority=%s file=%s"):format(
            self.guidanceConfig.initialDelaySeconds,
            self.guidanceConfig.intervalSeconds,
            tostring(self.guidanceConfig.priority),
            self.guidanceConfig.path
        ))
    end
end

-- function: Return whether a guidance request may be queued now.
function Scheduler:_guidanceDue()
    return self.guidanceAvailable
        and self.trackState:get() ~= "PLATFORM"
        and not self.guidanceWaitingForDeparture
        and not self.guidanceQueued
        and self.currentRequestType == nil
        and self.queue:size() == 0
        and self.guidanceNextAt ~= nil
        and now() >= self.guidanceNextAt
end

-- function: Remove queued periodic announcement requests.
function Scheduler:_dropPeriodicQueue()
    local types = {}

    for _, cfg in pairs(self.config.periodic or {}) do
        if type(cfg) == "table" and type(cfg.type) == "string" then
            types[cfg.type] = true
        end
    end

    return self.queue:removeTypes(types)
end

-- function: Reset periodic announcement deadlines for the current track state.
function Scheduler:_resetPeriodicTimers()
    local currentState = self.trackState:get()
    local currentTime = now()

    for name, cfg in pairs(self.config.periodic or {}) do
        if type(cfg) == "table" and type(cfg.type) == "string" then
            if cfg.enabled == true and cfg.state == currentState then
                local intervalMs = tonumber(cfg.intervalMs) or 0
                local initialDelayMs = tonumber(cfg.initialDelayMs)

                if initialDelayMs == nil then
                    initialDelayMs = intervalMs
                end

                if initialDelayMs < 0 then
                    initialDelayMs = 0
                end

                self.periodicNextAt[name] = currentTime + initialDelayMs
            else
                self.periodicNextAt[name] = nil
            end
        end
    end
end

-- function: Clear stale periodic work after a track state transition.
function Scheduler:_handleStateChange()
    self:_dropPeriodicQueue()
    self:_resetPeriodicTimers()
end

-- function: Invalidate cached metadata for the configured track when supported.
function Scheduler:_invalidateMetadata()
    if self.metadataProvider and type(self.metadataProvider.invalidate) == "function" then
        self.metadataProvider:invalidate({ track = self.config.trackNumber })
    end
end

-- function: Queue an announcement request with configured priority and expiry.
function Scheduler:_enqueue(typeName, priorityOverride)
    local priority = tonumber(priorityOverride)
    if priority == nil then
        priority = priorityFor(self.config, typeName)
    end

    local ttl = ttlFor(self.config, typeName)
    local createdAt = now()

    local request = {
        type = typeName,
        track = self.config.trackNumber,
        priority = priority,
        createdAt = createdAt,
    }

    if typeName == "guidance_bell" then
        request.guidanceGeneration = self.guidanceGeneration
    end

    if ttl and ttl > 0 then
        request.expiresAt = createdAt + ttl
    end

    local ok, reason = self.queue:enqueue(request)
    if not ok then
        if self.logger and not (typeName == "guidance_bell" and reason == "duplicate") then
            self.logger.warn(("Announcement skipped (%s): %s"):format(tostring(reason), typeName))
        end
        return false
    end

    if typeName == "guidance_bell" then
        self.guidanceQueued = true
        self.guidanceNextAt = nil
    end

    if priority >= self:_preemptPriority() then
        self.queue:removeBelow(priority)
        if self.guidanceQueued and self.guidanceConfig and priority > self.guidanceConfig.priority then
            self.guidanceQueued = false
        end
        self.player:interruptBelow(priority)
    end

    return true
end

-- function: Handle an APPROACH pulse and enable the PLATFORM periodic announcement mode.
function Scheduler:_handleApproach()
    self.trackState:set("PLATFORM")
    self.guidanceWaitingForDeparture = false
    self:_resetGuidanceCycle()

    if self.logger then
        self.logger.event("State", "PLATFORM (approach)")
    end

    self:_handleStateChange()
    self:_enqueue("approach")
end

-- function: Handle a DEPARTURE pulse and enable the IDLE periodic announcement mode.
function Scheduler:_handleDeparture()
    self.trackState:set("IDLE")

    if self.guidanceAvailable then
        self:_resetGuidanceCycle()
        self.guidanceWaitingForDeparture = true
    end

    if self.logger then
        self.logger.event("State", "IDLE (departure)")
    end

    self:_handleStateChange()
    self:_invalidateMetadata()
    self:_enqueue("departure")
end

-- function: Handle a PASSING pulse without changing the periodic announcement mode.
function Scheduler:_handlePassing()
    if self.logger then
        self.logger.event("Passing", ("signal received (track=%s)"):format(tostring(self.config.trackNumber)))
    end

    self:_enqueue("passing")
end

-- function: Handle the direct reset button and enable the IDLE periodic announcement mode.
function Scheduler:_handleReset()
    self.trackState:set("IDLE")
    self.guidanceWaitingForDeparture = false
    self:_invalidateMetadata()

    local priority = self:_preemptPriority()
    self.queue:removeBelow(priority)
    self.player:interruptBelow(priority)
    self:_handleStateChange()

    if self.guidanceAvailable then
        self:_resetGuidanceCycle()
        self:_scheduleGuidance(self.guidanceConfig.initialDelaySeconds, "reset initial")
    end

    if self.logger then
        self.logger.event("State", "IDLE (manual reset)")
    end
end

-- function: Monitor logical railway input events and dispatch their actions.
function Scheduler:monitorInput()
    while true do
        local event = self.input:waitForEvent()

        if event == "approach" then
            self:_handleApproach()
        elseif event == "departure" then
            self:_handleDeparture()
        elseif event == "passing" then
            self:_handlePassing()
        elseif event == "reset" then
            self:_handleReset()
        elseif self.logger then
            self.logger.warn("Unknown railway input event: " .. tostring(event))
        end
    end
end

-- function: Queue low-priority announcements when their configured state timer expires.
function Scheduler:monitorPeriodic()
    local checkInterval = tonumber((self.config.periodic or {}).checkIntervalSeconds) or 1
    if checkInterval <= 0 then
        checkInterval = 1
    end

    while true do
        local currentTime = now()
        local currentState = self.trackState:get()

        for name, cfg in pairs(self.config.periodic or {}) do
            if type(cfg) == "table" and type(cfg.type) == "string" then
                if cfg.enabled == true and cfg.state == currentState then
                    local dueAt = self.periodicNextAt[name]
                    local intervalMs = tonumber(cfg.intervalMs) or 0

                    if dueAt == nil then
                        local initialDelayMs = tonumber(cfg.initialDelayMs)
                        if initialDelayMs == nil then
                            initialDelayMs = intervalMs
                        end
                        self.periodicNextAt[name] = currentTime + math.max(0, initialDelayMs)
                    elseif currentTime >= dueAt then
                        local queued = self:_enqueue(cfg.type)
                        if queued and self.logger then
                            self.logger.event("Periodic", ("%s fired (state=%s)"):format(
                                tostring(cfg.type),
                                tostring(currentState)
                            ))
                        end
                        self.periodicNextAt[name] = currentTime + math.max(1000, intervalMs)
                    end
                else
                    self.periodicNextAt[name] = nil
                end
            end
        end

        sleep(checkInterval)
    end
end

-- function: Queue the guidance bell only when no normal announcement is active or waiting.
function Scheduler:monitorGuidanceBell()
    if not self.guidanceAvailable then
        return
    end

    while true do
        if self:_guidanceDue() then
            self:_enqueue("guidance_bell", self.guidanceConfig.priority)
        end

        sleep(GUIDANCE_CHECK_SECONDS)
    end
end

-- function: Return metadata only for announcement types that require train information.
function Scheduler:_metadataFor(request)
    if request.type == "approach"
        or request.type == "stopped"
        or request.type == "next_train"
    then
        return self.metadataProvider:get(request)
    end

    return nil
end

-- function: Resolve playback items for one queued request.
function Scheduler:_composeRequest(request, metadata)
    if request.type == "guidance_bell" then
        if not self.guidanceAvailable
            or self.trackState:get() == "PLATFORM"
            or self.guidanceWaitingForDeparture
            or request.guidanceGeneration ~= self.guidanceGeneration
        then
            return {}, {}
        end

        return { self.guidanceConfig.path }, {}
    end

    return self.composer:compose(request, metadata)
end

-- function: Complete guidance timing transitions after one request finishes.
function Scheduler:_afterRequest(request, completed, hadSegments)
    if request.type == "departure" then
        if self.guidanceWaitingForDeparture then
            self.guidanceWaitingForDeparture = false
            self.guidanceNextAt = nil

            if self.guidanceAvailable and self.trackState:get() ~= "PLATFORM" then
                self:_scheduleGuidance(
                    self.guidanceConfig.initialDelaySeconds,
                    "departure initial"
                )
            end
        end
        return
    end

    if request.type ~= "guidance_bell" then
        return
    end

    if request.guidanceGeneration ~= self.guidanceGeneration then
        return
    end

    if not hadSegments then
        return
    end

    if self.trackState:get() == "PLATFORM" or self.guidanceWaitingForDeparture then
        self.guidanceNextAt = nil
        return
    end

    -- intervalSeconds is the quiet interval from the actual end of this bell
    -- to the start of the next bell. Player returns only after its completion
    -- barrier has been accepted by every connected speaker.
    self:_scheduleGuidance(self.guidanceConfig.intervalSeconds, "bell interval")
end

-- function: Process queued announcements sequentially with priority-aware interruption.
function Scheduler:processQueue()
    while true do
        local request = self.queue:waitPop()
        self.currentRequestType = request.type

        if request.type == "guidance_bell" then
            self.guidanceQueued = false
        end

        if request.type == "departure" then
            local delaySeconds = tonumber(self.config.TIMEOUT_TIMING) or 0
            if delaySeconds > 0 then
                sleep(delaySeconds)
            end
        end

        local metadata = self:_metadataFor(request)
        local segments, diagnostics = self:_composeRequest(request, metadata)
        local hadSegments = #segments > 0
        local completed = true

        if not hadSegments then
            if self.logger and request.type ~= "guidance_bell" then
                self.logger.warn("Announcement has no playable segments: " .. tostring(request.type))
                for _, diagnostic in ipairs(diagnostics or {}) do
                    self.logger.warn("  - " .. tostring(diagnostic))
                end
            end
        else
            if self.logger and request.type ~= "guidance_bell" then
                self.logger.info(("Playing %s announcement at priority %s (%d segment(s))."):format(
                    tostring(request.type),
                    tostring(request.priority),
                    #segments
                ))
            end

            completed = self.player:playSegments(segments, request.priority)

            if not completed and self.logger and request.type ~= "guidance_bell" then
                self.logger.info("Announcement interrupted: " .. tostring(request.type))
            end
        end

        self:_afterRequest(request, completed, hadSegments)
        self.currentRequestType = nil
    end
end

-- function: Run input, periodic scheduling, guidance scheduling, and queue processing tasks in parallel.
function Scheduler:run()
    self:_resetPeriodicTimers()
    self:_initializeGuidance()

    parallel.waitForAll(
        function()
            self:monitorInput()
        end,
        function()
            self:monitorPeriodic()
        end,
        function()
            self:monitorGuidanceBell()
        end,
        function()
            self:processQueue()
        end
    )
end

return Scheduler
