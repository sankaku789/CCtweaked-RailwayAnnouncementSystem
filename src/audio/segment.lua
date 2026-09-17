local Segment = {}
Segment.__index = Segment

-- function: Validate an audio asset ID before using it as a file name.
local function validId(value)
    if value == nil then
        return false
    end

    local text = tostring(value)
    if text == "" or text == "." or text == ".." then
        return false
    end

    return not text:find("[/\\]")
end

-- function: Read a dotted configuration path from a Lua table.
local function readConfigPath(root, path)
    if type(path) ~= "string" or path == "" then
        return nil
    end

    local value = root
    for key in path:gmatch("[^.]+") do
        if type(value) ~= "table" then
            return nil
        end
        value = value[key]
    end

    return value
end

-- function: Append resolved segment paths to an output list.
local function appendAll(output, paths)
    if not paths then
        return
    end

    for _, path in ipairs(paths) do
        output[#output + 1] = path
    end
end

-- function: Create a semantic announcement segment resolver.
function Segment.new(config, definitions, routeOptions)
    return setmetatable({
        config = config or {},
        definitions = definitions or {},
        routeOptions = routeOptions or {},
    }, Segment)
end

-- function: Check whether an audio file exists and is not a directory.
function Segment:exists(path)
    return type(path) == "string"
        and path ~= ""
        and fs.exists(path)
        and not fs.isDir(path)
end

-- function: Resolve an audio asset ID to a DFPWM file inside a directory.
function Segment:fromId(directory, value)
    if not validId(value) or type(directory) ~= "string" or directory == "" then
        return nil
    end

    local path = fs.combine(directory, tostring(value) .. ".dfpwm")
    if self:exists(path) then
        return path
    end

    return nil
end

-- function: Check whether a segment definition is enabled by configuration.
function Segment:_isEnabled(definition)
    if definition.enabled == nil then
        return true
    end

    if type(definition.enabled) == "boolean" then
        return definition.enabled
    end

    if type(definition.enabled) == "string" then
        return readConfigPath(self.config, definition.enabled) == true
    end

    error("invalid segment enabled condition")
end

-- function: Resolve a dynamic track segment from the announcement request.
function Segment:_resolveTrack(definition, context)
    local request = context and context.request or nil
    local path = self:fromId(definition.directory, request and request.track or nil)

    if path then
        return { path }
    end

    return nil
end

-- function: Resolve class and destination files as one train information segment.
function Segment:_resolveTrainInfo(definition, context)
    local metadata = context and context.metadata or nil
    if type(metadata) ~= "table" then
        return nil
    end

    local classPath = self:fromId(definition.classDirectory, metadata.class)
    local destinationPath = self:fromId(definition.destinationDirectory, metadata.destination)

    if not classPath or not destinationPath then
        return nil
    end

    return { classPath, destinationPath }
end

-- function: Resolve the complete metadata-based approach phrase as one audio run.
function Segment:_resolveApproachTrainBlock(definition, context)
    local paths = self:_resolveTrainInfo(definition, context)
    if not paths or not self:exists(definition.warningPath) then
        return nil
    end

    paths[#paths + 1] = definition.warningPath
    return paths
end

-- function: Resolve the out-of-service approach phrase as one audio run.
function Segment:_resolveOutOfServiceBlock(definition)
    if not self:exists(definition.trainPath) or not self:exists(definition.warningPath) then
        return nil
    end

    return {
        definition.trainPath,
        definition.warningPath,
    }
end

-- function: Resolve route-specific optional segment IDs for the current announcement type.
function Segment:_resolveRouteOptions(_definition, context)
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

    local segmentIds = routeDefinition[request.type]
    if type(segmentIds) ~= "table" then
        return nil
    end

    local output = {}
    for _, segmentId in ipairs(segmentIds) do
        if type(segmentId) ~= "string" or segmentId == "" then
            error("route option segment ID must be a non-empty string")
        end

        if segmentId == "route_options" then
            error("route_options cannot include itself")
        end

        appendAll(output, self:resolve(segmentId, context, true))
    end

    if #output == 0 then
        return nil
    end

    return output
end

-- function: Resolve a named dynamic segment into audio file paths.
function Segment:_resolveDynamic(definition, context)
    if definition.resolver == "track" then
        return self:_resolveTrack(definition, context)
    elseif definition.resolver == "train_info" then
        return self:_resolveTrainInfo(definition, context)
    elseif definition.resolver == "approach_train_block" then
        return self:_resolveApproachTrainBlock(definition, context)
    elseif definition.resolver == "out_of_service_block" then
        return self:_resolveOutOfServiceBlock(definition)
    elseif definition.resolver == "route_options" then
        return self:_resolveRouteOptions(definition, context)
    end

    error("unknown dynamic segment resolver: " .. tostring(definition.resolver))
end

-- function: Resolve a semantic segment ID into one or more audio file paths.
function Segment:resolve(id, context, requirePlayable)
    local definition = self.definitions[id]
    if type(definition) ~= "table" then
        error("unknown announcement segment: " .. tostring(id))
    end

    if not self:_isEnabled(definition) then
        return nil
    end

    if definition.kind == "file" then
        if type(definition.path) ~= "string" or definition.path == "" then
            error("segment file path is not configured: " .. tostring(id))
        end

        if requirePlayable and not self:exists(definition.path) then
            return nil
        end

        return { definition.path }
    elseif definition.kind == "dynamic" then
        return self:_resolveDynamic(definition, context)
    end

    error("unknown announcement segment kind: " .. tostring(definition.kind))
end

return Segment
