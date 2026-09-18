return {
    trackNumber = 1,

    input = {
        bundled = {
            side = "top",
            signals = {
                next = colors.red,
                passing = colors.blue,
            },
        },

        -- Connect a normal redstone button directly to this computer side.
        reset = {
            side = "back",
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
            enabled = false,
            state = "PLATFORM",
            type = "stopped",
            initialDelayMs = 30000,
            intervalMs = 30000,
        },

        nextTrain = {
            enabled = false,
            state = "IDLE",
            type = "next_train",
            initialDelayMs = 60000,
            intervalMs = 60000,
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
            approachEnabled = true,
            arrivalEnabled = false,
            departureEnabled = true,
        },

        departure = {
            doorsClosingEnabled = false,
        },
    },
}
