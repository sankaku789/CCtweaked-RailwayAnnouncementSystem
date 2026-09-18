local Composer = {}
Composer.__index = Composer

-- function: Trim leading and trailing ASCII whitespace.
local function trim(value)
    return value:match("^%s*(.-)%s*$")
end

-- function: Check whether a composed playback item is a pause directive.
local function isPause(item)
    return type(item) == "table" and item.kind == "pause"
end

-- function: Append resolved playback items while collapsing adjacent pauses.
local function appendAll(output, items)
    if not items then
        return
    end

    for _, item in ipairs(items) do
        local previous = output[#output]
        if isPause(item) and isPause(previous) then
            previous.seconds = math.max(
                tonumber(previous.seconds) or 0,
                tonumber(item.seconds) or 0
            )
        else
            output[#output + 1] = item
        end
    end
end

-- function: Remove pause directives which would play before or after all audio.
local function trimBoundaryPauses(output)
    while #output > 0 and isPause(output[1]) do
        table.remove(output, 1)
    end

    while #output > 0 and isPause(output[#output]) do
        output[#output] = nil
    end

    return output
end

-- function: Parse pause, optional, and fallback operators from a pattern entry.
local function parseEntry(entry)
    assert(type(entry) == "string", "announcement pattern entry must be a string")

    entry = trim(entry)
    assert(entry ~= "", "announcement pattern entry cannot be empty")

    local pauseValue = entry:match("^@pause%s*:%s*(.+)$")
    if pauseValue then
        local seconds = tonumber(trim(pauseValue))
        assert(seconds and seconds >= 0, "pause duration must be a non-negative number")

        return {
            kind = "pause",
            seconds = seconds,
        }
    end

    local optional = entry:sub(1, 1) == "?"
    if optional then
        entry = trim(entry:sub(2))
        assert(entry ~= "", "optional announcement segment cannot be empty")
    end

    local separator = entry:find("|", 1, true)
    if not separator then
        return {
            kind = "segment",
            optional = optional,
            primary = entry,
        }
    end

    local primary = trim(entry:sub(1, separator - 1))
    local fallback = trim(entry:sub(separator + 1))

    assert(primary ~= "", "fallback primary segment cannot be empty")
    assert(fallback ~= "", "fallback segment cannot be empty")

    return {
        kind = "segment",
        optional = optional,
        primary = primary,
        fallback = fallback,
    }
end

-- function: Create an announcement composer from declarative patterns and named composites.
function Composer.new(patterns, resolver, composites, routeOptions)
    return setmetatable({
        patterns = patterns or {},
        resolver = resolver,
        composites = composites or {},
        routeOptions = routeOptions or {},
    }, Composer)
end

-- function: Select the pattern variant for a request and its metadata.
function Composer:_patternName(request, metadata)
    if request.type == "approach"
        and type(metadata) == "table"
        and metadata.terminating == true
        and type(self.patterns.approach_out_of_service) == "table"
    then
        return "approach_out_of_service"
    end

    return request.type
end

-- function: Resolve a named composite only when every required entry can be played.
function Composer:_resolveComposite(id, definition, context, resolving)
    if type(definition) ~= "table" then
        error("announcement composite must be a table: " .. tostring(id))
    end

    if resolving[id] then
        error("recursive announcement composite: " .. tostring(id))
    end

    resolving[id] = true

    local output = {}
    for _, entry in ipairs(definition) do
        local items, parsed = self:_resolveEntry(entry, context, true, resolving)
        if items then
            appendAll(output, items)
        elseif not parsed.optional then
            resolving[id] = nil
            return nil
        end
    end

    resolving[id] = nil
    if #output == 0 then
        return nil
    end

    return output
end

-- function: Resolve route-specific optional symbols for the current announcement type.
function Composer:_resolveRouteOptions(context, resolving)
    local request = context and context.request or nil
    local metadata = context and context.metadata or nil

    if type(request) ~= "table" or type(metadata) ~= "table" then
        return nil
    end

    local routeId = metadata.routeId
    if type(routeId) ~= "string" or routeId == "" then
        return nil
    end

    local routeDefinition = self.routeOptions[routeId]
    if type(routeDefinition) ~= "table" then
        return nil
    end

    local symbolIds = routeDefinition[request.type]
    if type(symbolIds) ~= "table" then
        return nil
    end

    if resolving.route_options then
        error("recursive announcement composite: route_options")
    end

    resolving.route_options = true

    local output = {}
    for _, symbolId in ipairs(symbolIds) do
        if type(symbolId) ~= "string" or symbolId == "" then
            error("route option symbol ID must be a non-empty string")
        end

        if symbolId == "route_options" then
            error("route_options cannot include itself")
        end

        appendAll(output, self:_resolveSymbol(symbolId, context, true, resolving))
    end

    resolving.route_options = nil
    if #output == 0 then
        return nil
    end

    return output
end

-- function: Resolve one segment, composite, or route-options symbol into playback items.
function Composer:_resolveSymbol(id, context, requirePlayable, resolving)
    if type(self.resolver.has) == "function" and self.resolver:has(id) then
        return self.resolver:resolve(id, context, requirePlayable)
    end

    local composite = self.composites[id]
    if composite ~= nil then
        return self:_resolveComposite(id, composite, context, resolving)
    end

    if id == "route_options" then
        return self:_resolveRouteOptions(context, resolving)
    end

    return self.resolver:resolve(id, context, requirePlayable)
end

-- function: Resolve one pattern entry into zero or more playback items.
function Composer:_resolveEntry(entry, context, requirePlayable, resolving)
    local parsed = parseEntry(entry)

    if parsed.kind == "pause" then
        return {
            {
                kind = "pause",
                seconds = parsed.seconds,
            },
        }, parsed
    end

    if parsed.fallback then
        local primary = self:_resolveSymbol(parsed.primary, context, true, resolving)
        if primary then
            return primary, parsed
        end

        local fallback = self:_resolveSymbol(
            parsed.fallback,
            context,
            requirePlayable or parsed.optional,
            resolving
        )
        return fallback, parsed
    end

    local items = self:_resolveSymbol(
        parsed.primary,
        context,
        requirePlayable or parsed.optional,
        resolving
    )
    return items, parsed
end

-- function: Compose audio and pause items for an announcement request.
function Composer:compose(request, metadata)
    local patternName = self:_patternName(request, metadata)
    local pattern = self.patterns[patternName]
    if type(pattern) ~= "table" then
        return {}
    end

    local context = {
        request = request,
        metadata = metadata,
    }

    local output = {}
    local resolving = {}
    for _, entry in ipairs(pattern) do
        local items = self:_resolveEntry(entry, context, false, resolving)
        appendAll(output, items)
    end

    return trimBoundaryPauses(output)
end

return Composer
