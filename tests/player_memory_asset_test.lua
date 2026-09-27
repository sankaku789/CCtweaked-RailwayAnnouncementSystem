package.path = "./src/?.lua;" .. package.path

local decoderCount = 0
local decodeCalls = 0
package.preload["cc.audio.dfpwm"] = function()
    return {
        make_decoder = function()
            decoderCount = decoderCount + 1
            return function(input)
                decodeCalls = decodeCalls + 1
                return { #input }
            end
        end,
    }
end

local fakeNow = 123456
os.epoch = function()
    return fakeNow
end

fs = {
    exists = function()
        return false
    end,
    isDir = function()
        return false
    end,
}

local Player = require("audio.player")

local submitted = {}
local speakers = {}

function speakers:preparePlayback()
end

function speakers:playChunk(audio)
    submitted[#submitted + 1] = audio
    return true
end

function speakers:finishPlayback()
    return true
end

function speakers:stop()
    return true
end

function speakers:drainEvents()
end

local player = Player.new(speakers)
local startedAt = nil
local completed = player:playSegments({
    {
        kind = "dfpwm_chunks",
        chunks = { "abcd", "efghij" },
    },
}, 1, function(epoch)
    startedAt = epoch
end)

assert(completed == true, "RAM-backed DFPWM playback must complete")
assert(decoderCount == 1, "one RAM asset must use one continuous DFPWM decoder")
assert(decodeCalls == 2, "every RAM chunk must be decoded")
assert(#submitted == 2, "PCM data and completion barrier must be submitted")
assert(submitted[1][1] == 4 and submitted[1][2] == 6, "decoded RAM chunks must preserve order")
assert(startedAt == fakeNow, "audio-start callback must fire for RAM playback")

print("player RAM asset tests passed")
