package.path = "./src/?.lua;" .. package.path

local replies = {}
local Protocol = {
    ACTION = {
        ASSET_QUERY = "ASSET_QUERY",
        ASSET_NEED = "ASSET_NEED",
        ASSET_BEGIN = "ASSET_BEGIN",
        ASSET_BEGIN_ACK = "ASSET_BEGIN_ACK",
        ASSET_CHUNK = "ASSET_CHUNK",
        ASSET_CHUNK_ACK = "ASSET_CHUNK_ACK",
        ASSET_COMMIT = "ASSET_COMMIT",
        ASSET_READY = "ASSET_READY",
        ASSET_ERROR = "ASSET_ERROR",
    },
}

function Protocol.send(clientId, groupId, action, payload, instanceId)
    replies[#replies + 1] = {
        clientId = clientId,
        groupId = groupId,
        action = action,
        payload = payload,
        instanceId = instanceId,
    }
    return true
end

package.loaded["core.protocol"] = Protocol

local fakeNow = 100000
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

local AssetServer = require("core.server.assets")

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error(("%s: expected %s, got %s"):format(
            tostring(message),
            tostring(expected),
            tostring(actual)
        ), 2)
    end
end

local function checksum(data)
    local a = 1
    local b = 0
    for index = 1, #data do
        a = (a + data:byte(index)) % 65521
        b = (b + a) % 65521
    end
    return ("%08x"):format((b * 65536) + a)
end

local server = AssetServer.new({
    groupId = "test",
    instanceId = "server-1",
})

local function upload(logicalKey, transportKey, data)
    local sum = checksum(data)

    server:handle(2, Protocol.ACTION.ASSET_QUERY, {
        assetKey = transportKey,
        logicalKey = logicalKey,
        size = #data,
        checksum = sum,
    })
    assertEqual(replies[#replies].action, Protocol.ACTION.ASSET_NEED, "new asset must be requested")

    server:handle(2, Protocol.ACTION.ASSET_BEGIN, {
        assetKey = transportKey,
        logicalKey = logicalKey,
        size = #data,
        checksum = sum,
    })
    assertEqual(replies[#replies].action, Protocol.ACTION.ASSET_BEGIN_ACK, "asset begin acknowledgement")

    local split = math.floor(#data / 2)
    local chunks = { data:sub(1, split), data:sub(split + 1) }
    for index, chunk in ipairs(chunks) do
        if chunk ~= "" then
            server:handle(2, Protocol.ACTION.ASSET_CHUNK, {
                assetKey = transportKey,
                index = index,
                data = chunk,
            })
            assertEqual(replies[#replies].action, Protocol.ACTION.ASSET_CHUNK_ACK, "asset chunk acknowledgement")
        end
    end

    server:handle(2, Protocol.ACTION.ASSET_COMMIT, {
        assetKey = transportKey,
        logicalKey = logicalKey,
        size = #data,
        checksum = sum,
    })
    assertEqual(replies[#replies].action, Protocol.ACTION.ASSET_READY, "asset commit must become ready")
end

local firstData = "first-memory-asset"
local firstKey = "departure_melody-18-11111111"
upload("departure_melody", firstKey, firstData)

local resolved = assert(server:resolveSegments(2, {
    { kind = "client_asset", key = firstKey },
}))
assertEqual(resolved[1].kind, "dfpwm_chunks", "remote asset must resolve to RAM chunks")
assertEqual(table.concat(resolved[1].chunks), firstData, "RAM chunks must preserve uploaded bytes")

server:handle(2, Protocol.ACTION.ASSET_QUERY, {
    assetKey = firstKey,
    logicalKey = "departure_melody",
    size = #firstData,
    checksum = checksum(firstData),
})
assertEqual(replies[#replies].action, Protocol.ACTION.ASSET_READY, "cached RAM asset must answer ready")

fakeNow = fakeNow + 1000
local secondData = "replacement-memory-asset"
local secondKey = "departure_melody-24-22222222"
upload("departure_melody", secondKey, secondData)

local oldResolved = server:resolveSegments(2, {
    { kind = "client_asset", key = firstKey },
})
assertEqual(oldResolved, nil, "replaced logical asset must leave the active RAM cache")

local newResolved = assert(server:resolveSegments(2, {
    { kind = "client_asset", key = secondKey },
}))
assertEqual(table.concat(newResolved[1].chunks), secondData, "replacement asset must resolve from RAM")
assertEqual(server.remoteBytes, #secondData, "RAM accounting must only include the current logical asset")

print("asset server RAM tests passed")
