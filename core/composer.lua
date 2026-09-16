local Composer = {}
Composer.__index = Composer

-- function: Trim leading and trailing ASCII whitespace.
local function trim(value)
    return value:match("^%s*(.-)%s*$")
end

-- function: Append resolved segment paths to the output list.
local function appendAll(output, paths)
    if not paths then
        return
    end

    for _, path in ipairs(paths) do
        output[#output + 1] = path
    end
end

-- function: Parse optional and fallback operators from a pattern entry.
local function parseEntry(entry)
    assert(type(entry) == "string", "announcement pattern entry must be a string")

    local optional = entry:sub(1, 1) == "?"
    if optional then
        entry = entry:sub(2)
    end

    entry = trim(entry)
    assert(entry ~= "", "announcement pattern entry cannot be empty")

    local separator = entry:find("|", 1, true)
    if not separator then
        return {
            optional = optional,
            primary = entry,
        }
    end

    local primary = trim(entry:sub(1, separator - 1))
    local fallback = trim(entry:sub(separator + 1))

    assert(primary ~= "", "fallback primary segment cannot be empty")
    assert(fallback ~= "", "fallback segment cannot be empty")

    return {
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

-- function: Resolve one pattern entry into zero or more audio file paths.
function Composer:_resolveEntry(entry, context)
    local parsed = parseEntry(entry)

    if parsed.fallback then
        local primary = self.resolver:resolve(parsed.primary, context, true)
        if primary then
            return primary
        end

        return self.resolver:resolve(parsed.fallback, context, parsed.optional)
    end

    return self.resolver:resolve(parsed.primary, context, parsed.optional)
end

-- function: Compose audio segments for an announcement request.
function Composer:compose(request, metadata)
    local pattern = self.patterns[request.type]
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

    return output
end

return Composer
