local TrackState = {}
TrackState.__index = TrackState

local transitions = {
    IDLE = {
        state = "PLATFORM",
        event = "approach",
    },
    PLATFORM = {
        state = "IDLE",
        event = "departure",
    },
}

-- function: Create a track state machine starting from IDLE.
function TrackState.new(_options)
    return setmetatable({
        state = "IDLE",
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

    return {
        previous = previous,
        state = self.state,
        event = transition.event,
    }
end

return TrackState
