return {
    trackNumber = 1,

    runtime = {
        -- Restart after unexpected application failures, but stop repeated crash loops.
        restartDelaySeconds = 5,
        stableRunSeconds = 60,
        maxConsecutiveFailures = 5,
    },

    input = {
        bundled = {
            side = "top",
            syncDelaySeconds = 0.05,
            signals = {
                approach = colors.red,
                departure = colors.blue,
            },
        },

        -- Connect a normal redstone button directly to this computer side.
        reset = {
            side = "back",
        },
    },

    speaker = {
        volume = 3,
        reconnectDelay = 1,
    },

    adapter = {
        module = "mtr",
        cacheTtlMs = 30000,

        mtr = {
            baseUrl = "http://127.0.0.1:8888",
            dimension = 0,

            -- Preferred: exact station/platform name matching through the TSC HTTP API.
            stationName = "",
            platformName = "",

            -- Optional direct override. When set, stationName/platformName are ignored.
            platformIdHex = "",
        },
    },

    announcement = {
        melody = {
            -- Paths are relative to audio/melody and may include subdirectories.
            approachPath = "approach.dfpwm",
            arrivalPath = "arrival.dfpwm",
            departurePath = "departure.dfpwm",

            approachEnabled = true,
            arrivalEnabled = false,
            departureEnabled = true,
        },

        departure = {
            doorsClosingEnabled = false,
        },
    },

    queue = {
        -- Requests at or above this priority interrupt lower-priority playback.
        preemptPriority = 100,

        priorities = {
            approach = 100,
            passing = 100,
            departure = 100,
            stopped = 20,
            next_train = 10,
        },

        ttlMs = {
            approach = 30000,
            passing = 30000,
            departure = 30000,
            stopped = 10000,
            next_train = 10000,
        },
    },

    periodic = {
        checkIntervalSeconds = 1,

        stopped = {
            enabled = true,
            state = "PLATFORM",
            type = "stopped",
            initialDelayMs = 30000,
            intervalMs = 30000,
        },

        nextTrain = {
            enabled = true,
            state = "IDLE",
            type = "next_train",
            initialDelayMs = 60000,
            intervalMs = 60000,
        },
    }
}
