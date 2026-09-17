local RailwayInput = {}
RailwayInput.__index = RailwayInput

-- function: Check whether one bundled redstone color is active in a bit mask.
local function bundledActive(mask, color)
    return type(color) == "number" and colors.test(mask, color)
end

-- function: Append one logical input event to a FIFO list.
local function push(list, value)
    list[#list + 1] = value
end

-- function: Create a railway input monitor for bundled signals and a direct reset button.
function RailwayInput.new(options)
    options = options or {}

    local bundled = options.bundled or {}
    local signals = bundled.signals or {}
    local reset = options.reset or {}

    assert(type(bundled.side) == "string", "input.bundled.side must be a string")
    assert(type(signals.next) == "number", "input.bundled.signals.next must be a color")
    assert(type(signals.passing) == "number", "input.bundled.signals.passing must be a color")
    assert(signals.next ~= signals.passing, "NEXT and PASSING bundled colors must be different")

    if reset.side ~= nil then
        assert(type(reset.side) == "string", "input.reset.side must be a string")
    end

    return setmetatable({
        bundledSide = bundled.side,
        nextColor = signals.next,
        passingColor = signals.passing,
        resetSide = reset.side,
        lastBundled = redstone.getBundledInput(bundled.side),
        lastReset = reset.side and redstone.getInput(reset.side) or false,
        pending = {},
    }, RailwayInput)
end

-- function: Capture rising edges from bundled NEXT/PASSING signals and the reset button.
function RailwayInput:_captureEdges()
    local currentBundled = redstone.getBundledInput(self.bundledSide)
    local currentReset = self.resetSide and redstone.getInput(self.resetSide) or false

    local nextRising = bundledActive(currentBundled, self.nextColor)
        and not bundledActive(self.lastBundled, self.nextColor)
    local passingRising = bundledActive(currentBundled, self.passingColor)
        and not bundledActive(self.lastBundled, self.passingColor)
    local resetRising = currentReset and not self.lastReset

    self.lastBundled = currentBundled
    self.lastReset = currentReset

    -- Reset is processed first if multiple inputs rise in the same redstone event.
    if resetRising then
        push(self.pending, "reset")
    end

    if passingRising then
        push(self.pending, "passing")
    end

    if nextRising then
        push(self.pending, "next")
    end
end

-- function: Wait for and return the next logical railway input event.
function RailwayInput:waitForEvent()
    while #self.pending == 0 do
        os.pullEvent("redstone")
        self:_captureEdges()
    end

    return table.remove(self.pending, 1)
end

return RailwayInput
