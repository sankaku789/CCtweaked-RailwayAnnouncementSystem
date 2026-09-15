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

-- function: Create a segment resolver.
function Segment.new()
    return setmetatable({}, Segment)
end

-- function: Check whether a segment file exists and is not a directory.
function Segment:exists(path)
    return type(path) == "string"
        and path ~= ""
        and fs.exists(path)
        and not fs.isDir(path)
end

-- function: Return an optional segment path only when the file exists.
function Segment:optional(path)
    if self:exists(path) then
        return path
    end

    return nil
end

-- function: Resolve an audio asset ID to a DFPWM file inside a directory.
function Segment:fromId(directory, value)
    if not validId(value) or type(directory) ~= "string" or directory == "" then
        return nil
    end

    local path = fs.combine(directory, tostring(value) .. ".dfpwm")
    return self:optional(path)
end

return Segment
