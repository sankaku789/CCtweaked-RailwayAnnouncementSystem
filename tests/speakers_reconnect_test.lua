package.path = "./src/?.lua;" .. package.path

local attachedSpeakers = {}
local eventQueue = {}
local sleepCalls = 0
local nextTimerId = 0
local activeTimers = {}
local canceledTimers = {}

peripheral = {
    find = function(kind)
        assert(kind == "speaker", "unexpected peripheral kind: " .. tostring(kind))
        return table.unpack(attachedSpeakers)
    end,
    getName = function(speaker)
        return speaker.name
    end,
}

os.queueEvent = function(event, ...)
    eventQueue[#eventQueue + 1] = { event, ... }
end

os.pullEvent = function()
    if #eventQueue == 0 then
        error("unexpected empty event queue in test")
    end
    local entry = table.remove(eventQueue, 1)
    return table.unpack(entry)
end

os.startTimer = function(seconds)
    nextTimerId = nextTimerId + 1
    activeTimers[nextTimerId] = seconds
    return nextTimerId
end

os.cancelTimer = function(timerId)
    if activeTimers[timerId] ~= nil then
        activeTimers[timerId] = nil
        canceledTimers[timerId] = (canceledTimers[timerId] or 0) + 1
    end
end

sleep = function()
    sleepCalls = sleepCalls + 1
end

local Speakers = require("hardware.speakers")

local function makeSpeaker(name, playHandler)
    local device = {
        name = name,
        playCalls = 0,
        stopCalls = 0,
    }

    function device.playAudio(audio, volume)
        device.playCalls = device.playCalls + 1
        if playHandler then
            return playHandler(device.playCalls, audio, volume)
        end
        return true
    end

    function device.stop()
        device.stopCalls = device.stopCalls + 1
    end

    return device
end

local function makeLogger()
    local logs = {
        info = {},
        warn = {},
    }
    return {
        logs = logs,
        info = function(msg)
            logs.info[#logs.info + 1] = msg
        end,
        warn = function(msg)
            logs.warn[#logs.warn + 1] = msg
        end,
    }
end

local function resetEnv(speakersList)
    attachedSpeakers = speakersList or {}
    eventQueue = {}
    sleepCalls = 0
    nextTimerId = 0
    activeTimers = {}
    canceledTimers = {}
end

local function queue(...)
    local events = { ... }
    for _, entry in ipairs(events) do
        eventQueue[#eventQueue + 1] = entry
    end
end

-- 1. Partial busy (speaker_a accepts, speaker_b busy): speaker_a is never stopped,
-- no sleep/reconnect occurs, waits only for speaker_b, then delivers and finishes.
do
    local speakerA = makeSpeaker("speaker_a")
    local speakerB = makeSpeaker("speaker_b", function(callIndex)
        return callIndex >= 2
    end)
    resetEnv({ speakerA, speakerB })

    local logger = makeLogger()
    local speakers = Speakers.connect({ reconnectDelay = 1 }, logger)
    assert(speakers:preparePlayback() == true)
    sleepCalls = 0

    queue({ "speaker_audio_empty", "speaker_b" })
    assert(speakers:playChunk({ 1, 2, 3 }, "interrupt") == true)
    assert(sleepCalls == 0, "partial busy must not sleep or reconnect")
    assert(speakerA.stopCalls == 0 and speakerB.stopCalls == 0, "healthy speakers must not be stopped")
    assert(speakerA.playCalls == 1, "accepted speaker must not be retried")
    assert(speakerB.playCalls == 2, "busy speaker must receive chunk after empty event")

    queue({ "speaker_audio_empty", "speaker_a" }, { "speaker_audio_empty", "speaker_b" })
    assert(speakers:finishPlayback("interrupt") == true)
    assert(sleepCalls == 0)
end

-- 2. Partial busy where speaker_a emits speaker_audio_empty while waiting for speaker_b:
-- finishPlayback() only waits for speaker_b and does not time out on speaker_a.
do
    local speakerA = makeSpeaker("speaker_a")
    local speakerB = makeSpeaker("speaker_b", function(callIndex)
        return callIndex >= 2
    end)
    resetEnv({ speakerA, speakerB })

    local speakers = Speakers.connect({ reconnectDelay = 1 }, makeLogger())
    assert(speakers:preparePlayback() == true)
    sleepCalls = 0

    queue(
        { "speaker_audio_empty", "speaker_a" },
        { "speaker_audio_empty", "speaker_b" }
    )
    assert(speakers:playChunk({ 1, 2, 3 }, "interrupt") == true)
    assert(speakers.pendingEmpty["speaker_a"] == nil, "speaker_a empty must be cleared during busy wait")
    assert(speakers.pendingEmpty["speaker_b"] == true, "speaker_b must still have pending audio")

    queue({ "speaker_audio_empty", "speaker_b" })
    assert(speakers:finishPlayback("interrupt") == true, "finishPlayback must not wait on already-empty speaker_a")
    assert(sleepCalls == 0)
end

-- 3. peripheral_detach of 1 of 2 speakers during finishPlayback(): drops only detached speaker,
-- remaining speaker finishes without stop/reconnect, next preparePlayback() recovers it.
do
    local speakerA = makeSpeaker("speaker_a")
    local speakerB = makeSpeaker("speaker_b")
    resetEnv({ speakerA, speakerB })

    local logger = makeLogger()
    local speakers = Speakers.connect({ reconnectDelay = 1 }, logger)
    assert(speakers:preparePlayback() == true)
    sleepCalls = 0

    assert(speakers:playChunk({ 1, 2, 3 }, "interrupt") == true)
    attachedSpeakers = { speakerA }
    queue(
        { "peripheral_detach", "speaker_b" },
        { "speaker_audio_empty", "speaker_a" }
    )
    assert(speakers:finishPlayback("interrupt") == true)
    assert(sleepCalls == 0, "detach of one speaker must not trigger reconnect mid-announcement")
    assert(speakerA.stopCalls == 0 and speakerB.stopCalls == 0)
    assert(speakers.needsReconnect == true)
    assert(#speakers.activeDevices == 1 and speakers.activeDevices[1].name == "speaker_a")

    attachedSpeakers = { speakerA, speakerB }
    assert(speakers:preparePlayback() == true)
    assert(speakers.needsReconnect == false)
    assert(#speakers.activeDevices == 2)
end

-- 4. playAudio error on 1 of 2 speakers: does not stop or skip the healthy speaker.
do
    local speakerA = makeSpeaker("speaker_a", function()
        error("peripheral error")
    end)
    local speakerB = makeSpeaker("speaker_b")
    resetEnv({ speakerA, speakerB })

    local speakers = Speakers.connect({ reconnectDelay = 1 }, makeLogger())
    assert(speakers:preparePlayback() == true)
    sleepCalls = 0

    assert(speakers:playChunk({ 1, 2, 3 }, "interrupt") == true)
    assert(speakerA.stopCalls == 0 and speakerB.stopCalls == 0)
    assert(speakerB.playCalls == 1, "healthy speaker must still receive chunk after peer error")
    assert(sleepCalls == 0)
    assert(#speakers.activeDevices == 1 and speakers.activeDevices[1].name == "speaker_b")

    queue({ "speaker_audio_empty", "speaker_b" })
    assert(speakers:finishPlayback("interrupt") == true)
end

-- 5. Ready timeout on 1 of 2 speakers: drops only timed-out speaker, continues on healthy speaker.
do
    local speakerA = makeSpeaker("speaker_a")
    local speakerB = makeSpeaker("speaker_b")
    resetEnv({ speakerA, speakerB })

    local speakers = Speakers.connect({ reconnectDelay = 1 }, makeLogger())
    assert(speakers:preparePlayback() == true)
    sleepCalls = 0

    assert(speakers:playChunk({ 1, 2, 3 }, "interrupt") == true)
    local expectedTimer = nextTimerId + 1
    queue(
        { "speaker_audio_empty", "speaker_a" },
        { "timer", expectedTimer }
    )
    assert(speakers:finishPlayback("interrupt") == true)
    assert(sleepCalls == 0)
    assert(speakerA.stopCalls == 0 and speakerB.stopCalls == 0)
    assert(#speakers.activeDevices == 1 and speakers.activeDevices[1].name == "speaker_a")
    assert(speakers.needsReconnect == true)
end

-- 6. Speaker stuck busy past MAX_SPEAKER_RESYNC_ATTEMPTS: drops only stuck speaker and continues.
do
    local speakerA = makeSpeaker("speaker_a")
    local speakerB = makeSpeaker("speaker_b", function()
        return false
    end)
    resetEnv({ speakerA, speakerB })

    local speakers = Speakers.connect({ reconnectDelay = 1 }, makeLogger())
    assert(speakers:preparePlayback() == true)
    sleepCalls = 0

    queue(
        { "speaker_audio_empty", "speaker_b" },
        { "speaker_audio_empty", "speaker_b" },
        { "speaker_audio_empty", "speaker_b" },
        { "speaker_audio_empty", "speaker_b" },
        { "speaker_audio_empty", "speaker_b" }
    )
    assert(speakers:playChunk({ 1, 2, 3 }, "interrupt") == true)
    assert(speakerB.playCalls == 6, "stuck speaker must be dropped after MAX_SPEAKER_RESYNC_ATTEMPTS")
    assert(#speakers.activeDevices == 1 and speakers.activeDevices[1].name == "speaker_a")
    assert(sleepCalls == 0)

    queue({ "speaker_audio_empty", "speaker_a" })
    assert(speakers:finishPlayback("interrupt") == true)
end

-- 7. All speakers lost mid-playback and 0 attached at preparePlayback():
-- returns false without blocking (sleep count == 0), and recovers when a speaker returns.
do
    local speakerA = makeSpeaker("speaker_a", function()
        error("disconnected")
    end)
    resetEnv({ speakerA })

    local logger = makeLogger()
    local speakers = Speakers.connect({ reconnectDelay = 1 }, logger)
    assert(speakers:preparePlayback() == true)
    sleepCalls = 0

    assert(speakers:playChunk({ 1, 2, 3 }, "interrupt") == false)
    assert(sleepCalls == 0, "losing all speakers mid-playback must not block")
    assert(#speakers.activeDevices == 0)

    attachedSpeakers = {}
    assert(speakers:preparePlayback() == false)
    assert(sleepCalls == 1, "only drainEvents sleep(0) may occur when 0 speakers attached")
    local warnCountAfterFirst = #logger.logs.warn

    assert(speakers:preparePlayback() == false)
    assert(#logger.logs.warn == warnCountAfterFirst, "unavailable warning must not spam")

    local recoveredA = makeSpeaker("speaker_a")
    attachedSpeakers = { recoveredA }
    assert(speakers:preparePlayback() == true)
    assert(speakers.warnedUnavailable == false)
    assert(speakers.needsReconnect == false)
    assert(#speakers.activeDevices == 1)
    assert(speakers:playChunk({ 1, 2, 3 }, "interrupt") == true)
end

-- 8. Interrupt event during ready wait: cancels timer and returns false without dropping speakers.
do
    local speakerA = makeSpeaker("speaker_a")
    local speakerB = makeSpeaker("speaker_b")
    resetEnv({ speakerA, speakerB })

    local speakers = Speakers.connect({ reconnectDelay = 1 }, makeLogger())
    assert(speakers:preparePlayback() == true)
    assert(speakers:playChunk({ 1, 2, 3 }, "interrupt_now") == true)

    local expectedTimer = nextTimerId + 1
    queue({ "interrupt_now" })
    assert(speakers:finishPlayback("interrupt_now") == false)
    assert(canceledTimers[expectedTimer] == 1, "ready timer must be canceled on interrupt")
    assert(#speakers.activeDevices == 2, "interrupt must not drop speakers")
end

print("speaker reconnect and isolation tests passed")
