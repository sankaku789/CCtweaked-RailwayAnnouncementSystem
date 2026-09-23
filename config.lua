return {
    trackNumber = 1,

    -- Used only when automatic departure timing calculation fails.
    TIMEOUT_TIMING = 0,

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
            releaseDelaySeconds = 0.15,
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

    guidanceBell = {
        enabled = false,
        path = "audio/guidance/bell.dfpwm",
        initialDelaySeconds = 7,
        intervalSeconds = 1,
        -- Keep below every normal announcement priority.
        priority = -1,
    },

    adapter = {
        module = "mtr",
        cacheTtlMs = 30000,

        mtr = {
            baseUrl = "http://127.0.0.1:8888",
            dimension = 0,

            -- trackNumber is matched against the platform name at this station.
            stationName = "",

            -- Optional direct override. When set, stationName/trackNumber are ignored.
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
            -- Seconds to leave between the end of the melody and scheduled departure.
            melodyEndLeadSeconds = 5,
        },
    },

    queue = {
        -- Requests at or above this priority interrupt lower-priority playback.
        preemptPriority = 2,

        priorities = {
            approach = 2,
            passing = 2,
            departure = 3,
            stopped = 1,
            next_train = 0,
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
