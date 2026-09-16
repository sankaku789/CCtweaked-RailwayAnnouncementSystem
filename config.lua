return {
    trackNumber = 1,

    redstone = {
        side = "top",
    },

    state = {
        -- The third NEXT pulse enters DEPARTURE and then returns to IDLE.
        autoResetAfterDeparture = true,
    },

    queue = {
        approachTtlMs = 30000,
        departureTtlMs = 30000,
    },

    speaker = {
        volume = 3,
        reconnectDelay = 1,
    },

    adapter = {
        module = "none",
        cacheTtlMs = 30000,

        mtr = {
            baseUrl = "http://localhost:8888",
            dimension = 0,
            platformIdHex = "",
        },
    },

    announcement = {
        approach = {
            melodyEnabled = true,
            arrivalMelodyEnabled = false,
        },

        departure = {
            doorsClosingEnabled = false,
        },
    },
}
