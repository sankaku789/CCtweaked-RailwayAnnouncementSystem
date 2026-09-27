local Protocol = require("core.protocol")

local AssetServer = {}
AssetServer.__index = AssetServer

local MAX_ASSET_BYTES = 256 * 1024
local MAX_REMOTE_MEMORY_BYTES = 512 * 1024
local MAX_CHUNK_BYTES = 16 * 1024
local TRANSFER_LEASE_MS = 30 * 1000
local ADLER_MOD = 65521

local HANDLED_ACTIONS = {
    [Protocol.ACTION.ASSET_QUERY] = true,
    [Protocol.ACTION.ASSET_BEGIN] = true,
    [Protocol.ACTION.ASSET_CHUNK] = true,
    [Protocol.ACTION.ASSET_COMMIT] = true,
}

local function now()
    return os.epoch("utc")
end

local function validKey(value)
    return type(value) == "string"
        and value ~= ""
        and value:match("^[%w_%-]+$") ~= nil
end

local function updateChecksum(a, b, data)
    for index = 1, #data do
        a = (a + data:byte(index)) % ADLER_MOD
        b = (b + a) % ADLER_MOD
    end
    return a, b
end

local function checksumText(a, b)
    return ("%08x"):format((b * 65536) + a)
end

local function validSize(value)
    value = tonumber(value)
    return value ~= nil
        and value >= 0
        and value == math.floor(value)
        and value <= MAX_ASSET_BYTES
end

local function transferKey(sourceId, assetKey)
    return ("%s:%s"):format(tostring(sourceId), tostring(assetKey))
end

-- function: Create the Server-side RAM cache for Client-owned audio assets.
function AssetServer.new(options)
    return setmetatable({
        groupId = options.groupId,
        instanceId = options.instanceId,
        logger = options.logger,
        localAssets = {},
        localSlots = {},
        remoteAssets = {},
        assetSlots = {},
        remoteBytes = 0,
        transfers = {},
        transferReservedBytes = 0,
    }, AssetServer)
end

-- function: Return whether one committed RAM asset exactly matches the requested signature.
function AssetServer:_memoryMatches(sourceId, assetKey, size, checksum)
    local asset = self.remoteAssets[transferKey(sourceId, assetKey)]
    return asset ~= nil
        and tonumber(asset.size) == tonumber(size)
        and tostring(asset.checksum) == tostring(checksum)
end

-- function: Remove one committed RAM asset from the active lookup table.
function AssetServer:_removeRemoteAsset(sourceId, assetKey)
    local key = transferKey(sourceId, assetKey)
    local asset = self.remoteAssets[key]
    if not asset then
        return
    end

    self.remoteAssets[key] = nil
    self.remoteBytes = math.max(0, self.remoteBytes - (tonumber(asset.size) or 0))
end

-- function: Discard one unfinished in-memory transfer and release its reservation.
function AssetServer:_discardTransfer(key)
    local transfer = self.transfers[key]
    if not transfer then
        return
    end

    self.transferReservedBytes = math.max(
        0,
        self.transferReservedBytes - (tonumber(transfer.expectedSize) or 0)
    )
    self.transfers[key] = nil
end

-- function: Release abandoned partial uploads.
function AssetServer:_pruneTransfers()
    local current = now()
    for key, transfer in pairs(self.transfers) do
        if current - (tonumber(transfer.updatedAt) or 0) > TRANSFER_LEASE_MS then
            self:_discardTransfer(key)
        end
    end
end

-- function: Reply to one remote Client asset command.
function AssetServer:_reply(clientId, action, payload)
    return Protocol.send(
        clientId,
        self.groupId,
        action,
        payload,
        self.instanceId
    )
end

-- function: Register a local Client-owned asset without copying it into RAM.
function AssetServer:registerLocal(sourceId, logicalKey, assetKey, path, size, checksum)
    sourceId = tonumber(sourceId)
    if not sourceId or not validKey(logicalKey) or not validKey(assetKey) then
        return false, "invalid local asset identity"
    end
    if type(path) ~= "string" or path == "" or not fs.exists(path) or fs.isDir(path) then
        return false, "local asset file was not found: " .. tostring(path)
    end
    if not validSize(size) or fs.getSize(path) ~= tonumber(size) then
        return false, "local asset size changed during synchronization"
    end
    if type(checksum) ~= "string" or checksum == "" then
        return false, "local asset checksum is invalid"
    end

    local slotKey = transferKey(sourceId, logicalKey)
    local previousAssetKey = self.localSlots[slotKey]
    if previousAssetKey and previousAssetKey ~= assetKey then
        self.localAssets[transferKey(sourceId, previousAssetKey)] = nil
    end

    self.localSlots[slotKey] = assetKey
    self.localAssets[transferKey(sourceId, assetKey)] = path
    return true
end

-- function: Resolve one Client-owned asset to a file-backed or RAM-backed playback item.
function AssetServer:resolve(sourceId, assetKey)
    sourceId = tonumber(sourceId)
    if not sourceId or not validKey(assetKey) then
        return nil
    end

    local key = transferKey(sourceId, assetKey)
    local localPath = self.localAssets[key]
    if localPath and fs.exists(localPath) and not fs.isDir(localPath) then
        return {
            kind = "audio",
            path = localPath,
        }
    end

    local asset = self.remoteAssets[key]
    if asset then
        asset.lastUsedAt = now()
        return {
            kind = "dfpwm_chunks",
            chunks = asset.chunks,
        }
    end

    return nil
end

-- function: Resolve Client asset references while leaving shared segments unchanged.
function AssetServer:resolveSegments(sourceId, segments)
    local resolved = {}

    for index, item in ipairs(segments or {}) do
        if type(item) == "table" and item.kind == "client_asset" then
            local assetKey = item.key
            local playbackItem = self:resolve(sourceId, assetKey)
            if not playbackItem then
                return nil, "Client asset is not synchronized: " .. tostring(assetKey)
            end
            resolved[index] = playbackItem
        else
            resolved[index] = item
        end
    end

    return resolved
end

-- function: Return whether this action belongs to asset synchronization.
function AssetServer:handles(action)
    return HANDLED_ACTIONS[action] == true
end

-- function: Process one remote asset synchronization packet.
function AssetServer:handle(clientId, action, payload)
    self:_pruneTransfers()

    clientId = tonumber(clientId)
    payload = type(payload) == "table" and payload or {}
    local assetKey = payload.assetKey

    if not clientId or not validKey(assetKey) then
        return false
    end

    if action == Protocol.ACTION.ASSET_QUERY then
        if not validSize(payload.size) or type(payload.checksum) ~= "string" then
            self:_reply(clientId, Protocol.ACTION.ASSET_ERROR, {
                assetKey = assetKey,
                reason = "invalid asset signature",
            })
            return true
        end

        local response = self:_memoryMatches(clientId, assetKey, payload.size, payload.checksum)
            and Protocol.ACTION.ASSET_READY
            or Protocol.ACTION.ASSET_NEED
        self:_reply(clientId, response, {
            assetKey = assetKey,
            size = tonumber(payload.size),
            checksum = payload.checksum,
        })
        return true
    end

    local key = transferKey(clientId, assetKey)

    if action == Protocol.ACTION.ASSET_BEGIN then
        if not validSize(payload.size) or type(payload.checksum) ~= "string" then
            self:_reply(clientId, Protocol.ACTION.ASSET_ERROR, {
                assetKey = assetKey,
                reason = "invalid asset transfer signature",
            })
            return true
        end

        local logicalKey = payload.logicalKey
        if logicalKey == nil then
            -- Compatibility with an older Client which only sends the versioned key.
            logicalKey = assetKey
        elseif not validKey(logicalKey) then
            self:_reply(clientId, Protocol.ACTION.ASSET_ERROR, {
                assetKey = assetKey,
                reason = "invalid logical asset key",
            })
            return true
        end

        self:_discardTransfer(key)

        local expectedSize = tonumber(payload.size)
        if self.remoteBytes + self.transferReservedBytes + expectedSize > MAX_REMOTE_MEMORY_BYTES then
            self:_reply(clientId, Protocol.ACTION.ASSET_ERROR, {
                assetKey = assetKey,
                reason = ("remote asset RAM limit exceeded: need %d bytes, used/reserved %d of %d"):format(
                    expectedSize,
                    self.remoteBytes + self.transferReservedBytes,
                    MAX_REMOTE_MEMORY_BYTES
                ),
            })
            return true
        end

        self.transfers[key] = {
            logicalKey = logicalKey,
            chunks = {},
            expectedSize = expectedSize,
            expectedChecksum = payload.checksum,
            receivedSize = 0,
            nextIndex = 1,
            checksumA = 1,
            checksumB = 0,
            updatedAt = now(),
        }
        self.transferReservedBytes = self.transferReservedBytes + expectedSize

        self:_reply(clientId, Protocol.ACTION.ASSET_BEGIN_ACK, {
            assetKey = assetKey,
            index = 0,
        })
        return true
    end

    local transfer = self.transfers[key]

    if action == Protocol.ACTION.ASSET_CHUNK then
        local index = tonumber(payload.index)
        local data = payload.data
        if not transfer then
            self:_reply(clientId, Protocol.ACTION.ASSET_ERROR, {
                assetKey = assetKey,
                index = index,
                reason = "asset transfer is not active",
            })
            return true
        end

        transfer.updatedAt = now()
        if not index or index < 1 or index ~= math.floor(index) or type(data) ~= "string" then
            self:_reply(clientId, Protocol.ACTION.ASSET_ERROR, {
                assetKey = assetKey,
                index = index,
                reason = "invalid asset chunk",
            })
            return true
        end
        if #data > MAX_CHUNK_BYTES then
            self:_reply(clientId, Protocol.ACTION.ASSET_ERROR, {
                assetKey = assetKey,
                index = index,
                reason = "asset chunk is too large",
            })
            return true
        end

        if index < transfer.nextIndex then
            self:_reply(clientId, Protocol.ACTION.ASSET_CHUNK_ACK, {
                assetKey = assetKey,
                index = index,
            })
            return true
        end

        if index ~= transfer.nextIndex then
            self:_reply(clientId, Protocol.ACTION.ASSET_ERROR, {
                assetKey = assetKey,
                index = index,
                reason = "unexpected asset chunk index",
            })
            return true
        end

        if transfer.receivedSize + #data > transfer.expectedSize then
            self:_discardTransfer(key)
            self:_reply(clientId, Protocol.ACTION.ASSET_ERROR, {
                assetKey = assetKey,
                index = index,
                reason = "asset exceeds declared size",
            })
            return true
        end

        transfer.chunks[#transfer.chunks + 1] = data
        transfer.receivedSize = transfer.receivedSize + #data
        transfer.checksumA, transfer.checksumB = updateChecksum(
            transfer.checksumA,
            transfer.checksumB,
            data
        )
        transfer.nextIndex = transfer.nextIndex + 1

        self:_reply(clientId, Protocol.ACTION.ASSET_CHUNK_ACK, {
            assetKey = assetKey,
            index = index,
        })
        return true
    end

    if action == Protocol.ACTION.ASSET_COMMIT then
        if not transfer then
            if validSize(payload.size)
                and type(payload.checksum) == "string"
                and self:_memoryMatches(clientId, assetKey, payload.size, payload.checksum)
            then
                self:_reply(clientId, Protocol.ACTION.ASSET_READY, {
                    assetKey = assetKey,
                    size = tonumber(payload.size),
                    checksum = payload.checksum,
                })
            else
                self:_reply(clientId, Protocol.ACTION.ASSET_ERROR, {
                    assetKey = assetKey,
                    reason = "asset transfer is not active",
                })
            end
            return true
        end

        local actualChecksum = checksumText(transfer.checksumA, transfer.checksumB)
        if transfer.receivedSize ~= transfer.expectedSize
            or actualChecksum ~= tostring(transfer.expectedChecksum)
        then
            self:_discardTransfer(key)
            self:_reply(clientId, Protocol.ACTION.ASSET_ERROR, {
                assetKey = assetKey,
                reason = "asset size or checksum mismatch",
            })
            return true
        end

        self:_discardTransfer(key)

        local slotKey = transferKey(clientId, transfer.logicalKey)
        local previousAssetKey = self.assetSlots[slotKey]
        if previousAssetKey then
            self:_removeRemoteAsset(clientId, previousAssetKey)
        end

        self.remoteAssets[key] = {
            logicalKey = transfer.logicalKey,
            size = transfer.expectedSize,
            checksum = transfer.expectedChecksum,
            chunks = transfer.chunks,
            lastUsedAt = now(),
        }
        self.remoteBytes = self.remoteBytes + transfer.expectedSize
        self.assetSlots[slotKey] = assetKey

        if self.logger then
            self.logger.info(("Cached Client asset in RAM: source=%s key=%s size=%d"):format(
                tostring(clientId),
                assetKey,
                transfer.expectedSize
            ))
        end

        self:_reply(clientId, Protocol.ACTION.ASSET_READY, {
            assetKey = assetKey,
            size = transfer.expectedSize,
            checksum = transfer.expectedChecksum,
        })
        return true
    end

    return false
end

return AssetServer
