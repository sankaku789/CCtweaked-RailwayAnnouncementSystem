return {
    approach = {
        "?approach_melody",
        "soon",
        "?track_ni",
        "approach_train_arrival|train",
        "warning",
        "?arrival_melody",
        "?route_options",
    },

    approach_out_of_service = {
        "?approach_melody",
        "soon",
        "?track_ni",
        "out_of_service_train",
        "warning",
        "?arrival_melody",
        "?route_options",
    },

    passing = {
        "soon",
        "?track_wo",
        "passing",
        "warning",
    },

    departure = {
        "departure_melody",
        "?doors_closing",
    },

    stopped = {
        "?track_ni"
        "train",
        "approach_train_arrival",
        ""
    },

    next_train = {
        "next_train_intro",
        "train_info|next_train_generic",
        "?route_options",
    },
}
