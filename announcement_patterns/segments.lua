return {
    approach_melody = {
        kind = "file",
        path = "audio/approach/melody.dfpwm",
        enabled = "announcement.approach.melodyEnabled",
    },

    soon = {
        kind = "file",
        path = "audio/approach/soon.dfpwm",
    },

    track = {
        kind = "dynamic",
        resolver = "track",
        directory = "audio/track",
    },

    approach_train_block = {
        kind = "dynamic",
        resolver = "approach_train_block",
        classDirectory = "audio/class",
        destinationDirectory = "audio/destination",
        warningPath = "audio/approach/warning.dfpwm",
    },

    out_of_service_block = {
        kind = "dynamic",
        resolver = "out_of_service_block",
        trainPath = "audio/approach/out_of_service_train.dfpwm",
        warningPath = "audio/approach/warning.dfpwm",
    },

    train_info = {
        kind = "dynamic",
        resolver = "train_info",
        classDirectory = "audio/class",
        destinationDirectory = "audio/destination",
    },

    route_options = {
        kind = "dynamic",
        resolver = "route_options",
    },

    train = {
        kind = "file",
        path = "audio/approach/train.dfpwm",
    },

    passing_warning = {
        kind = "file",
        path = "audio/passing/warning.dfpwm",
    },

    departure_melody = {
        kind = "file",
        path = "audio/departure/melody.dfpwm",
    },

    doors_closing = {
        kind = "file",
        path = "audio/departure/doors_closing.dfpwm",
        enabled = "announcement.departure.doorsClosingEnabled",
    },

    stopped_notice = {
        kind = "file",
        path = "audio/stopped/notice.dfpwm",
    },

    next_train_intro = {
        kind = "file",
        path = "audio/next_train/intro.dfpwm",
    },

    next_train_generic = {
        kind = "file",
        path = "audio/next_train/generic.dfpwm",
    },
}
