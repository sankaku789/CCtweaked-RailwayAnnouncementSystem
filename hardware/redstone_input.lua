local RedstoneInput = {}
RedstoneInput.__index = RedstoneInput

-- function: Create a rising-edge redstone input monitor for one computer side.
function RedstoneInput.new(side)
    assert(type(side) == "string", "redstone side must be a string")

    local self = setmetatable({
        side = side,
        last = redstone.getInput(side),
    }, RedstoneInput)

    return self
end

-- function: Return whether the configured redstone input is currently active.
function RedstoneInput:isActive()
    return redstone.getInput(self.side)
end

-- function: Wait for the next rising-edge redstone pulse.
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
