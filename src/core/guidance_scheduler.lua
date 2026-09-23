local Scheduler = require("core.scheduler")

local function now()
    return os.epoch("utc")
end

local originalNew = Scheduler.new
local originalNotifySharedTrackState = Scheduler._notifySharedTrackState
local originalGuidanceDue = Scheduler._guidanceDue
local originalComposeRequest = Scheduler._composeRequest
local originalHandleApproach = Scheduler._handleApproach
local originalHandleDeparture = Scheduler._handleDeparture
local originalHandleReset = Scheduler._handleReset
local originalAfterRequest = Scheduler._afterRequest
local originalSetRemoteGuidanceGate = Scheduler.setRemoteGuidanceGate

-- function: Create a scheduler with explicit local shared-guidance hold state.
function Scheduler.new(options)
    local self = originalNew(options)
    self.sharedGuidanceHold = false
    return self
end

-- function: Return whether this computer is intentionally holding the shared bell off.
function Scheduler:getSharedGuidanceHold()
    return self.sharedGuidanceHold == true
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

-- function: Return whether this computer's own policy still forbids bell playback.
function Scheduler:_localGuidanceConstrained()
    local resumeAt = tonumber(self.sharedGuidanceResumeAt)
    return self.sharedGuidanceHold == true
        or (resumeAt ~= nil and resumeAt > now())
end

-- function: Start a local policy hold and clear any precomputed resume deadline.
function Scheduler:_beginSharedGuidanceHold()
    self.sharedGuidanceHold = true
    self.sharedGuidanceResumeAt = nil

    if self.guidanceAvailable then
        self:_resetGuidanceCycle()
    end

    self:_notifySharedTrackState(
        self.trackState:get(),
        nil,
        true
    )
end

-- function: Complete a local policy hold from the actual end of the announcement.
function Scheduler:_completeSharedGuidanceHold(delaySeconds, reason)
    local completedAt = now()
    local delay = math.max(0, tonumber(delaySeconds) or 0)
    local resumeAt = completedAt + (delay * 1000)

    self.sharedGuidanceHold = false
    self.sharedGuidanceResumeAt = resumeAt
    self:_notifySharedTrackState(
        self.trackState:get(),
        resumeAt,
        false
    )

    if self.guidanceAvailable and self.trackState:get() ~= "PLATFORM" then
        self:_resetGuidanceCycle()
        self:_scheduleGuidanceFrom(completedAt, delay, reason)
    end
end

-- function: Never shorten a local post-announcement deadline when a remote gate changes.
function Scheduler:setRemoteGuidanceGate(blocked, resumeAt)
    originalSetRemoteGuidanceGate(self, blocked, resumeAt)

    if self.sharedGuidanceHold == true then
        self.guidanceNextAt = nil
        return
    end

    local localResumeAt = tonumber(self.sharedGuidanceResumeAt)
    if self.guidanceAvailable
        and self.trackState:get() ~= "PLATFORM"
        and localResumeAt
        and localResumeAt > now()
        and (self.guidanceNextAt == nil or self.guidanceNextAt < localResumeAt)
    then
        self.guidanceNextAt = localResumeAt
    end
end

-- function: Apply the local hold/deadline in addition to the existing guidance checks.
function Scheduler:_guidanceDue()
    if self:_localGuidanceConstrained() then
        return false
    end

    return originalGuidanceDue(self)
end

-- function: Start post-playback holds before normal playback enters shared FCFS.
function Scheduler:_composeRequest(request, metadata)
    local segments, diagnostics = originalComposeRequest(self, request, metadata)

    if #segments > 0
        and (request.type == "next_train" or request.type == "passing")
    then
        self:_beginSharedGuidanceHold()
        request.sharedGuidanceHoldStarted = true
    end

    return segments, diagnostics
end

-- function: A new approach supersedes any older IDLE resume policy.
function Scheduler:_handleApproach()
    self.sharedGuidanceHold = false
    self.sharedGuidanceResumeAt = nil
    return originalHandleApproach(self)
end

-- function: Hold from departure detection until the departure announcement actually finishes.
function Scheduler:_handleDeparture()
    self:_beginSharedGuidanceHold()
    local result = originalHandleDeparture(self)

    -- The base scheduler computes an event/dwell-based estimate. Shared guidance
    -- uses the actual playback completion instead, so keep the hard hold active.
    self.sharedGuidanceResumeAt = nil
    if self.guidanceAvailable then
        self:_resetGuidanceCycle()
    end
    self:_notifySharedTrackState(self.trackState:get(), nil, true)

    return result
end

-- function: Manual reset cancels an older playback hold and uses its normal initial delay.
function Scheduler:_handleReset()
    self.sharedGuidanceHold = false
    self.sharedGuidanceResumeAt = nil
    return originalHandleReset(self)
end

-- function: Rebase post-announcement guidance timing on the actual playback end.
function Scheduler:_afterRequest(request, completed, hadSegments)
    originalAfterRequest(self, request, completed, hadSegments)

    if request.type == "departure" then
        self:_completeSharedGuidanceHold(
            self.guidanceConfig.initialDelaySeconds,
            "departure complete+initial"
        )
        return
    end

    if request.type == "next_train" and request.sharedGuidanceHoldStarted then
        self:_completeSharedGuidanceHold(
            self.guidanceConfig.initialDelaySeconds,
            "next_train complete+initial"
        )
        return
    end

    if request.type == "passing" and request.sharedGuidanceHoldStarted then
        self:_completeSharedGuidanceHold(
            self.guidanceConfig.intervalSeconds,
            "passing complete+interval"
        )
    end
end

return Scheduler
