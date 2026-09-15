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
    },

    announcement = {
        approach = {
            melodyEnabled = true,
            melody = "audio/approach/melody.dfpwm",
            soon = "audio/approach/soon.dfpwm",
            train = "audio/approach/train.dfpwm",
            warning = "audio/approach/warning.dfpwm",

            trackDir = "audio/track",
            classDir = "audio/class",
            destinationDir = "audio/destination",

            arrivalMelodyEnabled = false,
            arrivalMelody = "audio/arrival/melody.dfpwm",
        },

        departure = {
            melody = "audio/departure/melody.dfpwm",

            doorsClosingEnabled = false,
            doorsClosing = "audio/departure/doors_closing.dfpwm",
        },
    },
}
