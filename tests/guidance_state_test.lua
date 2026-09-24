package.path = "./src/?.lua;" .. package.path

local fakeNow = 100000
os.epoch = function()
    return fakeNow
end
os.getComputerID = function()
    return 42
end

local GuidanceClient = require("core.client.guidance")

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error(("%s: expected %s, got %s"):format(
            tostring(message),
            tostring(expected),
            tostring(actual)
        ), 2)
    end
end

local observed = {}
local localServer = {}

function localServer:observeGuidanceState(clientId, state, instanceId)
    observed[#observed + 1] = {
        clientId = clientId,
        state = state,
        instanceId = instanceId,
    }
end

local client = GuidanceClient.new({
    groupId = "test",
    serverId = 42,
    instanceId = "boot-test",
    localServer = localServer,
})

client:updateFromTrack("IDLE", nil, false)
assertEqual(client:snapshot().blocked, false, "IDLE must allow guidance")
assertEqual(observed[#observed].state.blocked, false, "IDLE must publish unblocked guidance")

client:updateFromTrack("APPROACH", nil, false)
assertEqual(client:snapshot().blocked, true, "APPROACH must block guidance")
assertEqual(observed[#observed].state.blocked, true, "APPROACH must publish blocked guidance")
assertEqual(observed[#observed].state.resumeAt, nil, "APPROACH must clear guidance resume deadline")

-- PLATFORM is also blocked. Because the effective server-facing policy does not
-- change from APPROACH, an extra revision/publish is intentionally unnecessary.
local revisionsBeforePlatform = client:snapshot().revision
local updatesBeforePlatform = #observed
client:updateFromTrack("PLATFORM", nil, false)
assertEqual(client:snapshot().blocked, true, "PLATFORM must block guidance")
assertEqual(client:snapshot().revision, revisionsBeforePlatform, "equivalent blocked states must not republish")
assertEqual(#observed, updatesBeforePlatform, "PLATFORM must not duplicate an unchanged blocked update")

fakeNow = 110000
client:updateFromTrack("IDLE", 117000, false)
assertEqual(client:snapshot().blocked, false, "return to IDLE must release guidance block")
assertEqual(client:snapshot().resumeAt, 117000, "IDLE must preserve a future resume deadline")
assertEqual(observed[#observed].state.blocked, false, "IDLE return must publish unblocked guidance")
assertEqual(observed[#observed].state.resumeAt, 117000, "IDLE return must publish resume deadline")

client:updateFromTrack("UNKNOWN", 120000, false)
assertEqual(client:snapshot().blocked, true, "non-IDLE fallback states must block guidance safely")
assertEqual(client:snapshot().resumeAt, nil, "blocked fallback state must clear resume deadline")

print("guidance state tests passed")
