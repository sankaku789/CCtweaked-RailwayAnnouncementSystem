local Provider = {}
Provider.__index = Provider

-- function: Create a metadata provider backed by an adapter and RAM cache.
function Provider.new(adapter, cache, logger)
    return setmetatable({
        adapter = adapter,
        cache = cache,
        logger = logger,
    }, Provider)
end

-- function: Return cached metadata or fetch fresh metadata from the adapter.
function Provider:get(context)
    local key = tostring(context.track or "default")
    local cached = self.cache:get(key)
    if cached then
        return cached
    end

    if not self.adapter or type(self.adapter.getMetadata) ~= "function" then
        return nil
    end

    local ok, metadata = pcall(self.adapter.getMetadata, self.adapter, context)
    if not ok then
        if self.logger then
            self.logger.warn("Metadata adapter failed: " .. tostring(metadata))
        end
        return nil
    end

    if metadata then
        self.cache:set(key, metadata)
    end

    return metadata
end

return Provider
