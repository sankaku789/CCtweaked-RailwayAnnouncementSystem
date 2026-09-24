package.path = "./src/?.lua;" .. package.path

local fileSizes = {
    ["melody.dfpwm"] = 60000,
    ["doors_closing.dfpwm"] = 18000,
}

fs = {
    exists = function(path)
        return fileSizes[path] ~= nil
    end,
    isDir = function()
        return false
    end,
    getSize = function(path)
        return fileSizes[path]
    end,
}

local Timeline = require("audio.timeline")

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error(("%s: expected %s, got %s"):format(
            tostring(message),
            tostring(expected),
            tostring(actual)
        ), 2)
    end
end

local durationSeconds = Timeline.durationSeconds({
    {
        kind = "audio",
        path = "melody.dfpwm",
    },
    {
        kind = "pause",
        seconds = 1,
    },
    {
        kind = "client_asset",
        path = "doors_closing.dfpwm",
    },
})

assertEqual(durationSeconds, 14, "10s melody + 1s pause + 3s closing must total 14s")

print("departure duration tests passed")
