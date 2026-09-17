return {
    approach = {
        "?approach_melody",
        "soon",
        "?track",
        "train_info|train",
        "warning",
        "?arrival_melody",
        "@pause:0.3",
        "?route_options",
    },

    approach_out_of_service = {
        "?approach_melody",
        "soon",
        "?track",
        "out_of_service_train",
        "warning",
        "?arrival_melody",
        "@pause:0.3",
        "?route_options",
    },

    passing = {
        "passing_warning",
    },

    departure = {
        "departure_melody",
        "@pause:0.3",
        "?doors_closing",
    },

    stopped = {
        "stopped_notice",
    },

    next_train = {
        "next_train_intro",
        "train_info|next_train_generic",
        "@pause:1.0",
        "?route_options",
    },
}
