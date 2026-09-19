local RailwayInput = {}
RailwayInput.__index = RailwayInput

-- function: Check whether one bundled redstone color is active in a bit mask.
local function bundledActive(mask, color)
    return type(color) == "number" and colors.test(mask, color)
end

-- function: Convert observed pulse-line bits into one logical railway event.
local function pulseEvent(approach, departure)
    if approach and departure then
        return "passing"
    elseif approach then
        return "approach"
    elseif departure then
        return "departure"
    end

    return nil
end

-- function: Create a railway input monitor for two bundled pulse lines and a direct reset button.
function RailwayInput.new(options)
    options = options or {}

    local bundled = options.bundled or {}
    local signals = bundled.signals or {}
    local reset = options.reset or {}

    assert(type(bundled.side) == "string", "input.bundled.side must be a string")
    assert(type(signals.approach) == "number", "input.bundled.signals.approach must be a color")
    assert(type(signals.departure) == "number", "input.bundled.signals.departure must be a color")
    assert(signals.approach ~= signals.departure, "APPROACH and DEPARTURE bundled colors must be different")

    local syncDelaySeconds = tonumber(bundled.syncDelaySeconds)
    if syncDelaySeconds == nil then
        syncDelaySeconds = 0.05
    end
    assert(syncDelaySeconds >= 0, "input.bundled.syncDelaySeconds must be non-negative")

    if reset.side ~= nil then
        assert(type(reset.side) == "string", "input.reset.side must be a string")
    end

    return setmetatable({
        bundledSide = bundled.side,
        approachColor = signals.approach,
        departureColor = signals.departure,
        syncDelaySeconds = syncDelaySeconds,
        resetSide = reset.side,
        lastReset = reset.side and redstone.getInput(reset.side) or false,
        armed = true,
    }, RailwayInput)
end

-- function: Read the current bundled approach and departure pulse-line levels.
function RailwayInput:_readLines()
    local mask = redstone.getBundledInput(self.bundledSide)
    return bundledActive(mask, self.approachColor), bundledActive(mask, self.departureColor)
end

-- function: Detect a rising edge from the direct reset input.
function RailwayInput:_readResetRising()
    local current = self.resetSide and redstone.getInput(self.resetSide) or false
    local rising = current and not self.lastReset
    self.lastReset = current
    return rising
end

-- function: Accumulate pulse-line bits during the synchronization window.
function RailwayInput:_collectPulse(approachSeen, departureSeen)
    if approachSeen and departureSeen then
        return "passing"
    end

    if self.syncDelaySeconds <= 0 then
        return pulseEvent(approachSeen, departureSeen)
    end

    local timerId = os.startTimer(self.syncDelaySeconds)

    while true do
        local event, value = os.pullEvent()

        if event == "redstone" then
            if self:_readResetRising() then
                if type(os.cancelTimer) == "function" then
                    os.cancelTimer(timerId)
                end
                return "reset"
            end

            local approach, departure = self:_readLines()
            approachSeen = approachSeen or approach
            departureSeen = departureSeen or departure

            if approachSeen and departureSeen then
                if type(os.cancelTimer) == "function" then
                    os.cancelTimer(timerId)
                end
                return "passing"
            end
        elseif event == "timer" and value == timerId then
            return pulseEvent(approachSeen, departureSeen)
        end
    end
end

-- function: Sample one logical input event and re-arm bundled pulse detection after idle.
function RailwayInput:_sample()
    if self:_readResetRising() then
        return "reset"
    end

    local approach, departure = self:_readLines()
    if not approach and not departure then
        self.armed = true
        return nil
    end

    if not self.armed then
        return nil
    end

    local pulse = self:_collectPulse(approach, departure)
    if pulse == "reset" then
        return pulse
    end

    if pulse then
        self.armed = false
    end

    return pulse
end

-- function: Wait for and return the next logical railway input event.
function RailwayInput:waitForEvent()
    while true do
        local event = self:_sample()
        if event then
            return event
        end

        os.pullEvent("redstone")
    end
end

return RailwayInput
