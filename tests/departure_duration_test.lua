package.path = "./src/?.lua;" .. package.path

colors = colors or {
    red = 1,
    blue = 2,
}

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

local app = require("app")

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error(("%s: expected %s, got %s"):format(
            tostring(message),
            tostring(expected),
            tostring(actual)
        ), 2)
    end
end

local composer = {}

function composer:compose(request)
    assertEqual(request.type, "departure", "duration calculation must compose departure")
    return {
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
    }, {}
end

local durationSeconds, reason = app._departureDurationSeconds(composer)
assertEqual(durationSeconds, 14, "10s melody + 1s pause + 3s closing must total 14s")
assertEqual(reason, nil, "playable departure must not return an error")

print("departure duration tests passed")
