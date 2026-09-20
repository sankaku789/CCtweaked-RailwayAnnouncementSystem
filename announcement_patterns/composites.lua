return {
    car_count_info = {
        "car_count_prefix",
        "car_count",
    },

    approach_train_arrival = {
        "train_class",
        "approach_destination",
        "?car_count_info",
    },

    train_info = {
        "train_class",
        "destination_sentence",
        "?car_count_info",
    },

    stopped_train_info = {
        "track_ni",
        "stopped_notice",
        "train_info",
    },

    next_train_info = {
        "next_train_prefix",
        "track_ni",
        "next_train_intro",
        "train_info",
    },
}
