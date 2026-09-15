local Segment = {}
Segment.__index = Segment

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

function Segment.new()
    return setmetatable({}, Segment)
end

function Segment:exists(path)
    return type(path) == "string"
        and path ~= ""
        and fs.exists(path)
        and not fs.isDir(path)
end

function Segment:optional(path)
    if self:exists(path) then
        return path
    end

    return nil
end

function Segment:fromId(directory, value)
    if not validId(value) or type(directory) ~= "string" or directory == "" then
        return nil
    end

    local path = fs.combine(directory, tostring(value) .. ".dfpwm")
    return self:optional(path)
end

return Segment
