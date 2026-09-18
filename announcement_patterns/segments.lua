return {
    approach_melody = {
        kind = "file",
        path = "audio/melody/approach.dfpwm",
        enabled = {
            path = "announcement.melody.approachEnabled",
            fallbackPath = "announcement.approach.melodyEnabled",
            default = true,
        },
    },

    soon = {
        kind = "file",
        path = "audio/approach/soon.dfpwm",
    },

    track_ni = {
        kind = "dynamic",
        resolver = "track",
        directory = "audio/track/ni",
    },

    track_wo = {
        kind = "dynamic",
        resolver = "track",
        directory = "audio/track/wo",
    },

    -- Legacy aliases for custom patterns using the previous track segment names.
    approach_track = {
        kind = "dynamic",
        resolver = "track",
        directory = "audio/track/ni",
    },

    passing_track = {
        kind = "dynamic",
        resolver = "track",
        directory = "audio/track/wo",
    },

    track = {
        kind = "dynamic",
        resolver = "track",
        directory = "audio/track/ni",
    },

    approach_train_arrival = {
        kind = "dynamic",
        resolver = "train_info",
        classDirectory = "audio/class",
        destinationDirectory = "audio/destination/mairimasu",
    },

    train_info = {
        kind = "dynamic",
        resolver = "train_info",
        classDirectory = "audio/class",
        destinationDirectory = "audio/destination/desu",
    },

    approach_destination = {
        kind = "dynamic",
        resolver = "destination",
        directory = "audio/destination/mairimasu",
    },

    destination_sentence = {
        kind = "dynamic",
        resolver = "destination",
        directory = "audio/destination/desu",
    },

    station_name = {
        kind = "dynamic",
        resolver = "destination",
        directory = "audio/station",
    },

    route_options = {
        kind = "dynamic",
        resolver = "route_options",
    },

    train = {
        kind = "file",
        path = "audio/approach/train.dfpwm",
    },

    out_of_service_train = {
        kind = "file",
        path = "audio/approach/out_of_service_train.dfpwm",
    },

    passing_train = {
        kind = "file",
        path = "audio/approach/passing_train.dfpwm",
    },

    -- Legacy alias for custom patterns using the previous passing segment name.
    passing = {
        kind = "file",
        path = "audio/approach/passing_train.dfpwm",
    },

    warning = {
        kind = "file",
        path = "audio/approach/warning.dfpwm",
    },

    arrival_melody = {
        kind = "file",
        path = "audio/melody/arrival.dfpwm",
        enabled = {
            path = "announcement.melody.arrivalEnabled",
            fallbackPath = "announcement.approach.arrivalMelodyEnabled",
            default = false,
        },
    },

    departure_melody = {
        kind = "file",
        path = "audio/melody/departure.dfpwm",
        enabled = {
            path = "announcement.melody.departureEnabled",
            default = true,
        },
    },

    doors_closing = {
        kind = "file",
        path = "audio/departure/doors_closing.dfpwm",
        enabled = "announcement.departure.doorsClosingEnabled",
    },

    stopped_train_info = {
        kind = "dynamic",
        resolver = "train_info",
        trackDirectory = "audio/track/ni",
        prefixPath = "audio/stopped/train.dfpwm",
        classDirectory = "audio/class",
        destinationDirectory = "audio/destination/desu",
    },

    -- Legacy fixed segment for custom stopped patterns.
    stopped_notice = {
        kind = "file",
        path = "audio/stopped/train.dfpwm",
    },

    -- Legacy fixed segment for custom next-train patterns.
    next_train_intro = {
        kind = "file",
        path = "audio/next_train/intro.dfpwm",
    },

    next_train_info = {
        kind = "dynamic",
        resolver = "train_info",
        introPath = "audio/next_train/intro.dfpwm",
        trackDirectory = "audio/track/ni",
        prefixPath = "audio/next_train/train.dfpwm",
        classDirectory = "audio/class",
        destinationDirectory = "audio/destination/desu",
    },
}
