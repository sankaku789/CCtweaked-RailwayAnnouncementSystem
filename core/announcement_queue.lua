local Queue = {}
Queue.__index = Queue

local EVENT_NAME = "railway_announcement_queued"

-- function: Return the current UTC epoch time in milliseconds.
local function now()
    return os.epoch("utc")
end

-- function: Build the deduplication key for an announcement request.
local function requestKey(request)
    return ("%s:%s"):format(tostring(request.type), tostring(request.track))
end

-- function: Create an empty first-in-first-out announcement queue.
function Queue.new()
    return setmetatable({
        items = {},
        keys = {},
    }, Queue)
end

-- function: Add an announcement request unless an equivalent request is already queued.
function Queue:enqueue(request)
    assert(type(request) == "table", "request must be a table")
    assert(request.type ~= nil, "request.type is required")

    local key = requestKey(request)
    if self.keys[key] then
        return false, "duplicate"
    end

    request.createdAt = request.createdAt or now()

    self.items[#self.items + 1] = request
    self.keys[key] = true
    os.queueEvent(EVENT_NAME)

    return true
end

-- function: Remove and return the oldest queued request without expiry checks.
function Queue:_popRaw()
    if #self.items == 0 then
        return nil
    end

    local request = table.remove(self.items, 1)
    self.keys[requestKey(request)] = nil
    return request
end

-- function: Return the oldest non-expired announcement request.
function Queue:pop()
    while true do
        local request = self:_popRaw()
        if not request then
            return nil
        end

        if not request.expiresAt or request.expiresAt >= now() then
            return request
        end
    end
end

-- function: Wait until a non-expired announcement request is available.
function Queue:waitPop()
    while true do
        local request = self:pop()
        if request then
            return request
        end

        os.pullEvent(EVENT_NAME)
    end
end

-- function: Return the number of queued announcement requests.
function Queue:size()
    return #self.items
end

return Queue
