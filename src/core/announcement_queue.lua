local Queue = {}
Queue.__index = Queue

local EVENT_NAME = "railway_announcement_queued"

-- function: Return the current UTC epoch time in milliseconds.
local function now()
    return os.epoch("utc")
end

-- function: Return the numeric priority for an announcement request.
local function priorityOf(request)
    return tonumber(request.priority) or 0
end

-- function: Build the deduplication key for an announcement request.
local function requestKey(request)
    if request.dedupeKey ~= nil then
        return tostring(request.dedupeKey)
    end

    return ("%s:%s"):format(tostring(request.type), tostring(request.track))
end

-- function: Create an empty priority-aware announcement queue.
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

    local currentTime = now()
    self:_removeExpired(currentTime)

    local key = requestKey(request)
    if self.keys[key] then
        return false, "duplicate"
    end

    request.createdAt = request.createdAt or currentTime
    request.priority = priorityOf(request)

    self.items[#self.items + 1] = request
    self.keys[key] = true
    os.queueEvent(EVENT_NAME)

    return true
end

-- function: Remove and return one queued request by array index.
function Queue:_removeAt(index)
    local request = table.remove(self.items, index)
    if request then
        self.keys[requestKey(request)] = nil
    end
    return request
end

-- function: Remove every queued request whose expiry deadline has already passed.
function Queue:_removeExpired(currentTime)
    currentTime = tonumber(currentTime) or now()
    local removed = 0

    for index = #self.items, 1, -1 do
        local expiresAt = tonumber(self.items[index].expiresAt)
        if expiresAt and expiresAt < currentTime then
            self:_removeAt(index)
            removed = removed + 1
        end
    end

    return removed
end

-- function: Return the index of the highest-priority oldest queued request.
function Queue:_bestIndex()
    local bestIndex
    local bestPriority
    local bestCreatedAt

    for index, request in ipairs(self.items) do
        local priority = priorityOf(request)
        local createdAt = tonumber(request.createdAt) or 0

        if bestIndex == nil
            or priority > bestPriority
            or (priority == bestPriority and createdAt < bestCreatedAt)
        then
            bestIndex = index
            bestPriority = priority
            bestCreatedAt = createdAt
        end
    end

    return bestIndex
end

-- function: Return the highest-priority oldest non-expired announcement request.
function Queue:pop()
    while true do
        local index = self:_bestIndex()
        if not index then
            return nil
        end

        local request = self:_removeAt(index)
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

-- function: Remove every queued request whose priority is below the given value.
function Queue:removeBelow(priority)
    priority = tonumber(priority) or 0
    local removed = 0

    for index = #self.items, 1, -1 do
        if priorityOf(self.items[index]) < priority then
            self:_removeAt(index)
            removed = removed + 1
        end
    end

    return removed
end

-- function: Remove queued requests whose type exists in the supplied set or list.
function Queue:removeTypes(types)
    local lookup = {}

    if type(types) == "table" then
        for key, value in pairs(types) do
            if type(key) == "number" then
                lookup[tostring(value)] = true
            elseif value then
                lookup[tostring(key)] = true
            end
        end
    end

    local removed = 0
    for index = #self.items, 1, -1 do
        if lookup[tostring(self.items[index].type)] then
            self:_removeAt(index)
            removed = removed + 1
        end
    end

    return removed
end

-- function: Return the number of queued announcement requests.
function Queue:size()
    return #self.items
end

return Queue
