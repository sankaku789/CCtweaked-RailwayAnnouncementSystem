local log = {}

-- function: Build a timestamped log prefix.
local function prefix(level)
    return ("[%s] [%s] "):format(textutils.formatTime(os.time(), true), level)
end

-- function: Write an informational log message.
function log.info(message)
    print(prefix("INFO") .. tostring(message))
end

-- function: Write a warning log message.
function log.warn(message)
    print(prefix("WARN") .. tostring(message))
end

-- function: Write an error log message.
function log.error(message)
    print(prefix("ERROR") .. tostring(message))
end

return log
