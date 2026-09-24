local Timeline = {}

local DFPWM_BYTES_PER_SECOND = 6000

-- function: Return the local audio path represented by one playback item.
local function audioPath(item)
    if type(item) == "string" then
        return item
    end

    if type(item) == "table"
        and (item.kind == "audio" or item.kind == "client_asset")
        and type(item.path) == "string"
    then
        return item.path
    end

    return nil
end

-- function: Return the audible duration from the first playable audio item onward.
function Timeline.durationSeconds(items)
    local duration = 0
    local started = false

    for _, item in ipairs(items or {}) do
        local path = audioPath(item)
        if path and fs.exists(path) and not fs.isDir(path) then
            started = true
            duration = duration + (fs.getSize(path) / DFPWM_BYTES_PER_SECOND)
        elseif type(item) == "table" and item.kind == "pause" and started then
            duration = duration + math.max(0, tonumber(item.seconds) or 0)
        end
    end

    if not started then
        return nil
    end

    return duration
end

return Timeline
