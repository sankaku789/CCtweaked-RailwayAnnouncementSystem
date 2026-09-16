local log = {}

-- function: Build the legacy timestamped log prefix.
local function prefix()
    return "[" .. textutils.formatTime(os.time(), true) .. "] : "
end

-- function: Write a normal log message using the legacy format.
function log.info(message)
    print(prefix() .. tostring(message))
end

-- function: Write a categorized event log message using the legacy format.
function log.event(category, message)
    print(prefix() .. tostring(category) .. " -> " .. tostring(message))
end

-- function: Write a warning log message using the legacy format.
function log.warn(message)
    print(prefix() .. "Warning -> " .. tostring(message))
end

-- function: Write an error log message using the legacy format.
function log.error(message)
    print(prefix() .. "Error -> " .. tostring(message))
end

return log
