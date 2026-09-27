local Cache = {}
Cache.__index = Cache

-- function: Return the current UTC epoch time in milliseconds.
local function now()
    return os.epoch("utc")
end

-- function: Create an in-memory metadata cache with a TTL.
function Cache.new(ttlMs)
    return setmetatable({
        ttlMs = ttlMs or 30000,
        values = {},
    }, Cache)
end

-- function: Store a metadata cache entry.
function Cache:set(key, value)
    self.values[key] = {
        value = value,
        updatedAt = now(),
    }
end

-- function: Return a non-expired metadata cache entry.
function Cache:get(key)
    local item = self.values[key]
    if not item then
        return nil
    end

    if now() - item.updatedAt > self.ttlMs then
        self.values[key] = nil
        return nil
    end

    return item.value
end

-- function: Clear one metadata cache entry.
function Cache:clear(key)
    self.values[key] = nil
end

return Cache
