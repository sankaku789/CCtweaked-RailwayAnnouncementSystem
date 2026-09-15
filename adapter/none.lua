local NoneAdapter = {}
NoneAdapter.__index = NoneAdapter

function NoneAdapter.new()
    return setmetatable({}, NoneAdapter)
end

function NoneAdapter:getMetadata(_context)
    return nil
end

return NoneAdapter
