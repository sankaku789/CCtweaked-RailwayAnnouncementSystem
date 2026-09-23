local Protocol = require("core.protocol")

local AssetClient = {}
AssetClient.__index = AssetClient

local CHUNK_SIZE = 8 * 1024
local RETRY_SECONDS = 0.5
local ADLER_MOD = 65521

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

local function checksumFile(path)
    if type(path) ~= "string" or path == "" or not fs.exists(path) or fs.isDir(path) then
        return nil, nil, "asset file was not found: " .. tostring(path)
    end

    local handle, openError = fs.open(path, "rb")
    if not handle then
        return nil, nil, "could not open asset file: " .. tostring(openError)
    end

    local size = 0
    local a = 1
    local b = 0

    while true do
        local chunk = handle.read(CHUNK_SIZE)
        if chunk == nil or chunk == "" then
            break
        end
        size = size + #chunk
        a, b = updateChecksum(a, b, chunk)
    end

    handle.close()
    return size, ("%08x"):format((b * 65536) + a), nil
end

-- function: Create a client-side synchronizer for Client-owned audio assets.
function AssetClient.new(options)
    return setmetatable({
        groupId = options.groupId,
        serverId = options.serverId,
        instanceId = options.instanceId,
        localAssetServer = options.localAssetServer,
        logger = options.logger,
    }, AssetClient)
end

-- function: Return one matching asset response from the bound Server.
function AssetClient:_waitResponse(assetKey, allowedActions, expectedIndex)
    local timer = os.startTimer(RETRY_SECONDS)

    while true do
        local event = { os.pullEvent() }
        if event[1] == "rednet_message"
            and tonumber(event[2]) == self.serverId
            and event[4] == Protocol.REDNET_PROTOCOL
        then
            local message = event[3]
            local payload = type(message) == "table" and message.payload or nil
            if Protocol.matches(message, self.groupId)
                and type(payload) == "table"
                and payload.assetKey == assetKey
                and allowedActions[message.action]
                and (expectedIndex == nil or tonumber(payload.index) == expectedIndex)
            then
                if type(os.cancelTimer) == "function" then
                    os.cancelTimer(timer)
                end
                return message
            end
        elseif event[1] == "timer" and event[2] == timer then
            return nil
        end
    end
end

-- function: Send one idempotent asset command until the Server replies.
function AssetClient:_request(action, payload, allowedActions, expectedIndex)
    while true do
        Protocol.send(
            self.serverId,
            self.groupId,
            action,
            payload,
            self.instanceId
        )

        local response = self:_waitResponse(payload.assetKey, allowedActions, expectedIndex)
        if response then
            return response
        end
    end
end

-- function: Synchronize one Client-owned asset before announcements start.
function AssetClient:sync(assetKey, path)
    if not validKey(assetKey) then
        return false, "invalid asset key: " .. tostring(assetKey)
    end

    local size, checksum, checksumError = checksumFile(path)
    if not size then
        return false, checksumError
    end

    if self.localAssetServer then
        local ok, reason = self.localAssetServer:registerLocal(
            os.getComputerID(),
            assetKey,
            path,
            size,
            checksum
        )
        if ok and self.logger then
            self.logger.info(("Client asset ready: %s (%d bytes, local)"):format(assetKey, size))
        end
        return ok, reason
    end

    local query = self:_request(
        Protocol.ACTION.ASSET_QUERY,
        {
            assetKey = assetKey,
            size = size,
            checksum = checksum,
        },
        {
            [Protocol.ACTION.ASSET_READY] = true,
            [Protocol.ACTION.ASSET_NEED] = true,
            [Protocol.ACTION.ASSET_ERROR] = true,
        }
    )

    if query.action == Protocol.ACTION.ASSET_ERROR then
        return false, tostring((query.payload or {}).reason or "asset query failed")
    end

    if query.action == Protocol.ACTION.ASSET_READY then
        if self.logger then
            self.logger.info(("Client asset ready: %s (%d bytes, cached)"):format(assetKey, size))
        end
        return true
    end

    local begin = self:_request(
        Protocol.ACTION.ASSET_BEGIN,
        {
            assetKey = assetKey,
            size = size,
            checksum = checksum,
        },
        {
            [Protocol.ACTION.ASSET_BEGIN_ACK] = true,
            [Protocol.ACTION.ASSET_ERROR] = true,
        }
    )

    if begin.action == Protocol.ACTION.ASSET_ERROR then
        return false, tostring((begin.payload or {}).reason or "asset transfer could not start")
    end

    local handle, openError = fs.open(path, "rb")
    if not handle then
        return false, "could not reopen asset file: " .. tostring(openError)
    end

    local index = 1
    while true do
        local chunk = handle.read(CHUNK_SIZE)
        if chunk == nil or chunk == "" then
            break
        end

        local response = self:_request(
            Protocol.ACTION.ASSET_CHUNK,
            {
                assetKey = assetKey,
                index = index,
                data = chunk,
            },
            {
                [Protocol.ACTION.ASSET_CHUNK_ACK] = true,
                [Protocol.ACTION.ASSET_ERROR] = true,
            },
            index
        )

        if response.action == Protocol.ACTION.ASSET_ERROR then
            handle.close()
            return false, tostring((response.payload or {}).reason or "asset chunk failed")
        end

        index = index + 1
    end
    handle.close()

    local commit = self:_request(
        Protocol.ACTION.ASSET_COMMIT,
        {
            assetKey = assetKey,
            size = size,
            checksum = checksum,
        },
        {
            [Protocol.ACTION.ASSET_READY] = true,
            [Protocol.ACTION.ASSET_ERROR] = true,
        }
    )

    if commit.action == Protocol.ACTION.ASSET_ERROR then
        return false, tostring((commit.payload or {}).reason or "asset commit failed")
    end

    if self.logger then
        self.logger.info(("Client asset uploaded: %s (%d bytes)"):format(assetKey, size))
    end
    return true
end

return AssetClient
