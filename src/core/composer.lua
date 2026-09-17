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

-- function: Create an announcement composer from declarative patterns.
function Composer.new(patterns, resolver)
    return setmetatable({
        patterns = patterns or {},
        resolver = resolver,
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

-- function: Resolve one pattern entry into zero or more playback items.
function Composer:_resolveEntry(entry, context)
    local parsed = parseEntry(entry)

    if parsed.kind == "pause" then
        return {
            {
                kind = "pause",
                seconds = parsed.seconds,
            },
        }
    end

    if parsed.fallback then
        local primary = self.resolver:resolve(parsed.primary, context, true)
        if primary then
            return primary
        end

        return self.resolver:resolve(parsed.fallback, context, parsed.optional)
    end

    return self.resolver:resolve(parsed.primary, context, parsed.optional)
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
    for _, entry in ipairs(pattern) do
        appendAll(output, self:_resolveEntry(entry, context))
    end

    return trimBoundaryPauses(output)
end

return Composer
