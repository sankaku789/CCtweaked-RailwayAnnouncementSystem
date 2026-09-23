local Scheduler = require("core.guidance_scheduler")

local DFPWM_BYTES_PER_SECOND = 6000

local originalAfterRequest = Scheduler._afterRequest

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

-- function: Add the agreed passing->interval guidance resume policy after playback completes.
function Scheduler:_afterRequest(request, completed, hadSegments)
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

return Scheduler
