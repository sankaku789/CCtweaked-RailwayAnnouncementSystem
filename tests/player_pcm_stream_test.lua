package.path = "./src/?.lua;" .. package.path

local decoderCalls = 0
local decodedTables = {}
local decodeCountsByInput = {}
local lastReadSize = nil

package.preload["cc.audio.dfpwm"] = function()
    return {
        make_decoder = function()
            return function(input)
                decoderCalls = decoderCalls + 1
                decodeCountsByInput[input] = (decodeCountsByInput[input] or 0) + 1

                if input == "empty" then
                    return {}
                end

                local samples = {}
                for sampleIndex = 1, #input do
                    samples[sampleIndex] = sampleIndex
                end
                samples.source = input
                decodedTables[#decodedTables + 1] = samples
                return samples
            end
        end,
    }
end

os.epoch = function()
    return 654321
end

os.queueEvent = function()
end

local files = {}
fs = {
    exists = function(path)
        local file = files[path]
        return file ~= nil and file.exists ~= false
    end,
    isDir = function(path)
        local file = files[path]
        return file ~= nil and file.isDir == true
    end,
    attributes = function(path)
        local file = files[path]
        if not file or file.exists == false then
            return nil
        end
        return {
            size = file.size,
            modification = file.modification,
        }
    end,
}

local fakeChunks = {}
local realLines = io.lines
io.lines = function(path, size)
    lastReadSize = size

    local chunks = fakeChunks[path]
    if not chunks then
        return realLines(path, size)
    end

    local index = 0
    return function()
        index = index + 1
        return chunks[index]
    end
end

local Player = require("audio.player")

local function newSpeakers()
    local speakers = {
        submitted = {},
        accepted = true,
    }

    function speakers:preparePlayback()
    end

    function speakers:playChunk(audio)
        if self.onPlay then
            self.onPlay(#self.submitted + 1)
        end
        if not self.accepted then
            return false
        end
        self.submitted[#self.submitted + 1] = audio
        return true
    end

    function speakers:finishPlayback()
        return true
    end

    function speakers:stop()
    end

    function speakers:drainEvents()
    end

    return speakers
end

local function resetState()
    decoderCalls = 0
    decodedTables = {}
    decodeCountsByInput = {}
    lastReadSize = nil
    files = {}
    fakeChunks = {}
end

-- Files are submitted in decoded form, keep their order, and are never copied.
resetState()
files["f1"] = { size = 4, modification = 1 }
files["f2"] = { size = 4, modification = 1 }
fakeChunks["f1"] = { "aa", "bb" }
fakeChunks["f2"] = { "cccc" }

local speakers = newSpeakers()
local player = Player.new(speakers, nil, { pcmCacheMaxFileBytes = 0 })
assert(player:playSegments({ { kind = "audio", path = "f1" }, "f2" }, 1) == true)
assert(#speakers.submitted == 4, "each chunk and the completion barrier must be submitted")
assert(speakers.submitted[1] == decodedTables[1], "decoded PCM must not be copied")
assert(speakers.submitted[2] == decodedTables[2], "decoded PCM must not be copied")
assert(speakers.submitted[3] == decodedTables[3], "decoded PCM must not be copied")
assert(speakers.submitted[1].source == "aa", "multi-file playback must preserve order")
assert(speakers.submitted[2].source == "bb", "multi-file playback must preserve order")
assert(speakers.submitted[3].source == "cccc", "multi-file playback must preserve order")
assert(speakers.submitted[4][1] == 0, "completion barrier must be submitted last")

-- A file larger than 16384 bytes is read in speaker-sized chunks.
resetState()
local splitPath = assert(os.tmpname())
local handle = assert(io.open(splitPath, "wb"))
handle:write(string.rep("\0", 16384 * 2 + 100))
handle:close()
files[splitPath] = { size = 16384 * 2 + 100, modification = 1 }

speakers = newSpeakers()
player = Player.new(speakers, nil, { pcmCacheMaxFileBytes = 0 })
assert(player:playSegments({ splitPath }, 1) == true)
assert(lastReadSize == 16384, "file reads must use one speaker buffer of 16384 bytes")
assert(#speakers.submitted == 4, "three decoded chunks and the barrier must be submitted")
assert(#speakers.submitted[1] == 16384 and #speakers.submitted[2] == 16384,
    "full reads must decode to 16384 bytes each")
assert(#speakers.submitted[3] == 100, "the final short chunk must still be submitted")
os.remove(splitPath)

-- A repeated small file is cached after the configured number of plays.
resetState()
files["bell"] = { size = 4, modification = 10 }
fakeChunks["bell"] = { "ding" }

speakers = newSpeakers()
player = Player.new(speakers, nil, { pcmCachePromoteAfterPlays = 1 })
assert(player:playSegments({ "bell" }, 1) == true)
assert(decoderCalls == 1, "first play must decode the file")
local firstCacheTable = decodedTables[1]
assert(speakers.submitted[1] == firstCacheTable, "decoded PCM must not be copied")

speakers.submitted = {}
assert(player:playSegments({ "bell" }, 1) == true)
assert(decoderCalls == 1, "second play must reuse the cached PCM")
assert(speakers.submitted[1] == firstCacheTable, "cached PCM must be submitted without copying")

-- The default policy starts caching after the second play.
resetState()
files["bell2"] = { size = 4, modification = 1 }
fakeChunks["bell2"] = { "dong" }

speakers = newSpeakers()
player = Player.new(speakers)
assert(player:playSegments({ "bell2" }, 1) == true)
assert(player:playSegments({ "bell2" }, 1) == true)
assert(decoderCalls == 2, "the default policy decodes on the first two plays")
assert(player:playSegments({ "bell2" }, 1) == true)
assert(decoderCalls == 2, "the third play must reuse the cached PCM")

-- A size or modification change invalidates the cached PCM.
resetState()
files["bell3"] = { size = 4, modification = 1 }
fakeChunks["bell3"] = { "bang" }

speakers = newSpeakers()
player = Player.new(speakers, nil, { pcmCachePromoteAfterPlays = 1 })
assert(player:playSegments({ "bell3" }, 1) == true)
assert(decoderCalls == 1)

files["bell3"].size = 5
assert(player:playSegments({ "bell3" }, 1) == true)
assert(decoderCalls == 2, "a size change must invalidate the cache")

assert(player:playSegments({ "bell3" }, 1) == true)
assert(decoderCalls == 2, "the refreshed entry must be reused")

files["bell3"].modification = 2
assert(player:playSegments({ "bell3" }, 1) == true)
assert(decoderCalls == 3, "a modification change must invalidate the cache")

-- Least recently used entries are evicted when the sample budget is exceeded.
resetState()
files["a"] = { size = 4, modification = 1 }
files["b"] = { size = 4, modification = 1 }
files["c"] = { size = 4, modification = 1 }
fakeChunks["a"] = { "aaaa" }
fakeChunks["b"] = { "bbbb" }
fakeChunks["c"] = { "cccc" }

speakers = newSpeakers()
player = Player.new(speakers, nil, {
    pcmCacheMaxSamples = 8,
    pcmCacheMaxFileBytes = 4096,
    pcmCachePromoteAfterPlays = 1,
})
assert(player:playSegments({ "a" }, 1) == true)
assert(player:playSegments({ "b" }, 1) == true)
assert(player:playSegments({ "a" }, 1) == true)
assert(decoderCalls == 2, "the recent entry must hit the cache")
assert(player:playSegments({ "c" }, 1) == true)
assert(decoderCalls == 3)
assert(player:playSegments({ "b" }, 1) == true)
assert(decoderCalls == 4, "the least recently used entry must be evicted")
assert(player:playSegments({ "c" }, 1) == true)
assert(decoderCalls == 4, "the newest entries must remain cached")
assert(player:playSegments({ "a" }, 1) == true)
assert(decoderCalls == 5, "the evicted entry must be decoded again")
assert(player.pcmCacheSamples <= 8, "the cache must stay inside its sample budget")
assert(decodeCountsByInput["aaaa"] == 2)
assert(decodeCountsByInput["bbbb"] == 2)
assert(decodeCountsByInput["cccc"] == 1)

-- Without fs.attributes the player must not cache anything.
resetState()
files["nostat"] = { size = 4, modification = 1 }
fakeChunks["nostat"] = { "tick" }
local savedAttributes = fs.attributes
fs.attributes = nil

speakers = newSpeakers()
player = Player.new(speakers, nil, { pcmCachePromoteAfterPlays = 1 })
assert(player:playSegments({ "nostat" }, 1) == true)
assert(player:playSegments({ "nostat" }, 1) == true)
assert(decoderCalls == 2, "caching must be disabled without fs.attributes")
fs.attributes = savedAttributes

-- Empty decoder output must not be submitted.
resetState()
speakers = newSpeakers()
player = Player.new(speakers)
assert(player:playSegments({
    { kind = "dfpwm_chunks", chunks = { "aa", "empty" } },
}, 1) == true)
assert(#speakers.submitted == 2, "an empty decode result must be skipped")
assert(speakers.submitted[1].source == "aa")
assert(speakers.submitted[2][1] == 0, "completion barrier must still be submitted")

-- An interrupt during the first chunk stops the run.
resetState()
files["long"] = { size = 6, modification = 1 }
fakeChunks["long"] = { "aaa", "bbb", "ccc" }

speakers = newSpeakers()
player = Player.new(speakers, nil, { pcmCacheMaxFileBytes = 0 })
speakers.onPlay = function(index)
    if index == 1 then
        player:interrupt()
    end
end
assert(player:playSegments({ "long" }, 1) == false, "an interrupt must stop playback")
assert(decoderCalls == 1, "no further chunks must be decoded after an interrupt")
assert(#speakers.submitted == 1, "no further chunks must be submitted after an interrupt")

print("player PCM stream tests passed")
