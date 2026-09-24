local TrackState = {}
TrackState.__index = TrackState

local states = {
    UNKNOWN = true,
    IDLE = true,
    APPROACH = true,
    PLATFORM = true,
}

-- function: Create a track state holder starting in next-train/IDLE mode.
function TrackState.new(_options)
    return setmetatable({
        state = "IDLE",
    }, TrackState)
end

-- function: Return the current track state used for periodic announcement selection.
function TrackState:get()
    return self.state
end

-- function: Set the current track state explicitly from a confirmed railway event.
function TrackState:set(state)
    assert(states[state], "unknown track state: " .. tostring(state))
    self.state = state
end

return TrackState
