local NoneAdapter = {}
NoneAdapter.__index = NoneAdapter

-- function: Create a metadata adapter which always returns no metadata.
function NoneAdapter.new()
    return setmetatable({}, NoneAdapter)
end

-- function: Return no metadata so the composer uses the simple announcement.
function NoneAdapter:getMetadata(_context)
    return nil
end

return NoneAdapter
