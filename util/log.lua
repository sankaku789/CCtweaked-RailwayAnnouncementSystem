local log = {}

local function prefix(level)
    return ("[%s] [%s] "):format(textutils.formatTime(os.time(), true), level)
end

function log.info(message)
    print(prefix("INFO") .. tostring(message))
end

function log.warn(message)
    print(prefix("WARN") .. tostring(message))
end

function log.error(message)
    print(prefix("ERROR") .. tostring(message))
end

return log
