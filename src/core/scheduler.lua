local Scheduler = {}
Scheduler.__index = Scheduler

local GUIDANCE_CHECK_SECONDS = 0.05

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
    options.guidancePlaying = false
    options.guidanceAvailable = false
    options.guidanceNextAt = nil
    options.guidanceResumeAfterDeparture = false
    return setmetatable(options, Scheduler)
end

-- function: Return the priority threshold that may preempt periodic announcements.
function Scheduler:_preemptPriority()
    local queue = self.config.queue or {}
    return tonumber(queue.preemptPriority) or 100
end

-- function: Return whether the guidance bell is configured to run.
function Scheduler:_guidanceBellEnabled()
    return self.guidanceBell ~= nil and self.guidanceBell.enabled == true
end

-- function: Return whether guidance bell audio may play in the current state.
function Scheduler:_guidanceBellPlaybackAllowed()
    return self.guidanceAvailable
        and self.trackState:get() ~= "PLATFORM"
        and not self.guidanceResumeAfterDeparture
end

-- function: Return whether the next guidance bell playback is due.
function Scheduler:_guidanceBellDue()
    return self:_guidanceBellPlaybackAllowed()
        and not self.guidancePlaying
        and self.guidanceNextAt ~= nil
        and now() >= self.guidanceNextAt
end

-- function: Schedule the next guidance bell after the given delay.
function Scheduler:_scheduleGuidanceBell(delaySeconds)
    if not self.guidanceAvailable then
        self.guidanceNextAt = nil
        return
    end

    delaySeconds = tonumber(delaySeconds) or 0
    self.guidanceNextAt = now() + (math.max(0, delaySeconds) * 1000)
end

-- function: Schedule the first guidance bell after startup or a PLATFORM to IDLE transition.
function Scheduler:_scheduleGuidanceBellInitialDelay()
    local delaySeconds = self.guidanceBell and self.guidanceBell.initialDelaySeconds or 0
    self:_scheduleGuidanceBell(delaySeconds)
end

-- function: Schedule the next guidance bell from the start of the previous playback.
function Scheduler:_scheduleGuidanceBellInterval()
    local delaySeconds = self.guidanceBell and self.guidanceBell.intervalSeconds or 0
    self:_scheduleGuidanceBell(delaySeconds)
end

-- function: Validate and initialize the guidance bell playback schedule.
function Scheduler:_initializeGuidanceBell()
    if not self:_guidanceBellEnabled() then
        return
    end

    local segments, diagnostics = self.guidanceBell:compose()
    if #segments == 0 then
        if self.logger then
            self.logger.warn("Guidance bell disabled because audio is unavailable.")
            for _, diagnostic in ipairs(diagnostics or {}) do
                self.logger.warn("  - " .. tostring(diagnostic))
            end
        end
        return
    end

    self.guidanceAvailable = true

    if self.logger then
        self.logger.info(("Guidance bell enabled: initialDelay=%.3fs interval=%.3fs priority=%s"):format(
            tonumber(self.guidanceBell.initialDelaySeconds) or 0,
            tonumber(self.guidanceBell.intervalSeconds) or 0,
            tostring(self.guidanceBell.priority)
        ))
    end

    self:_scheduleGuidanceBellInitialDelay()
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

    if typeName ~= "guidance_bell" then
        self.queue:removeTypes({ guidance_bell = true })

        if self.guidancePlaying then
            self.player:interruptBelow(priority)
        end
    end

    if priority >= self:_preemptPriority() then
        self.queue:removeBelow(priority)
        self.player:interruptBelow(priority)
    end

    return true
end

-- function: Handle an APPROACH pulse and enable the PLATFORM periodic announcement mode.
function Scheduler:_handleApproach()
    self.guidanceNextAt = nil
    self.guidanceResumeAfterDeparture = false
    self.queue:removeTypes({ guidance_bell = true })
    self.trackState:set("PLATFORM")

    if self.logger then
        self.logger.event("State", "PLATFORM (approach)")
    end

    self:_handleStateChange()
    self:_enqueue("approach")
end

-- function: Handle a DEPARTURE pulse and enable the IDLE periodic announcement mode.
function Scheduler:_handleDeparture()
    local previousState = self.trackState:get()
    self.trackState:set("IDLE")

    if previousState == "PLATFORM" and self:_guidanceBellEnabled() then
        self.guidanceResumeAfterDeparture = true
        self:_scheduleGuidanceBellInitialDelay()
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
    local previousState = self.trackState:get()
    self.trackState:set("IDLE")
    self.guidanceResumeAfterDeparture = false
    self:_invalidateMetadata()

    local priority = self:_preemptPriority()
    self.queue:removeBelow(priority)
    self.player:interruptBelow(priority)
    self:_handleStateChange()

    if previousState == "PLATFORM" then
        self:_scheduleGuidanceBellInitialDelay()
    else
        self:_scheduleGuidanceBellInterval()
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

-- function: Queue the guidance bell when its configured absolute deadline expires.
function Scheduler:monitorGuidanceBell()
    if not self.guidanceAvailable then
        return
    end

    while true do
        if self:_guidanceBellDue() then
            self:_enqueue("guidance_bell", self.guidanceBell.priority)
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
    if request.type == "guidance_bell" and self.guidanceBell then
        if not self:_guidanceBellPlaybackAllowed() then
            return {}, {}
        end

        return self.guidanceBell:compose()
    end

    return self.composer:compose(request, metadata)
end

-- function: Resume guidance bell playback after a departure announcement without shifting its deadline.
function Scheduler:_afterPlayback(request)
    if request.type == "departure" and self.guidanceResumeAfterDeparture then
        self.guidanceResumeAfterDeparture = false
    end
end

-- function: Process queued announcements sequentially with priority-aware interruption.
function Scheduler:processQueue()
    while true do
        local request = self.queue:waitPop()

        if request.type == "departure" then
            local delaySeconds = tonumber(self.config.TIMEOUT_TIMING) or 0
            if delaySeconds > 0 then
                sleep(delaySeconds)
            end
        end

        local metadata = self:_metadataFor(request)
        local segments, diagnostics = self:_composeRequest(request, metadata)

        if #segments == 0 then
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

            self.guidancePlaying = request.type == "guidance_bell"
            if self.guidancePlaying then
                self:_scheduleGuidanceBellInterval()
            end

            local completed = self.player:playSegments(segments, request.priority)
            self.guidancePlaying = false

            if not completed and self.logger and request.type ~= "guidance_bell" then
                self.logger.info("Announcement interrupted: " .. tostring(request.type))
            end
        end

        self:_afterPlayback(request)
    end
end

-- function: Run input, periodic scheduling, guidance bell scheduling, and queue processing tasks in parallel.
function Scheduler:run()
    self:_resetPeriodicTimers()
    self:_initializeGuidanceBell()

    parallel.waitForAll(
        -- function: Run the railway input monitoring task.
        function()
            self:monitorInput()
        end,
        -- function: Run the periodic announcement scheduling task.
        function()
            self:monitorPeriodic()
        end,
        -- function: Run the guidance bell scheduling task.
        function()
            self:monitorGuidanceBell()
        end,
        -- function: Run the announcement queue processing task.
        function()
            self:processQueue()
        end
    )
end

return Scheduler
