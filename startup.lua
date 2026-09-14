local dfpwm = require "cc.audio.dfpwm"
local config = require("config")
local decoder = dfpwm.make_decoder()


-- function: Connect speakers
function connect_speaker()
    local speakers

    while true do
        speakers = { peripheral.find("speaker") } 

        if #speakers > 0 then
            break
        end
    end

    print(now_time() .. "Speaker is connected.")
    return speakers
end


-- function: Play song
function play_audio(file_path)
    if file_path == nil or not fs.exists(file_path) or fs.isDir(file_path) then
        print(now_time() .. "Warning -> Audio file was not found: " .. tostring(file_path))
        return false
    end

    for input in io.lines(file_path, 16 * 1024) do
        local decoded = decoder(input)

        for _, speaker in ipairs(speakers) do
            while not speaker.playAudio(decoded, 3) do
                os.pullEvent("speaker_audio_empty")
            end
        end
    end

    return true
end

-- function: Returns voice-n.dfpwm file paths in numeric order.function 
function play_voice_files(dir_path)
    local voice_files = {}

    if not fs.exists(dir_path) or not fs.isDir(dir_path) then
        return voice_files
    end

    for _, file_name in ipairs(fs.list(dir_path)) do
        local voice_number = file_name:match("^voice%-(%d+)%.dfpwm$")

        voice_number = tonumber(voice_number)

        if voice_number ~= nil and voice_number >= 1 then
            table.insert(voice_files, {
                number = voice_number,
                path = fs.combine(dir_path, file_name)
            })
        end
    end

    table.sort(voice_files, function(a, b)
        return a.number < b.number
    end)

    for index, voice_file in ipairs(voice_files) do
        voice_files[index] = voice_file.path
    end

    return voice_files
end

-- function: Use a timer event to play a song
function audio_event(timerId)
    local event, id = os.pullEvent("timer")
    if id == timerId then
        play_audio(config.DEPART_FILE_PATH)
        play_audio(config.DEPART_VOICE_PATH)
    end
end

-- function: Returns the processing time.
function now_time()
    return "[" .. textutils.formatTime(os.time(), true) .. "] : "
end


-- function: main

speakers = connect_speaker()
voice_files = play_voice_files(config.VOICE_DIR_PATH)

while true do

    -- os.pullEvent("redstone")

    local arrival_signal = colors.test(
        rs.getBundledInput(config.RS_SIDE), 
        config.ARRIVAL_SIGNAL_COLOR
    )

    local depart_signal = colors.test(
        rs.getBundledInput(config.RS_SIDE), 
        config.DEPART_SIGNAL_COLOR
    )

    if depart_signal then
        print(now_time() .. "Depart signal was received.")
        timer = os.startTimer(config.TIMEOUT_TIMING)
        audio_event(timer)
    elseif arrival_signal then
        print(now_time() .. "Arrival signal was received.")
        play_audio(config.ARRIVAL_FILE_PATH)
        play_audio(config.ARRIVAL_VOICE_PATH)

        if #voice_files > 0 then
            for _, voice_file_path in ipairs(voice_files) do
                play_audio(voice_file_path)
            end
        end
    end

    sleep(0.1)
end