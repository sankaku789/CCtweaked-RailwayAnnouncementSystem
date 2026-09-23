package.path = "/src/?.lua;/src/?/init.lua;" .. package.path

local DEFAULT_RESTART_DELAY_SECONDS = 5
local DEFAULT_STABLE_RUN_SECONDS = 60
local DEFAULT_MAX_CONSECUTIVE_FAILURES = 5
local CONTROLLED_RESTART_DELAY_SECONDS = 0.5
local CONTROLLED_RESTART_MARKER = "railway_announcement_app_restart_v1"

local PROJECT_MODULE_PREFIXES = {
    "adapter.",
    "announcement_patterns.",
    "audio.",
    "core.",
    "hardware.",
    "metadata.",
    "util.",
}

-- function: Return whether one loaded module belongs to this application.
local function isProjectModule(name)
    if name == "app" or name == "config" then
        return true
    end

    for _, prefix in ipairs(PROJECT_MODULE_PREFIXES) do
        if name:sub(1, #prefix) == prefix then
            return true
        end
    end

    return false
end

-- function: Clear cached application modules so a restart always uses current files.
local function clearProjectModules()
    for name in pairs(package.loaded) do
        if isProjectModule(name) then
            package.loaded[name] = nil
        end
    end
end

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

-- function: Return whether one caught error requests an application-only restart.
local function isControlledRestart(value)
    return type(value) == "table" and value.marker == CONTROLLED_RESTART_MARKER
end

-- function: Load and run a fresh application instance.
local function runApplication()
    clearProjectModules()

    local app = require("app")
    local originalReboot = os.reboot

    -- The application uses reboot as a fail-stop signal when its fixed Server
    -- becomes unavailable. Convert that signal into an application-only restart
    -- so the Computer and attached peripherals are not physically rebooted.
    os.reboot = function()
        error({
            marker = CONTROLLED_RESTART_MARKER,
            reason = "Application requested restart",
        }, 0)
    end

    local ok, err = pcall(app.run)
    os.reboot = originalReboot

    if not ok then
        error(err, 0)
    end
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

    if not ok and isControlledRestart(err) then
        print("Railway Announcement System restarting application only.")
        sleep(CONTROLLED_RESTART_DELAY_SECONDS)
    else
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
end
