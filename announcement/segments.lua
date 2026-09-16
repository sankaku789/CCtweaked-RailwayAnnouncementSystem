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

    train_info = {
        kind = "dynamic",
        resolver = "train_info",
        classDirectory = "audio/class",
        destinationDirectory = "audio/destination",
    },

    train = {
        kind = "file",
        path = "audio/approach/train.dfpwm",
    },

    warning = {
        kind = "file",
        path = "audio/approach/warning.dfpwm",
    },

    arrival_melody = {
        kind = "file",
        path = "audio/arrival/melody.dfpwm",
        enabled = "announcement.approach.arrivalMelodyEnabled",
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
}
