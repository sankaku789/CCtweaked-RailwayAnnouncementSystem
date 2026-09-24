local Scheduler = {}
Scheduler.__index = Scheduler

local GUIDANCE_CHECK_SECONDS = 0.05
local DFPWM_BYTES_PER_SECOND = 6000
local DEFAULT_GUIDANCE_PATH = "audio/guidance/bell.dfpwm"
local DEFAULT_GUIDANCE_INTERVAL_SECONDS = 10
local DEFAULT_GUIDANCE_PRIORITY = -1
local REMOTE_GUIDANCE_INTERRUPT_PRIORITY = 0

-- function: Return the current UTC epoch time in milliseconds.
local function now()
    return os.epoch("utc")
end

-- function: Return the audible timeline duration from the first audio item onward.
local function playbackDurationSeconds(segments)
    local duration = 0
    local started = false

    for _, item in ipairs(segments or {}) do
        local path = nil

        if type(item) == "string" then
            path = item
        elseif type(item) == "table" and item.kind == "audio" then
            path = item.path
        elseif type(item) == "table" and item.kind == "pause" and started then
            duration = duration + math.max(0, tonumber(item.seconds) or 0)
        end

        if type(path) == "string" and path ~= "" and fs.exists(path) and not fs.isDir(path) then
            started = true
            duration = duration + (fs.getSize(path) / DFPWM_BYTES_PER_SECOND)
        end
    end

    if not started then
        return nil
    end

    return duration
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
    options.guidanceGeneration = 0
    options.guidanceDurationSeconds = nil

    -- Remote guidance constraints never mutate this computer's TrackState.
    options.remoteGuidanceBlocked = false
    options.remoteGuidanceResumeAt = nil

    -- This deadline is published to peers so bell-disabled computers can still
    -- contribute their local departure/next-train timing policy.
    options.sharedGuidanceResumeAt = nil

    return setmetatable(options, Scheduler)
end

-- function: Return the priority threshold that may preempt periodic announcements.
function Scheduler:_preemptPriority()
    local queue = self.config.queue or {}
    return tonumber(queue.preemptPriority) or 100
end

-- function: Return normalized guidance bell settings even when local playback is disabled.
function Scheduler:_readGuidanceConfig()
    local cfg = type(self.config.guidanceBell) == "table" and self.config.guidanceBell or {}
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

-- function: Set the next guidance bell deadline from an explicit epoch timestamp.
function Scheduler:_scheduleGuidanceFrom(baseEpoch, delaySeconds, reason)
    if not self.guidanceAvailable then
        self.guidanceNextAt = nil
        return
    end

    local base = tonumber(baseEpoch) or now()
    local delay = math.max(0, tonumber(delaySeconds) or 0)
    self.guidanceNextAt = base + (delay * 1000)

    local quiet = reason == "bell duration+interval" or reason == "bell fallback interval"
    if self.logger and not quiet then
        self.logger.event("Guidance", ("%s %.1fs"):format(
            tostring(reason or "scheduled"),
            delay
        ))
    end
end

-- function: Set the next guidance bell deadline from the current time.
function Scheduler:_scheduleGuidance(delaySeconds, reason)
    self:_scheduleGuidanceFrom(now(), delaySeconds, reason)
end

-- function: Remove queued guidance work and invalidate an older guidance cycle.
function Scheduler:_resetGuidanceCycle()
    self.guidanceGeneration = self.guidanceGeneration + 1
    self.guidanceNextAt = nil
    self.queue:removeTypes({ guidance_bell = true })
    self.guidanceQueued = false
end

-- function: Return the local resume deadline published to shared peers.
function Scheduler:getSharedGuidanceResumeAt()
    return tonumber(self.sharedGuidanceResumeAt)
end

-- function: Notify the shared coordinator about this computer's local policy state.
function Scheduler:_notifySharedTrackState(state, guidanceResumeAt)
    if type(self.sharedTrackNotifier) ~= "function" then
        return
    end

    local ok, err = pcall(self.sharedTrackNotifier, state, guidanceResumeAt)
    if not ok and self.logger then
        self.logger.warn("Shared track-state notification failed: " .. tostring(err))
    end
end

-- function: Return whether a remote platform, announcement, or resume delay suppresses the bell.
function Scheduler:_remoteGuidanceConstrained()
    local resumeAt = tonumber(self.remoteGuidanceResumeAt)
    return self.remoteGuidanceBlocked == true
        or (resumeAt ~= nil and resumeAt > now())
end

-- function: Apply remote guidance constraints without changing the local TrackState.
function Scheduler:setRemoteGuidanceGate(blocked, resumeAt)
    blocked = blocked == true
    resumeAt = tonumber(resumeAt)

    local currentTime = now()
    if resumeAt and resumeAt <= currentTime then
        resumeAt = nil
    end

    local oldBlocked = self.remoteGuidanceBlocked == true
    local oldResumeAt = tonumber(self.remoteGuidanceResumeAt)
    local oldHadConstraint = oldBlocked or oldResumeAt ~= nil
    local newHadConstraint = blocked or resumeAt ~= nil

    if oldBlocked == blocked and oldResumeAt == resumeAt then
        return
    end

    self.remoteGuidanceBlocked = blocked
    self.remoteGuidanceResumeAt = resumeAt

    if newHadConstraint then
        self:_resetGuidanceCycle()
        if self.currentRequestType == "guidance_bell" then
            self.player:interruptBelow(REMOTE_GUIDANCE_INTERRUPT_PRIORITY)
        end

        if self.logger and not oldHadConstraint then
            self.logger.event("Guidance", "shared suppression active")
        end
        return
    end

    if oldHadConstraint
        and self.guidanceAvailable
        and self.trackState:get() ~= "PLATFORM"
    then
        self:_resetGuidanceCycle()

        -- A stale hard block has no explicit deadline, so use the normal initial
        -- delay. A completed resume deadline already encoded its own delay.
        local delaySeconds = 0
        if oldBlocked and oldResumeAt == nil then
            delaySeconds = self.guidanceConfig.initialDelaySeconds
        end

        self:_scheduleGuidance(delaySeconds, "shared suppression cleared")
    end

    if self.logger and oldHadConstraint then
        self.logger.event("Guidance", "shared suppression cleared")
    end
end

-- function: Initialize guidance bell scheduling.
function Scheduler:_initializeGuidance()
    self.guidanceConfig = self:_readGuidanceConfig()

    if not self.guidanceConfig.enabled then
        return
    end

    if not self:_guidanceAudioAvailable(self.guidanceConfig.path) then
        if self.logger then
            self.logger.warn("Guidance bell disabled: audio unavailable")
        end
        return
    end

    self.guidanceDurationSeconds = fs.getSize(self.guidanceConfig.path) / DFPWM_BYTES_PER_SECOND
    self.guidanceAvailable = true
    self:_scheduleGuidance(self.guidanceConfig.initialDelaySeconds, "startup initial")

    if self.logger then
        self.logger.info(("Guidance bell enabled (initial=%.1fs interval=%.1fs)"):format(
            self.guidanceConfig.initialDelaySeconds,
            self.guidanceConfig.intervalSeconds
        ))
    end
end

-- function: Return whether a guidance request may be queued now.
function Scheduler:_guidanceDue()
    return self.guidanceAvailable
        and not self:_remoteGuidanceConstrained()
        and self.trackState:get() ~= "PLATFORM"
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

-- function: Queue an announcement request with configured priority and expiry.
function Scheduler:_enqueue(typeName, priorityOverride, requestOptions)
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

    if type(requestOptions) == "table" and requestOptions.departurePlayAt ~= nil then
        request.departurePlayAt = tonumber(requestOptions.departurePlayAt)
    end

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
    self.sharedGuidanceResumeAt = nil
    self:_notifySharedTrackState("PLATFORM", nil)
    self:_resetGuidanceCycle()

    if self.logger then
        self.logger.event("State", "PLATFORM (approach)")
    end

    self:_handleStateChange()
    self:_enqueue("approach")
end

-- function: Handle a DEPARTURE pulse and enable the IDLE periodic announcement mode.
function Scheduler:_handleDeparture()
    local departureAt = now()
    self.trackState:set("IDLE")

    if self.guidanceAvailable then
        self:_resetGuidanceCycle()
    end

    if self.logger then
        self.logger.event("State", "IDLE (departure)")
    end

    self:_handleStateChange()
    self:_invalidateMetadata()

    local departureDelaySeconds, dwellTimeMs = self:_resolveDepartureTiming()
    local dwellSeconds = 0
    local reason = "departure initial fallback"

    if dwellTimeMs and dwellTimeMs >= 0 then
        dwellSeconds = dwellTimeMs / 1000
        reason = "departure dwell+initial"
    elseif self.logger and self.guidanceAvailable then
        self.logger.warn("MTR dwell time unavailable; using departure initial fallback")
    end

    self.sharedGuidanceResumeAt = departureAt
        + ((dwellSeconds + self.guidanceConfig.initialDelaySeconds) * 1000)
    self:_notifySharedTrackState("IDLE", self.sharedGuidanceResumeAt)

    self:_enqueue("departure", nil, {
        departurePlayAt = departureAt + (departureDelaySeconds * 1000),
    })

    if self.guidanceAvailable then
        self:_scheduleGuidanceFrom(
            departureAt,
            dwellSeconds + self.guidanceConfig.initialDelaySeconds,
            reason
        )
    end
end

-- function: Handle a PASSING pulse without changing the periodic announcement mode.
function Scheduler:_handlePassing()
    if self.logger then
        self.logger.event("Passing", "signal")
    end

    self:_enqueue("passing")
end

-- function: Handle the direct reset button and enable the IDLE periodic announcement mode.
function Scheduler:_handleReset()
    local resetAt = now()
    self.trackState:set("IDLE")
    self:_invalidateMetadata()

    local priority = self:_preemptPriority()
    self.queue:removeBelow(priority)
    self.player:interruptBelow(priority)
    self:_handleStateChange()

    self.sharedGuidanceResumeAt = resetAt + (self.guidanceConfig.initialDelaySeconds * 1000)
    self:_notifySharedTrackState("IDLE", self.sharedGuidanceResumeAt)

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
            or self:_remoteGuidanceConstrained()
            or self.trackState:get() == "PLATFORM"
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
    if request.type == "next_train" then
        if not hadSegments then
            return
        end

        if not request.guidanceStartedAt or not completed then
            self.sharedGuidanceResumeAt = now()
                + (self.guidanceConfig.initialDelaySeconds * 1000)
            self:_notifySharedTrackState(
                self.trackState:get(),
                self.sharedGuidanceResumeAt
            )

            if self.guidanceAvailable
                and not self:_remoteGuidanceConstrained()
                and self.trackState:get() ~= "PLATFORM"
            then
                self:_scheduleGuidance(
                    self.guidanceConfig.initialDelaySeconds,
                    "next_train fallback initial"
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

    if self:_remoteGuidanceConstrained() or self.trackState:get() == "PLATFORM" then
        self.guidanceNextAt = nil
        return
    end

    if not request.guidanceStartedAt or not completed then
        self:_scheduleGuidance(self.guidanceConfig.intervalSeconds, "bell fallback interval")
    end
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
            local playAt = tonumber(request.departurePlayAt)
            local delaySeconds

            if playAt then
                delaySeconds = math.max(0, (playAt - now()) / 1000)
            else
                delaySeconds = math.max(0, tonumber(self.config.TIMEOUT_TIMING) or 0)
            end

            if delaySeconds > 0 then
                sleep(delaySeconds)
            end
        end

        local metadata = self:_metadataFor(request)
        local segments, diagnostics = self:_composeRequest(request, metadata)
        local hadSegments = #segments > 0
        local completed = true

        if hadSegments and request.type == "next_train" then
            request.guidanceDurationSeconds = playbackDurationSeconds(segments)

            if self.guidanceAvailable then
                self:_resetGuidanceCycle()
                request.guidanceGeneration = self.guidanceGeneration
            end
        end

        if not hadSegments then
            if self.logger and request.type ~= "guidance_bell" then
                self.logger.warn("Announcement has no playable segments: " .. tostring(request.type))
                for _, diagnostic in ipairs(diagnostics or {}) do
                    self.logger.warn("  - " .. tostring(diagnostic))
                end
            end
        else
            if self.logger and request.type ~= "guidance_bell" then
                self.logger.info("Playing: " .. tostring(request.type))
            end

            local onAudioStarted = nil
            if request.type == "guidance_bell" then
                onAudioStarted = function(startedAt)
                    if request.guidanceGeneration ~= self.guidanceGeneration then
                        return
                    end

                    request.guidanceStartedAt = startedAt
                    self:_scheduleGuidanceFrom(
                        startedAt,
                        self.guidanceDurationSeconds + self.guidanceConfig.intervalSeconds,
                        "bell duration+interval"
                    )
                end
            elseif request.type == "next_train" and request.guidanceDurationSeconds then
                onAudioStarted = function(startedAt)
                    request.guidanceStartedAt = startedAt
                    self.sharedGuidanceResumeAt = startedAt
                        + ((request.guidanceDurationSeconds
                            + self.guidanceConfig.initialDelaySeconds) * 1000)
                    self:_notifySharedTrackState(
                        self.trackState:get(),
                        self.sharedGuidanceResumeAt
                    )

                    if not self.guidanceAvailable
                        or request.guidanceGeneration ~= self.guidanceGeneration
                    then
                        return
                    end

                    self:_scheduleGuidanceFrom(
                        startedAt,
                        request.guidanceDurationSeconds + self.guidanceConfig.initialDelaySeconds,
                        "next_train duration+initial"
                    )
                end
            end

            completed = self.player:playSegments(
                segments,
                request.priority,
                onAudioStarted,
                request.type
            )

            if not completed and self.logger and request.type ~= "guidance_bell" then
                self.logger.info("Interrupted: " .. tostring(request.type))
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
