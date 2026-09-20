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

-- function: Build the cache key for one track context.
function Provider:_key(context)
    return tostring((context and context.track) or "default")
end

-- function: Return cached metadata or fetch fresh metadata from the adapter.
function Provider:get(context)
    local key = self:_key(context)
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

        if self.logger and type(self.logger.event) == "function" then
            self.logger.event("Metadata", ("routeId=%s class=%s destination=%s cars=%s"):format(
                tostring(metadata.routeId or "-"),
                tostring(metadata.class or "-"),
                tostring(metadata.destination or "-"),
                tostring(metadata.carCount or "-")
            ))
        end
    end

    return metadata
end

-- function: Invalidate cached metadata for one track context.
function Provider:invalidate(context)
    self.cache:clear(self:_key(context))
end

return Provider
