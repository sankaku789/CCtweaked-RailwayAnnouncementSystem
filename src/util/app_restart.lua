local AppRestart = {}

local MARKER = "railway_announcement_app_restart_v1"

-- function: Raise a controlled request for startup.lua to restart only this application.
function AppRestart.raise(reason)
    error({
        marker = MARKER,
        reason = tostring(reason or "Application restart requested"),
    }, 0)
end

-- function: Return whether a caught error is a controlled application restart request.
function AppRestart.is(value)
    return type(value) == "table" and value.marker == MARKER
end

-- function: Return the human-readable reason attached to a restart request.
function AppRestart.reason(value)
    if AppRestart.is(value) then
        return tostring(value.reason or "Application restart requested")
    end
    return tostring(value)
end

return AppRestart
