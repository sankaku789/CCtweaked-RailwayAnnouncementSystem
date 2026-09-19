local TrackState = {}
TrackState.__index = TrackState

local states = {
    IDLE = true,
    PLATFORM = true,
}

-- function: Create a track state holder starting from IDLE.
function TrackState.new(_options)
    return setmetatable({
        state = "IDLE",
    }, TrackState)
end

-- function: Return the current track state.
function TrackState:get()
    return self.state
end

-- function: Set the current track state explicitly.
function TrackState:set(state)
    assert(states[state], "unknown track state: " .. tostring(state))
    self.state = state
end

return TrackState
