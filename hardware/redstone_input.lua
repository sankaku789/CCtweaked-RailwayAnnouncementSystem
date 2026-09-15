local RedstoneInput = {}
RedstoneInput.__index = RedstoneInput

function RedstoneInput.new(side)
    assert(type(side) == "string", "redstone side must be a string")

    local self = setmetatable({
        side = side,
        last = redstone.getInput(side),
    }, RedstoneInput)

    return self
end

function RedstoneInput:isActive()
    return redstone.getInput(self.side)
end

function RedstoneInput:waitForPulse()
    while true do
        os.pullEvent("redstone")

        local current = redstone.getInput(self.side)
        local rising = current and not self.last
        self.last = current

        if rising then
            return true
        end
    end
end

return RedstoneInput
