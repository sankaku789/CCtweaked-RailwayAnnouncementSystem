package.path = "./src/?.lua;" .. package.path

local fakeNow = 100000
os.epoch = function()
    return fakeNow
end
os.getComputerID = function()
    return 42
end

fs = {
    exists = function(path)
        return path == "audio/guidance/bell.dfpwm"
    end,
    isDir = function()
        return false
    end,
}

local GuidanceServer = require("core.server.guidance")

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error(("%s: expected %s, got %s"):format(
            tostring(message),
            tostring(expected),
            tostring(actual)
        ), 2)
    end
end

local submitted = {}
local playbackServer = {
    idle = true,
    interrupts = 0,
}

function playbackServer:isIdle()
    return self.idle
end

function playbackServer:submitInternal(request)
    submitted[#submitted + 1] = request
    return true
end

function playbackServer:interruptGuidance()
    self.interrupts = self.interrupts + 1
    return true
end

local guidance = GuidanceServer.new({
    enabled = true,
    path = "audio/guidance/bell.dfpwm",
    initialDelaySeconds = 7,
    intervalSeconds = 1,
    priority = -1,
})
guidance:setPlaybackServer(playbackServer)

assertEqual(guidance.nextBellAt, 107000, "startup guidance must use initial delay")

-- A normal announcement always restarts guidance with initialDelaySeconds.
fakeNow = 200000
guidance:onPlaybackFinished({
    internalGuidance = false,
    label = "departure",
}, true, fakeNow)
assertEqual(guidance.nextBellAt, 207000, "departure completion must use initial delay")

fakeNow = 206999
guidance:_tryQueueBell()
assertEqual(#submitted, 0, "guidance must not queue before departure initial delay")

fakeNow = 207000
guidance:_tryQueueBell()
assertEqual(#submitted, 1, "guidance must queue at departure initial-delay deadline")
assertEqual(submitted[1].internalGuidance, true, "queued guidance must be internal")

-- Guidance-to-guidance cadence alone uses intervalSeconds.
fakeNow = 208000
guidance:onPlaybackFinished({
    internalGuidance = true,
    label = "guidance_bell",
}, true, fakeNow)
assertEqual(guidance.nextBellAt, 209000, "completed guidance bell must use recurring interval")

fakeNow = 208999
guidance:_tryQueueBell()
assertEqual(#submitted, 1, "next guidance must not queue before interval")

fakeNow = 209000
guidance:_tryQueueBell()
assertEqual(#submitted, 2, "next guidance must queue at interval deadline")

-- Passing is a normal announcement too, so it also uses initialDelaySeconds.
fakeNow = 300000
guidance:onPlaybackFinished({
    internalGuidance = false,
    label = "passing",
}, true, fakeNow)
assertEqual(guidance.nextBellAt, 307000, "passing completion must use initial delay")

-- A client resume deadline may extend, but never shorten, the server's initial delay.
fakeNow = 400000
guidance:updateClient(7, {
    revision = 1,
    blocked = false,
    resumeAt = 403000,
}, "boot-a")
guidance:onPlaybackFinished({
    internalGuidance = false,
    label = "next_train",
}, true, fakeNow)
assertEqual(guidance.nextBellAt, 407000, "short client resume deadline must not shorten initial delay")

fakeNow = 500000
guidance:updateClient(7, {
    revision = 2,
    blocked = false,
    resumeAt = 510000,
}, "boot-a")
guidance:onPlaybackFinished({
    internalGuidance = false,
    label = "stopped_train",
}, true, fakeNow)
assertEqual(guidance.nextBellAt, 510000, "longer client resume deadline must extend initial delay")

print("guidance server timing tests passed")
