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
}

function metadataProvider:get()
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
            stopped = 1,
            next_train = 0,
        },
        ttlMs = {
            approach = 30000,
            passing = 30000,
            departure = 30000,
            stopped = 10000,
            next_train = 10000,
        },
    },
    periodic = {
        stopped = {
            enabled = true,
            state = "PLATFORM",
            type = "stopped",
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
    },
})

-- Scheduler.run normally initializes this before any input event.
scheduler.guidanceConfig = {
    enabled = false,
    initialDelaySeconds = 7,
    intervalSeconds = 1,
    priority = -1,
}

scheduler:_resetPeriodicTimers()
local originalNextTrainDue = scheduler.periodicNextAt.nextTrain

scheduler:_handleApproach()
assertEqual(trackState:get(), "IDLE", "approach must keep IDLE state")
assertEqual(scheduler.periodicNextAt.nextTrain, originalNextTrainDue, "approach must not reset next-train timer")
assert(findQueued(queue, "approach"), "approach request must be queued")

queue.items = {}
fakeNow = 200000
scheduler:_handleDeparture()
assertEqual(trackState:get(), "PLATFORM", "departure reservation must enter PLATFORM")
assertEqual(scheduler.departureDueAt, 205000, "departure deadline")
assertEqual(scheduler.periodicNextAt.nextTrain, nil, "next-train timer must stop on departure reservation")
assertEqual(scheduler.periodicNextAt.stopped, 230000, "stopped timer must start on departure reservation")
assertEqual(findQueued(queue, "departure"), nil, "departure must not be queued before its deadline")

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

print("departure scheduler tests passed")
