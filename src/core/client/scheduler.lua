local Scheduler = require("core.guidance_scheduler")

local DFPWM_BYTES_PER_SECOND = 6000
local DEPARTURE_SCHEDULE_CHECK_SECONDS = 0.05

local originalAfterRequest = Scheduler._afterRequest
local originalHandleReset = Scheduler._handleReset
local originalMetadataFor = Scheduler._metadataFor
local originalRun = Scheduler.run

local function now()
    return os.epoch("utc")
end

local function playbackDurationSeconds(segments)
    local duration = 0
    local started = false

    for _, item in ipairs(segments or {}) do
        local path = nil

        if type(item) == "string" then
            path = item
        elseif type(item) == "table"
            and (item.kind == "audio" or item.kind == "client_asset")
        then
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

-- function: Keep approach as an IDLE-state announcement and start a new stopped metadata snapshot.
function Scheduler:_handleApproach()
    self.stoppedMetadata = nil

    -- TrackState starts as UNKNOWN after a cold boot. The first confirmed
    -- approach establishes IDLE/next-train mode without starting stopped mode.
    if self.trackState:get() == "UNKNOWN" then
        self.trackState:set("IDLE")
        self:_handleStateChange()

        if self.logger then
            self.logger.event("State", "IDLE (initial approach)")
        end
    end

    if self.logger then
        self.logger.event("Approach", "signal")
    end

    self:_enqueue("approach")
end

-- function: Reserve departure playback without blocking the local announcement queue.
function Scheduler:_handleDeparture()
    local departureAt = now()
    local departureDelaySeconds = self:_resolveDepartureTiming()

    if self.trackState:get() ~= "PLATFORM" then
        self.trackState:set("PLATFORM")
        self:_handleStateChange()
    end

    -- Departure reservation is the point where next-train mode ends and
    -- stopped-announcement mode begins. Keep the shared bell suppressed until
    -- the actual departure announcement reaches a terminal lifecycle event.
    self:_beginSharedGuidanceHold()

    -- Stop an active lower-priority periodic announcement, but do not disturb an
    -- equal-priority approach/passing announcement while the melody is only reserved.
    self.player:interruptBelow(self:_preemptPriority())

    self.departureDueAt = departureAt + (math.max(0, departureDelaySeconds) * 1000)

    if self.logger then
        self.logger.event("State", "PLATFORM (departure reserved)")
        self.logger.event("Departure", ("scheduled %.1fs"):format(math.max(0, departureDelaySeconds)))
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

-- function: Watch the departure reservation independently from normal queue processing.
function Scheduler:monitorDepartureSchedule()
    while true do
        self:_dispatchDepartureIfDue(now())
        sleep(DEPARTURE_SCHEDULE_CHECK_SECONDS)
    end
end

-- function: End the stopped metadata session and return to next-train mode after departure playback.
function Scheduler:_finishDepartureState()
    self:_cancelDepartureSchedule()
    self.stoppedMetadata = nil
    self.trackState:set("IDLE")
    self:_handleStateChange()
    self:_invalidateMetadata()

    if self.logger then
        self.logger.event("State", "IDLE (departure complete)")
    end
end

-- function: End the stopped-announcement metadata session and any pending departure on reset.
function Scheduler:_handleReset()
    self:_cancelDepartureSchedule()
    self.stoppedMetadata = nil
    return originalHandleReset(self)
end

-- function: Preserve approach metadata only for later stopped-train announcements.
function Scheduler:_metadataFor(request)
    if request.type == "stopped_train" or request.type == "stopped" then
        if self.stoppedMetadata then
            return self.stoppedMetadata
        end

        -- core.scheduler historically recognizes the announcement type as
        -- "stopped". Keep that internal compatibility while exposing the
        -- clearer public type "stopped_train".
        local metadataRequest = request
        if request.type == "stopped_train" then
            metadataRequest = {}
            for key, value in pairs(request) do
                metadataRequest[key] = value
            end
            metadataRequest.type = "stopped"
        end

        local metadata = originalMetadataFor(self, metadataRequest)
        if metadata then
            self.stoppedMetadata = metadata
        end
        return metadata
    end

    local metadata = originalMetadataFor(self, request)
    if request.type == "approach" and metadata then
        self.stoppedMetadata = metadata
    end
    return metadata
end

-- function: Queue requests using strict priority supersession for this client.
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

    -- Preserve the existing local queue-pruning threshold, but allow every
    -- strictly higher priority to interrupt an already submitted request. The
    -- interrupted request is cancelled on the server and is never re-queued.
    if priority >= self:_preemptPriority() then
        self.queue:removeBelow(priority)
        if self.guidanceQueued and self.guidanceConfig and priority > self.guidanceConfig.priority then
            self.guidanceQueued = false
        end
    end
    self.player:interruptBelow(priority)

    return true
end

-- function: Guidance bell playback is owned by the server, not each client scheduler.
function Scheduler:monitorGuidanceBell()
    while true do
        sleep(60)
    end
end

-- function: Complete state/guidance transitions after playback finishes.
function Scheduler:_afterRequest(request, completed, hadSegments)
    -- IDLE begins only after the departure announcement reaches its terminal
    -- lifecycle state. Do this before the guidance layer releases its hold so
    -- the published shared state and next bell deadline are based on IDLE.
    if request.type == "departure" then
        self:_finishDepartureState()
    end

    originalAfterRequest(self, request, completed, hadSegments)

    if request.type ~= "passing" or not completed or not hadSegments then
        return
    end

    local guidance = self.guidanceConfig or self:_readGuidanceConfig()
    local intervalSeconds = math.max(0, tonumber(guidance.intervalSeconds) or 0)
    local resumeAt = now() + (intervalSeconds * 1000)
    self.sharedGuidanceResumeAt = resumeAt
    self:_notifySharedTrackState(self.trackState:get(), resumeAt, false)
end

-- function: Process local railway requests while delegating all actual playback to the server.
function Scheduler:processQueue()
    while true do
        local request = self.queue:waitPop()
        self.currentRequestType = request.type

        if request.type == "guidance_bell" then
            self.guidanceQueued = false
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
                self.logger.info("Submitting: " .. tostring(request.type))
            end

            local onAudioStarted = nil
            if request.type == "next_train" and request.guidanceDurationSeconds then
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
                request.type,
                request.expiresAt
            )

            if not completed and self.logger and request.type ~= "guidance_bell" then
                self.logger.info("Interrupted: " .. tostring(request.type))
            end
        end

        self:_afterRequest(request, completed, hadSegments)
        self.currentRequestType = nil
    end
end

-- function: Add an independent departure deadline watcher without changing base scheduler tasks.
function Scheduler:run()
    parallel.waitForAll(
        function()
            originalRun(self)
        end,
        function()
            self:monitorDepartureSchedule()
        end
    )
end

return Scheduler
