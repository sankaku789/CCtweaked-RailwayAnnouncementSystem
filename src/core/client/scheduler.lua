local Scheduler = {}
Scheduler.__index = Scheduler

local DEPARTURE_SCHEDULE_CHECK_SECONDS = 0.05
local APPROACH_TIMEOUT_SECONDS = 120
local APPROACH_TIMEOUT_CHECK_SECONDS = 0.25

local function now()
    return os.epoch("utc")
end

local function priorityFor(config, typeName)
    local queue = config.queue or {}
    local priorities = queue.priorities or {}
    return tonumber(priorities[typeName]) or 0
end

local function ttlFor(config, typeName)
    local queue = config.queue or {}
    local ttlMs = queue.ttlMs or {}
    return tonumber(ttlMs[typeName])
end

-- function: Create a client scheduler.
function Scheduler.new(options)
    options.periodicNextAt = {}
    options.currentRequestType = nil
    options.guidanceConfig = nil
    options.sharedGuidanceHold = false
    options.sharedGuidanceResumeAt = nil
    return setmetatable(options, Scheduler)
end

-- function: Return the priority threshold that prunes lower-priority queued work.
function Scheduler:_preemptPriority()
    local queue = self.config.queue or {}
    return tonumber(queue.preemptPriority) or 100
end

-- function: Read only the guidance timing needed by client-side suppression policy.
function Scheduler:_readGuidanceConfig()
    local cfg = type(self.config.guidanceBell) == "table" and self.config.guidanceBell or {}
    return {
        initialDelaySeconds = math.max(0, tonumber(cfg.initialDelaySeconds) or 0),
    }
end

function Scheduler:_initializeGuidance()
    self.guidanceConfig = self:_readGuidanceConfig()
end

-- function: Publish local track state together with the explicit guidance hold.
function Scheduler:_notifySharedTrackState(state, guidanceResumeAt, guidanceHold)
    if type(self.sharedTrackNotifier) ~= "function" then
        return
    end

    if guidanceHold == nil then
        guidanceHold = self.sharedGuidanceHold == true
    else
        guidanceHold = guidanceHold == true
    end

    local ok, err = pcall(
        self.sharedTrackNotifier,
        state,
        guidanceResumeAt,
        guidanceHold
    )
    if not ok and self.logger then
        self.logger.warn("Shared track-state notification failed: " .. tostring(err))
    end
end

-- function: Suppress shared guidance until the active announcement completes.
function Scheduler:_beginSharedGuidanceHold()
    self.sharedGuidanceHold = true
    self.sharedGuidanceResumeAt = nil
    self:_notifySharedTrackState(self.trackState:get(), nil, true)
end

-- function: Release shared guidance after an explicit post-announcement delay.
function Scheduler:_completeSharedGuidanceHold(delaySeconds)
    local resumeAt = now() + (math.max(0, tonumber(delaySeconds) or 0) * 1000)
    self.sharedGuidanceHold = false
    self.sharedGuidanceResumeAt = resumeAt
    self:_notifySharedTrackState(self.trackState:get(), resumeAt, false)
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
                self.periodicNextAt[name] = currentTime + math.max(0, initialDelayMs)
            else
                self.periodicNextAt[name] = nil
            end
        end
    end
end

function Scheduler:_handleStateChange()
    self:_dropPeriodicQueue()
    self:_resetPeriodicTimers()
end

function Scheduler:_invalidateMetadata()
    if self.metadataProvider and type(self.metadataProvider.invalidate) == "function" then
        self.metadataProvider:invalidate({ track = self.config.trackNumber })
    end
end

-- function: Resolve the dwell and departure-announcement delay for the current departure event.
function Scheduler:_resolveDepartureTiming()
    local timing = type(self.departureTiming) == "table" and self.departureTiming or {}
    local fallbackDelaySeconds = math.max(
        0,
        tonumber(timing.fallbackDelaySeconds) or tonumber(self.config.TIMEOUT_TIMING) or 0
    )
    local dwellTimeMs = tonumber(timing.dwellTimeMs)
    local delaySeconds = tonumber(timing.staticDelaySeconds) or fallbackDelaySeconds

    if timing.dynamic ~= true then
        return math.max(0, delaySeconds), dwellTimeMs
    end

    dwellTimeMs = nil
    local adapter = self.departureTimingAdapter
    local getter = nil

    if adapter and type(adapter.getCurrentPlatformDwellTimeMs) == "function" then
        getter = adapter.getCurrentPlatformDwellTimeMs
    elseif adapter and type(adapter.getPlatformDwellTimeMs) == "function" then
        getter = adapter.getPlatformDwellTimeMs
    end

    if getter then
        local ok, currentDwellTimeMs = pcall(getter, adapter, {
            track = self.config.trackNumber,
        })

        if ok then
            currentDwellTimeMs = tonumber(currentDwellTimeMs)
            if currentDwellTimeMs and currentDwellTimeMs >= 0 then
                dwellTimeMs = currentDwellTimeMs
            end
        elseif self.logger then
            self.logger.warn("Dynamic departure timing failed: " .. tostring(currentDwellTimeMs))
        end
    elseif self.logger then
        self.logger.warn("Dynamic departure timing is unavailable")
    end

    local departureSeconds = tonumber(timing.departureSeconds) or tonumber(timing.melodySeconds)
    local leadSeconds = math.max(0, tonumber(timing.leadSeconds) or 0)

    if dwellTimeMs and departureSeconds then
        delaySeconds = math.max(0, (dwellTimeMs / 1000) - departureSeconds - leadSeconds)
    else
        delaySeconds = fallbackDelaySeconds
    end

    if self.logger and dwellTimeMs then
        self.logger.event("Departure timing", ("dynamic dwell=%.1fs delay=%.1fs"):format(
            dwellTimeMs / 1000,
            delaySeconds
        ))
    end

    return delaySeconds, dwellTimeMs
end

-- function: Queue requests using strict priority supersession for this client.
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
        if self.logger then
            self.logger.warn(("Announcement skipped (%s): %s"):format(tostring(reason), typeName))
        end
        return false
    end

    if priority >= self:_preemptPriority() then
        self.queue:removeBelow(priority)
    end
    self.player:interruptBelow(priority)
    return true
end

-- function: Enter approach mode and suppress periodic announcements/guidance until departure is reserved.
function Scheduler:_handleApproach()
    self.stoppedMetadata = nil
    self.approachTimeoutAt = now() + (APPROACH_TIMEOUT_SECONDS * 1000)
    self.trackState:set("APPROACH")
    self:_handleStateChange()
    self:_beginSharedGuidanceHold()

    if self.logger then
        self.logger.event("State", "APPROACH (approach)")
    end

    self:_enqueue("approach")
end

-- function: Reserve departure playback without blocking the local announcement queue.
function Scheduler:_handleDeparture()
    local departureAt = now()
    local departureDelaySeconds = self:_resolveDepartureTiming()
    self.approachTimeoutAt = nil

    if self.trackState:get() ~= "PLATFORM" then
        self.trackState:set("PLATFORM")
        self:_handleStateChange()
    end

    self:_beginSharedGuidanceHold()
    self.player:interruptBelow(self:_preemptPriority())
    self.departureDueAt = departureAt + (math.max(0, departureDelaySeconds) * 1000)

    if self.logger then
        self.logger.event("State", "PLATFORM (departure reserved)")
        self.logger.event("Departure", ("scheduled %.1fs"):format(math.max(0, departureDelaySeconds)))
    end
end

function Scheduler:_handlePassing()
    if self.logger then
        self.logger.event("Passing", "signal")
    end
    self:_enqueue("passing")
end

-- function: End the stopped-announcement metadata session and any pending departure on reset.
function Scheduler:_handleReset()
    local resetAt = now()
    self.departureDueAt = nil
    self.approachTimeoutAt = nil
    self.stoppedMetadata = nil
    self.sharedGuidanceHold = false
    self.trackState:set("IDLE")
    self:_invalidateMetadata()

    local priority = self:_preemptPriority()
    self.queue:removeBelow(priority)
    self.player:interruptBelow(priority)
    self:_handleStateChange()

    local guidance = self.guidanceConfig or self:_readGuidanceConfig()
    self.sharedGuidanceResumeAt = resetAt + (guidance.initialDelaySeconds * 1000)
    self:_notifySharedTrackState("IDLE", self.sharedGuidanceResumeAt, false)

    if self.logger then
        self.logger.event("State", "IDLE (manual reset)")
    end
end

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
                    local intervalMs = tonumber(cfg.intervalMs) or 0
                    local initialDelayMs = tonumber(cfg.initialDelayMs)
                    if initialDelayMs == nil then
                        initialDelayMs = intervalMs
                    end

                    local dueAt = self.periodicNextAt[name]
                    if dueAt == nil then
                        self.periodicNextAt[name] = currentTime + math.max(0, initialDelayMs)
                    elseif currentTime >= dueAt then
                        local queued = self:_enqueue(cfg.type)
                        if queued and self.logger then
                            self.logger.event("Periodic", tostring(cfg.type))
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

-- function: Cancel a not-yet-submitted departure reservation.
function Scheduler:_cancelDepartureSchedule()
    self.departureDueAt = nil
end

-- function: Submit the reserved departure only when its playback deadline arrives.
function Scheduler:_dispatchDepartureIfDue(currentTime)
    local dueAt = tonumber(self.departureDueAt)
    currentTime = tonumber(currentTime) or now()

    if not dueAt or currentTime < dueAt then
        return false
    end

    self.departureDueAt = nil
    return self:_enqueue("departure")
end

function Scheduler:monitorDepartureSchedule()
    while true do
        self:_dispatchDepartureIfDue(now())
        sleep(DEPARTURE_SCHEDULE_CHECK_SECONDS)
    end
end

-- function: Return an approach state to IDLE after its safety timeout.
function Scheduler:_handleApproachTimeout()
    if self.trackState:get() ~= "APPROACH" then
        self.approachTimeoutAt = nil
        return false
    end

    self.approachTimeoutAt = nil
    self.queue:removeTypes({ approach = true })

    if self.currentRequestType == "approach" then
        self.player:interruptBelow(priorityFor(self.config, "approach") + 1)
    end

    self.stoppedMetadata = nil
    self.trackState:set("IDLE")
    self:_handleStateChange()
    self:_invalidateMetadata()

    local guidance = self.guidanceConfig or self:_readGuidanceConfig()
    self:_completeSharedGuidanceHold(guidance.initialDelaySeconds)

    if self.logger then
        self.logger.event("State", "IDLE (approach timeout)")
    end

    return true
end

function Scheduler:monitorApproachTimeout()
    while true do
        local timeoutAt = tonumber(self.approachTimeoutAt)
        if timeoutAt and now() >= timeoutAt then
            self:_handleApproachTimeout()
        end
        sleep(APPROACH_TIMEOUT_CHECK_SECONDS)
    end
end

-- function: End the stopped metadata session and return to next-train mode after departure playback.
function Scheduler:_finishDepartureState()
    self:_cancelDepartureSchedule()
    self.approachTimeoutAt = nil
    self.stoppedMetadata = nil
    self.trackState:set("IDLE")
    self:_handleStateChange()
    self:_invalidateMetadata()

    if self.logger then
        self.logger.event("State", "IDLE (departure complete)")
    end
end

-- function: Preserve stopped-train metadata while always refreshing next-train metadata.
function Scheduler:_metadataFor(request)
    if request.type == "next_train" then
        self:_invalidateMetadata()
        return self.metadataProvider:get(request)
    end

    if request.type == "stopped_train" or request.type == "stopped" then
        if self.stoppedMetadata then
            return self.stoppedMetadata
        end

        local metadata = self.metadataProvider:get(request)
        if metadata then
            self.stoppedMetadata = metadata
        end
        return metadata
    end

    if request.type == "approach" then
        local metadata = self.metadataProvider:get(request)
        if metadata then
            self.stoppedMetadata = metadata
        end
        return metadata
    end

    return nil
end

-- function: Resolve one request and begin a hard guidance hold for next-train playback.
function Scheduler:_composeRequest(request, metadata)
    local segments, diagnostics = self.composer:compose(request, metadata)
    if #segments > 0 and request.type == "next_train" then
        self:_beginSharedGuidanceHold()
        request.sharedGuidanceHoldStarted = true
    end
    return segments, diagnostics
end

-- function: Complete state/guidance transitions after playback finishes.
function Scheduler:_afterRequest(request, completed, hadSegments)
    local guidance = self.guidanceConfig or self:_readGuidanceConfig()

    if request.type == "departure" then
        self:_finishDepartureState()
        local timing = type(self.departureTiming) == "table" and self.departureTiming or {}
        local leadSeconds = math.max(0, tonumber(timing.leadSeconds) or 0)
        self:_completeSharedGuidanceHold(leadSeconds + guidance.initialDelaySeconds)
        return
    end

    if request.type == "next_train" and request.sharedGuidanceHoldStarted then
        self:_completeSharedGuidanceHold(guidance.initialDelaySeconds)
        return
    end

    if request.type == "passing" and completed and hadSegments then
        local resumeAt = now() + (guidance.initialDelaySeconds * 1000)
        self.sharedGuidanceResumeAt = resumeAt
        self:_notifySharedTrackState(self.trackState:get(), resumeAt, false)
    end
end

-- function: Process local requests while delegating actual playback to the elected server.
function Scheduler:processQueue()
    while true do
        local request = self.queue:waitPop()
        self.currentRequestType = request.type

        local metadata = self:_metadataFor(request)
        local segments, diagnostics = self:_composeRequest(request, metadata)
        local hadSegments = #segments > 0
        local completed = true

        if not hadSegments then
            if self.logger then
                self.logger.warn("Announcement has no playable segments: " .. tostring(request.type))
                for _, diagnostic in ipairs(diagnostics or {}) do
                    self.logger.warn("  - " .. tostring(diagnostic))
                end
            end
        else
            if self.logger then
                self.logger.info("Submitting: " .. tostring(request.type))
            end

            completed = self.player:playSegments(
                segments,
                request.priority,
                nil,
                request.type,
                request.expiresAt
            )

            if not completed and self.logger then
                self.logger.info("Interrupted: " .. tostring(request.type))
            end
        end

        self:_afterRequest(request, completed, hadSegments)
        self.currentRequestType = nil
    end
end

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
            self:processQueue()
        end,
        function()
            self:monitorDepartureSchedule()
        end,
        function()
            self:monitorApproachTimeout()
        end
    )
end

return Scheduler
