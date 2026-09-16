local Scheduler = {}
Scheduler.__index = Scheduler

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
    return setmetatable(options, Scheduler)
end

-- function: Return the priority threshold that may preempt periodic announcements.
function Scheduler:_preemptPriority()
    local queue = self.config.queue or {}
    return tonumber(queue.preemptPriority) or 100
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
function Scheduler:_enqueue(typeName)
    local priority = priorityFor(self.config, typeName)
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
        if self.logger then
            self.logger.warn(("Announcement skipped (%s): %s"):format(tostring(reason), typeName))
        end
        return false
    end

    if priority >= self:_preemptPriority() then
        self.queue:removeBelow(priority)
        self.player:interruptBelow(priority)
    end

    return true
end

-- function: Handle a NEXT bundled signal and advance the stopping-train state machine.
function Scheduler:_handleNext()
    local transition = self.trackState:advance()

    if self.logger then
        self.logger.info(("%s -> %s"):format(transition.previous, transition.state))
    end

    self:_handleStateChange()

    if transition.event == "approach" then
        self:_enqueue("approach")
    elseif transition.event == "departure" then
        self:_invalidateMetadata()
        self:_enqueue("departure")
    end

    if transition.resetTo and self.logger then
        self.logger.info("Track state automatically reset to " .. transition.resetTo)
    end
end

-- function: Handle a PASSING bundled signal without advancing the stopping-train state machine.
function Scheduler:_handlePassing()
    if self.logger then
        self.logger.info("Passing train signal received.")
    end

    self:_enqueue("passing")
end

-- function: Handle the direct reset button and return the stopping-train state to IDLE.
function Scheduler:_handleReset()
    local previous = self.trackState:get()
    self.trackState:reset()
    self:_invalidateMetadata()

    local priority = self:_preemptPriority()
    self.queue:removeBelow(priority)
    self.player:interruptBelow(priority)
    self:_handleStateChange()

    if self.logger then
        self.logger.info(("Track state manually reset: %s -> IDLE"):format(tostring(previous)))
    end
end

-- function: Monitor logical railway input events and dispatch their actions.
function Scheduler:monitorInput()
    while true do
        local event = self.input:waitForEvent()

        if event == "next" then
            self:_handleNext()
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
                        self:_enqueue(cfg.type)
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

-- function: Return metadata only for announcement types that require train information.
function Scheduler:_metadataFor(request)
    if request.type == "approach" or request.type == "next_train" then
        return self.metadataProvider:get(request)
    end

    return nil
end

-- function: Process queued announcements sequentially with priority-aware interruption.
function Scheduler:processQueue()
    while true do
        local request = self.queue:waitPop()
        local metadata = self:_metadataFor(request)
        local segments = self.composer:compose(request, metadata)

        if #segments == 0 then
            if self.logger then
                self.logger.warn("Announcement has no playable segments: " .. tostring(request.type))
            end
        else
            if self.logger then
                self.logger.info(("Playing %s announcement at priority %s (%d segment(s))."):format(
                    tostring(request.type),
                    tostring(request.priority),
                    #segments
                ))
            end

            local completed = self.player:playSegments(segments, request.priority)
            if not completed and self.logger then
                self.logger.info("Announcement interrupted: " .. tostring(request.type))
            end
        end
    end
end

-- function: Run input, periodic scheduling, and queue processing tasks in parallel.
function Scheduler:run()
    self:_resetPeriodicTimers()

    parallel.waitForAll(
        -- function: Run the railway input monitoring task.
        function()
            self:monitorInput()
        end,
        -- function: Run the periodic announcement scheduling task.
        function()
            self:monitorPeriodic()
        end,
        -- function: Run the announcement queue processing task.
        function()
            self:processQueue()
        end
    )
end

return Scheduler
