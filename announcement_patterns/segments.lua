return {
    approach_melody = {
        resolver = "config_path",
        directory = "audio/melody",
        configPath = "announcement.melody.approachPath",
        defaultPath = "approach.dfpwm",
        enabled = {
            path = "announcement.melody.approachEnabled",
            fallbackPath = "announcement.approach.melodyEnabled",
            default = true,
        },
    },

    soon = "audio/approach/soon.dfpwm",

    track_ni = {
        resolver = "track",
        directory = "audio/track/ni",
    },

    track_wo = {
        resolver = "track",
        directory = "audio/track/wo",
    },

    train_class = {
        resolver = "class",
        directory = "audio/class",
    },

    approach_destination = {
        resolver = "destination",
        directory = "audio/destination/mairimasu",
    },

    destination_sentence = {
        resolver = "destination",
        directory = "audio/destination/station",
    },

    station_name = {
        resolver = "destination",
        directory = "audio/station",
    },

    car_count_prefix = "audio/cars/prefix.dfpwm",

    car_count = {
        resolver = "car_count",
        directory = "audio/cars",
    },

    train = "audio/approach/train.dfpwm",
    out_of_service_train = "audio/approach/out_of_service_train.dfpwm",
    passing_train = "audio/approach/passing_train.dfpwm",
    warning = "audio/approach/warning.dfpwm",

    arrival_melody = {
        resolver = "config_path",
        directory = "audio/melody",
        configPath = "announcement.melody.arrivalPath",
        defaultPath = "arrival.dfpwm",
        enabled = {
            path = "announcement.melody.arrivalEnabled",
            fallbackPath = "announcement.approach.arrivalMelodyEnabled",
            default = false,
        },
    },

    departure_melody = {
        resolver = "config_path",
        directory = "audio/melody",
        configPath = "announcement.melody.departurePath",
        defaultPath = "departure.dfpwm",
        enabled = {
            path = "announcement.melody.departureEnabled",
            default = true,
        },
    },

    doors_closing = {
        path = "audio/departure/doors_closing.dfpwm",
        enabled = "announcement.departure.doorsClosingEnabled",
    },

    stopped_notice = "audio/stopped/train.dfpwm",
    next_train_intro = "audio/next_train/train.dfpwm",
    next_train_prefix = "audio/next_train/prefix.dfpwm",
    next_train_melody = "audio/melody/next.dfpwm"
}
