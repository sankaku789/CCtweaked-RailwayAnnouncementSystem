local Protocol = require("core.protocol")

local AssetServer = {}
AssetServer.__index = AssetServer

local CACHE_ROOT = "/.railway_announcement_assets"
local MAX_ASSET_BYTES = 32 * 1024 * 1024
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

-- function: Create the Server-side cache for Client-owned audio assets.
function AssetServer.new(options)
    return setmetatable({
        groupId = options.groupId,
        instanceId = options.instanceId,
        logger = options.logger,
        localAssets = {},
        transfers = {},
    }, AssetServer)
end

-- function: Return cache, metadata, and temporary paths for one Client asset.
function AssetServer:_paths(sourceId, assetKey)
    local directory = fs.combine(CACHE_ROOT, tostring(sourceId))
    local base = fs.combine(directory, assetKey)
    return directory, base .. ".dfpwm", base .. ".meta", base .. ".tmp"
end

-- function: Read persisted cache metadata.
function AssetServer:_readMeta(path)
    if not fs.exists(path) or fs.isDir(path) then
        return nil
    end

    local handle = fs.open(path, "r")
    if not handle then
        return nil
    end
    local content = handle.readAll()
    handle.close()

    local value = textutils.unserialize(content)
    if type(value) ~= "table" then
        return nil
    end
    return value
end

-- function: Return whether one persisted asset exactly matches the requested signature.
function AssetServer:_cacheMatches(sourceId, assetKey, size, checksum)
    local _, assetPath, metaPath = self:_paths(sourceId, assetKey)
    if not fs.exists(assetPath) or fs.isDir(assetPath) then
        return false
    end

    local meta = self:_readMeta(metaPath)
    if not meta then
        return false
    end

    return tonumber(meta.size) == tonumber(size)
        and tostring(meta.checksum) == tostring(checksum)
        and fs.getSize(assetPath) == tonumber(size)
end

-- function: Return whether one persisted asset is safe to resolve for playback.
function AssetServer:_cachedPath(sourceId, assetKey)
    local _, assetPath, metaPath = self:_paths(sourceId, assetKey)
    if not fs.exists(assetPath) or fs.isDir(assetPath) then
        return nil
    end

    local meta = self:_readMeta(metaPath)
    if type(meta) ~= "table"
        or not validSize(meta.size)
        or type(meta.checksum) ~= "string"
        or fs.getSize(assetPath) ~= tonumber(meta.size)
    then
        return nil
    end

    return assetPath
end

-- function: Close and discard one unfinished transfer.
function AssetServer:_discardTransfer(key)
    local transfer = self.transfers[key]
    if not transfer then
        return
    end

    if transfer.handle then
        pcall(transfer.handle.close)
    end
    if transfer.tempPath and fs.exists(transfer.tempPath) and not fs.isDir(transfer.tempPath) then
        fs.delete(transfer.tempPath)
    end
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

-- function: Register a local Client-owned asset without copying it through rednet.
function AssetServer:registerLocal(sourceId, assetKey, path, size, checksum)
    sourceId = tonumber(sourceId)
    if not sourceId or not validKey(assetKey) then
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

    self.localAssets[transferKey(sourceId, assetKey)] = path
    return true
end

-- function: Resolve one Client-owned asset to a Server-local path.
function AssetServer:resolve(sourceId, assetKey)
    sourceId = tonumber(sourceId)
    if not sourceId or not validKey(assetKey) then
        return nil
    end

    local key = transferKey(sourceId, assetKey)
    local localPath = self.localAssets[key]
    if localPath and fs.exists(localPath) and not fs.isDir(localPath) then
        return localPath
    end

    return self:_cachedPath(sourceId, assetKey)
end

-- function: Resolve Client asset references while leaving shared segments unchanged.
function AssetServer:resolveSegments(sourceId, segments)
    local resolved = {}

    for index, item in ipairs(segments or {}) do
        if type(item) == "table" and item.kind == "client_asset" then
            local assetKey = item.key
            local path = self:resolve(sourceId, assetKey)
            if not path then
                return nil, "Client asset is not synchronized: " .. tostring(assetKey)
            end
            resolved[index] = {
                kind = "audio",
                path = path,
            }
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

        local response = self:_cacheMatches(clientId, assetKey, payload.size, payload.checksum)
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

        self:_discardTransfer(key)
        local directory, _, _, tempPath = self:_paths(clientId, assetKey)
        if not fs.exists(directory) then
            fs.makeDir(directory)
        end
        if fs.exists(tempPath) and not fs.isDir(tempPath) then
            fs.delete(tempPath)
        end

        local handle, openError = fs.open(tempPath, "wb")
        if not handle then
            self:_reply(clientId, Protocol.ACTION.ASSET_ERROR, {
                assetKey = assetKey,
                reason = "could not open asset cache: " .. tostring(openError),
            })
            return true
        end

        self.transfers[key] = {
            handle = handle,
            tempPath = tempPath,
            expectedSize = tonumber(payload.size),
            expectedChecksum = payload.checksum,
            receivedSize = 0,
            nextIndex = 1,
            checksumA = 1,
            checksumB = 0,
            updatedAt = now(),
        }

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

        transfer.handle.write(data)
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
                and self:_cacheMatches(clientId, assetKey, payload.size, payload.checksum)
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

        transfer.handle.close()
        transfer.handle = nil

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

        local directory, assetPath, metaPath, tempPath = self:_paths(clientId, assetKey)
        if not fs.exists(directory) then
            fs.makeDir(directory)
        end
        if fs.exists(assetPath) then
            fs.delete(assetPath)
        end
        fs.move(tempPath, assetPath)

        local meta = fs.open(metaPath, "w")
        if not meta then
            if fs.exists(assetPath) then
                fs.delete(assetPath)
            end
            self.transfers[key] = nil
            self:_reply(clientId, Protocol.ACTION.ASSET_ERROR, {
                assetKey = assetKey,
                reason = "could not persist asset metadata",
            })
            return true
        end
        meta.write(textutils.serialize({
            size = transfer.expectedSize,
            checksum = transfer.expectedChecksum,
        }))
        meta.close()

        self.transfers[key] = nil
        if self.logger then
            self.logger.info(("Cached Client asset: source=%s key=%s size=%d"):format(
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
