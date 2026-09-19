local Composer = {}
Composer.__index = Composer

-- function: Trim leading and trailing ASCII whitespace.
local function trim(value)
    return value:match("^%s*(.-)%s*$")
end

-- function: Parse a route-slot symbol and return its user-defined slot name.
local function routeSlotName(id)
    if type(id) ~= "string" or id:sub(1, 6) ~= "route:" then
        return nil
    end

    local name = trim(id:sub(7))
    assert(name ~= "", "route slot name cannot be empty")
    return name
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

-- function: Append diagnostic messages from one failed resolution.
local function appendDiagnostics(output, diagnostics)
    if not diagnostics then
        return
    end

    for _, diagnostic in ipairs(diagnostics) do
        output[#output + 1] = diagnostic
    end
end

-- function: Prefix diagnostic messages with one composite or route-slot context.
local function prefixDiagnostics(prefix, diagnostics)
    local output = {}

    for _, diagnostic in ipairs(diagnostics or {}) do
        output[#output + 1] = prefix .. " -> " .. tostring(diagnostic)
    end

    return output
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
    local diagnostics = {}
    local failed = false

    for _, entry in ipairs(definition) do
        local items, parsed, entryDiagnostics = self:_resolveEntry(entry, context, true, resolving)
        if items then
            appendAll(output, items)
        elseif not parsed.optional then
            failed = true
            appendDiagnostics(diagnostics, entryDiagnostics)
        end
    end

    resolving[id] = nil

    if failed then
        if #diagnostics == 0 then
            diagnostics[1] = "required entry could not be resolved"
        end
        return nil, prefixDiagnostics(id, diagnostics)
    end

    if #output == 0 then
        return nil, { id .. ": composite resolved no playable segments" }
    end

    return output
end

-- function: Resolve a user-defined route slot for the current route.
function Composer:_resolveRouteSlot(slotName, context, resolving)
    local metadata = context and context.metadata or nil
    if type(metadata) ~= "table" then
        return {}
    end

    local routeId = metadata.routeId
    if type(routeId) ~= "string" or routeId == "" then
        return {}
    end

    local routeDefinition = self.routeOptions[routeId]
    if type(routeDefinition) ~= "table" then
        return {}
    end

    local definition = routeDefinition[slotName]
    if definition == nil then
        return {}
    end

    if type(definition) ~= "table" then
        error("route slot must be a table: " .. tostring(slotName))
    end

    local resolvingKey = "route:" .. slotName
    if resolving[resolvingKey] then
        error("recursive route slot: " .. tostring(slotName))
    end

    resolving[resolvingKey] = true

    local output = {}
    local diagnostics = {}
    local failed = false

    for _, entry in ipairs(definition) do
        local items, parsed, entryDiagnostics = self:_resolveEntry(entry, context, true, resolving)
        if items then
            appendAll(output, items)
        elseif not parsed.optional then
            failed = true
            appendDiagnostics(diagnostics, entryDiagnostics)
        end
    end

    resolving[resolvingKey] = nil

    if failed then
        if #diagnostics == 0 then
            diagnostics[1] = "required entry could not be resolved"
        end
        return {}, prefixDiagnostics(resolvingKey, diagnostics)
    end

    return output
end

-- function: Resolve one composite, route-slot, or segment symbol into playback items.
function Composer:_resolveSymbol(id, context, requirePlayable, resolving)
    local slotName = routeSlotName(id)
    if slotName then
        return self:_resolveRouteSlot(slotName, context, resolving)
    end

    local composite = self.composites[id]
    if composite ~= nil then
        return self:_resolveComposite(id, composite, context, resolving)
    end

    local items, reason = self.resolver:resolve(id, context, requirePlayable)
    if not items and reason then
        return nil, { tostring(id) .. ": " .. tostring(reason) }
    end

    return items
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
        local primary, primaryDiagnostics = self:_resolveSymbol(parsed.primary, context, true, resolving)
        if primary then
            return primary, parsed
        end

        local fallback, fallbackDiagnostics = self:_resolveSymbol(
            parsed.fallback,
            context,
            requirePlayable or parsed.optional,
            resolving
        )
        if fallback then
            return fallback, parsed
        end

        local diagnostics = {}
        appendDiagnostics(diagnostics, primaryDiagnostics)
        appendDiagnostics(diagnostics, fallbackDiagnostics)
        return nil, parsed, diagnostics
    end

    local items, diagnostics = self:_resolveSymbol(
        parsed.primary,
        context,
        requirePlayable or parsed.optional,
        resolving
    )
    return items, parsed, diagnostics
end

-- function: Compose audio and pause items for an announcement request and report failed resolutions.
function Composer:compose(request, metadata)
    local patternName = self:_patternName(request, metadata)
    local pattern = self.patterns[patternName]
    if type(pattern) ~= "table" then
        return {}, { "announcement pattern not found: " .. tostring(patternName) }
    end

    local context = {
        request = request,
        metadata = metadata,
    }

    local output = {}
    local diagnostics = {}
    local resolving = {}
    for _, entry in ipairs(pattern) do
        local items, _, entryDiagnostics = self:_resolveEntry(entry, context, false, resolving)
        appendAll(output, items)
        appendDiagnostics(diagnostics, entryDiagnostics)
    end

    return trimBoundaryPauses(output), diagnostics
end

return Composer
