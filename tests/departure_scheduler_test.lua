package.path = "./src/?.lua;" .. package.path

local fakeNow = 100000
os.epoch = function()
    return fakeNow
end

-- Required only when helper functions are loaded. The tests below do not play audio.
fs = {
    exists = function()
        return false
    end,
    isDir = function()
        return false
    end,
    getSize = function()
        return 0
    end,
}

local Scheduler = require("core.client.scheduler")
local TrackState = require("core.track_state")

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error(("%s: expected %s, got %s"):format(
            tostring(message),
            tostring(expected),
            tostring(actual)
        ), 2)
    end
end

local function findQueued(queue, typeName)
    for _, request in ipairs(queue.items) do
        if request.type == typeName then
            return request
        end
    end
    return nil
end

assertEqual(TrackState.new():get(), "IDLE", "track state must start in IDLE")

local queue = {
    items = {},
}

function queue:enqueue(request)
    self.items[#self.items + 1] = request
    return true
end

function queue:removeBelow(priority)
    local removed = 0
    for index = #self.items, 1, -1 do
        if (tonumber(self.items[index].priority) or 0) < priority then
            table.remove(self.items, index)
            removed = removed + 1
        end
    end
    return removed
end

function queue:removeTypes(types)
    local removed = 0
    for index = #self.items, 1, -1 do
        if types[self.items[index].type] then
            table.remove(self.items, index)
            removed = removed + 1
        end
    end
    return removed
end

function queue:size()
    return #self.items
end

local trackState = {
    value = "IDLE",
}

function trackState:get()
    return self.value
end

function trackState:set(value)
    self.value = value
end

local player = {
    interrupts = {},
}

function player:interruptBelow(priority)
    self.interrupts[#self.interrupts + 1] = priority
    return false
end

local metadataProvider = {
    invalidations = 0,
    lastRequestType = nil,
}

function metadataProvider:get(request)
    self.lastRequestType = request and request.type or nil
    return {
        class = "local",
        destination = "test",
    }
end

function metadataProvider:invalidate()
    self.invalidations = self.invalidations + 1
end

local config = {
    trackNumber = 1,
    TIMEOUT_TIMING = 0,
    queue = {
        preemptPriority = 2,
        priorities = {
            approach = 2,
            passing = 2,
            departure = 3,
            stopped_train = 1,
            next_train = 0,
        },
        ttlMs = {
            approach = 30000,
            passing = 30000,
            departure = 30000,
            stopped_train = 10000,
            next_train = 10000,
        },
    },
    periodic = {
        stopped = {
            enabled = true,
            state = "PLATFORM",
            type = "stopped_train",
            initialDelayMs = 30000,
            intervalMs = 30000,
        },
        nextTrain = {
            enabled = true,
            state = "IDLE",
            type = "next_train",
            initialDelayMs = 60000,
            intervalMs = 60000,
        },
    },
    guidanceBell = {
        enabled = false,
        initialDelaySeconds = 7,
        intervalSeconds = 1,
        priority = -1,
    },
}

local scheduler = Scheduler.new({
    config = config,
    queue = queue,
    trackState = trackState,
    player = player,
    metadataProvider = metadataProvider,
    composer = {},
    departureTiming = {
        dynamic = false,
        staticDelaySeconds = 5,
        fallbackDelaySeconds = 0,
        leadSeconds = 3,
    },
})

-- Scheduler.run normally initializes this before any input event.
scheduler.guidanceConfig = {
    enabled = false,
    initialDelaySeconds = 7,
    intervalSeconds = 1,
    priority = -1,
}

local sharedUpdates = {}
scheduler.sharedTrackNotifier = function(state, resumeAt, hold)
    sharedUpdates[#sharedUpdates + 1] = {
        state = state,
        resumeAt = resumeAt,
        hold = hold,
    }
end

-- Dynamic timing must subtract the complete departure announcement and lead time.
local staticDepartureTiming = scheduler.departureTiming
scheduler.departureTiming = {
    dynamic = true,
    departureSeconds = 14,
    leadSeconds = 5,
    fallbackDelaySeconds = 0,
}
scheduler.departureTimingAdapter = {
    getCurrentPlatformDwellTimeMs = function()
        return 30000
    end,
}
local dynamicDelaySeconds, dynamicDwellTimeMs = scheduler:_resolveDepartureTiming()
assertEqual(dynamicDelaySeconds, 11, "30s dwell - 14s departure - 5s lead must start after 11s")
assertEqual(dynamicDwellTimeMs, 30000, "dynamic departure timing must preserve current dwell")
scheduler.departureTiming = staticDepartureTiming
scheduler.departureTimingAdapter = nil

scheduler:_resetPeriodicTimers()
assertEqual(scheduler.periodicNextAt.nextTrain, 160000, "startup IDLE must start next-train timer")

-- APPROACH suppresses both periodic train announcements and the shared guidance bell
-- until departure is reserved/completed.
queue.items[#queue.items + 1] = {
    type = "next_train",
    priority = 0,
}
scheduler:_handleApproach()
assertEqual(trackState:get(), "APPROACH", "approach must enter APPROACH state")
assertEqual(scheduler.periodicNextAt.nextTrain, nil, "approach must stop next-train timer")
assertEqual(scheduler.periodicNextAt.stopped, nil, "approach must not start stopped timer")
assertEqual(findQueued(queue, "next_train"), nil, "approach must remove queued next_train")
assert(findQueued(queue, "approach"), "approach request must be queued")
assertEqual(scheduler.sharedGuidanceHold, true, "approach must hold guidance bell")
local approachUpdate = sharedUpdates[#sharedUpdates]
assertEqual(approachUpdate.state, "APPROACH", "approach guidance state")
assertEqual(approachUpdate.hold, true, "approach must publish guidance hold")

queue.items = {}
fakeNow = 200000
scheduler:_handleDeparture()
assertEqual(trackState:get(), "PLATFORM", "departure reservation must enter PLATFORM")
assertEqual(scheduler.departureDueAt, 205000, "departure deadline")
assertEqual(scheduler.periodicNextAt.nextTrain, nil, "next-train timer must remain stopped on departure reservation")
assertEqual(scheduler.periodicNextAt.stopped, 230000, "stopped timer must start on departure reservation")
assertEqual(config.periodic.stopped.type, "stopped_train", "stopped periodic must use stopped_train announcement")
assertEqual(findQueued(queue, "departure"), nil, "departure must not be queued before its deadline")
assertEqual(scheduler.sharedGuidanceHold, true, "departure reservation must keep guidance bell held")

scheduler.stoppedMetadata = nil
local stoppedMetadata = scheduler:_metadataFor({
    type = "stopped_train",
    track = 1,
})
assertEqual(stoppedMetadata.class, "local", "stopped_train metadata must resolve")
assertEqual(metadataProvider.lastRequestType, "stopped_train", "stopped_train metadata lookup must preserve its public type")

fakeNow = 204999
assertEqual(scheduler:_dispatchDepartureIfDue(fakeNow), false, "departure must wait until deadline")
assertEqual(findQueued(queue, "departure"), nil, "departure must still be absent before deadline")

fakeNow = 205000
assertEqual(scheduler:_dispatchDepartureIfDue(fakeNow), true, "departure must queue at deadline")
local departure = findQueued(queue, "departure")
assert(departure, "departure request must exist at deadline")
assertEqual(departure.createdAt, 205000, "departure TTL must start when queued")
assertEqual(departure.expiresAt, 235000, "departure TTL deadline")

scheduler.stoppedMetadata = { class = "local" }
fakeNow = 210000
scheduler:_afterRequest({ type = "departure" }, true, true)
assertEqual(trackState:get(), "IDLE", "departure completion must return to IDLE")
assertEqual(scheduler.stoppedMetadata, nil, "departure completion must clear stopped metadata")
assertEqual(scheduler.periodicNextAt.stopped, nil, "stopped timer must stop after departure")
assertEqual(scheduler.periodicNextAt.nextTrain, 270000, "next-train timer must start after departure completion")
assertEqual(metadataProvider.invalidations, 1, "metadata cache must be invalidated after departure")
assertEqual(scheduler.sharedGuidanceHold, false, "departure completion must release guidance bell hold")
assertEqual(scheduler.sharedGuidanceResumeAt, 220000, "departure completion must use lead plus guidance initial delay")
local departureUpdate = sharedUpdates[#sharedUpdates]
assertEqual(departureUpdate.state, "IDLE", "departure completion guidance state")
assertEqual(departureUpdate.resumeAt, 220000, "departure completion must publish lead-plus-initial deadline")
assertEqual(departureUpdate.hold, false, "departure completion must publish released guidance hold")

-- Passing is also a normal announcement, so guidance must restart with the
-- initial delay rather than the recurring bell interval.
fakeNow = 220000
scheduler:_afterRequest({ type = "passing" }, true, true)
assertEqual(scheduler.sharedGuidanceResumeAt, 227000, "passing completion must use guidance initial delay")
local passingUpdate = sharedUpdates[#sharedUpdates]
assertEqual(passingUpdate.resumeAt, 227000, "passing completion must publish initial-delay deadline")

print("departure scheduler tests passed")
