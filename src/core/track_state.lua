local TrackState = {}
TrackState.__index = TrackState

local transitions = {
    IDLE = {
        state = "APPROACH",
        event = "approach",
    },
    APPROACH = {
        state = "PLATFORM",
        event = "platform",
    },
    PLATFORM = {
        state = "DEPARTURE",
        event = "departure",
    },
    DEPARTURE = {
        state = "IDLE",
        event = "idle",
    },
}

-- function: Create a track state machine starting from IDLE.
function TrackState.new(options)
    options = options or {}

    return setmetatable({
        state = "IDLE",
        autoResetAfterDeparture = options.autoResetAfterDeparture ~= false,
    }, TrackState)
end

-- function: Return the current track state.
function TrackState:get()
    return self.state
end

-- function: Reset the track state to IDLE.
function TrackState:reset()
    self.state = "IDLE"
end

-- function: Advance the track state by one transition.
function TrackState:advance()
    local previous = self.state
    local transition = assert(transitions[previous], "unknown track state: " .. tostring(previous))

    self.state = transition.state

    local result = {
        previous = previous,
        state = self.state,
        event = transition.event,
    }

    if self.state == "DEPARTURE" and self.autoResetAfterDeparture then
        self.state = "IDLE"
        result.resetTo = "IDLE"
    end

    return result
end

return TrackState
