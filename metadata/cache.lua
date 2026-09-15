local Cache = {}
Cache.__index = Cache

local function now()
    return os.epoch("utc")
end

function Cache.new(ttlMs)
    return setmetatable({
        ttlMs = ttlMs or 30000,
        values = {},
    }, Cache)
end

function Cache:set(key, value)
    if value == nil then
        self.values[key] = nil
        return
    end

    self.values[key] = {
        value = value,
        updatedAt = now(),
    }
end

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

function Cache:clear(key)
    if key == nil then
        self.values = {}
    else
        self.values[key] = nil
    end
end

return Cache
