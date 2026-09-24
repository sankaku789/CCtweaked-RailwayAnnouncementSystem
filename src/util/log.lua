local log = {}

-- function: Build a server-local real-time log prefix with millisecond precision.
local function prefix()
    local epochMs = os.epoch("local")
    local milliseconds = epochMs % 1000
    return ("[%s.%03d] : "):format(
        textutils.formatTime(os.time("local"), true),
        milliseconds
    )
end

-- function: Write a normal log message.
function log.info(message)
    print(prefix() .. tostring(message))
end

-- function: Write a categorized event log message.
function log.event(category, message)
    print(prefix() .. tostring(category) .. " -> " .. tostring(message))
end

-- function: Write a warning log message.
function log.warn(message)
    print(prefix() .. "Warning -> " .. tostring(message))
end

-- function: Write an error log message.
function log.error(message)
    print(prefix() .. "Error -> " .. tostring(message))
end

return log
