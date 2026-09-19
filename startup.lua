package.path = "/src/?.lua;/src/?/init.lua;" .. package.path

local DEFAULT_RESTART_DELAY_SECONDS = 5
local DEFAULT_STABLE_RUN_SECONDS = 60
local DEFAULT_MAX_CONSECUTIVE_FAILURES = 5

-- function: Load runtime restart settings without preventing startup error recovery.
local function loadRuntimeOptions()
    local options = {
        restartDelaySeconds = DEFAULT_RESTART_DELAY_SECONDS,
        stableRunSeconds = DEFAULT_STABLE_RUN_SECONDS,
        maxConsecutiveFailures = DEFAULT_MAX_CONSECUTIVE_FAILURES,
    }

    local ok, config = pcall(dofile, "/config.lua")
    local runtime = ok and type(config) == "table" and config.runtime or nil
    if type(runtime) ~= "table" then
        return options
    end

    options.restartDelaySeconds = tonumber(runtime.restartDelaySeconds) or options.restartDelaySeconds
    options.stableRunSeconds = tonumber(runtime.stableRunSeconds) or options.stableRunSeconds
    options.maxConsecutiveFailures = math.floor(
        tonumber(runtime.maxConsecutiveFailures) or options.maxConsecutiveFailures
    )

    options.restartDelaySeconds = math.max(0, options.restartDelaySeconds)
    options.stableRunSeconds = math.max(0, options.stableRunSeconds)
    options.maxConsecutiveFailures = math.max(1, options.maxConsecutiveFailures)

    return options
end

-- function: Load and run a fresh application instance.
local function runApplication()
    package.loaded["app"] = nil
    package.loaded["config"] = nil

    local app = require("app")
    app.run()
end

local consecutiveFailures = 0

while true do
    local runtime = loadRuntimeOptions()
    local startedAt = os.epoch("utc")
    local ok, err = pcall(runApplication)
    local runDurationMs = os.epoch("utc") - startedAt

    if not ok and tostring(err) == "Terminated" then
        print("Railway Announcement System terminated.")
        break
    end

    if runDurationMs >= runtime.stableRunSeconds * 1000 then
        consecutiveFailures = 0
    end
    consecutiveFailures = consecutiveFailures + 1

    if ok then
        printError("Railway Announcement System stopped unexpectedly without an error.")
    else
        printError("Railway Announcement System stopped: " .. tostring(err))
    end

    if consecutiveFailures >= runtime.maxConsecutiveFailures then
        printError(("Automatic restart stopped after %d consecutive failure(s)."):format(
            consecutiveFailures
        ))
        break
    end

    print(("Restarting in %.1f second(s)... (%d/%d)"):format(
        runtime.restartDelaySeconds,
        consecutiveFailures,
        runtime.maxConsecutiveFailures
    ))
    sleep(runtime.restartDelaySeconds)
end
