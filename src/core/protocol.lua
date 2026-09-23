local Protocol = {}

Protocol.SYSTEM = "railway_announcement_cs"
Protocol.VERSION = 3
Protocol.REDNET_PROTOCOL = "railway_announcement_cs_v3"
Protocol.PLAYBACK_EVENT = "railway_playback_response"
Protocol.ASSET_EVENT = "railway_asset_response"
Protocol.SERVER_QUEUE_EVENT = "railway_server_queue_changed"

Protocol.ACTION = {
    SERVER_DISCOVER = "SERVER_DISCOVER",
    SERVER_PRESENCE = "SERVER_PRESENCE",
    SERVER_CLAIM = "SERVER_CLAIM",
    CLIENT_PRESENCE = "CLIENT_PRESENCE",

    ASSET_QUERY = "ASSET_QUERY",
    ASSET_NEED = "ASSET_NEED",
    ASSET_BEGIN = "ASSET_BEGIN",
    ASSET_BEGIN_ACK = "ASSET_BEGIN_ACK",
    ASSET_CHUNK = "ASSET_CHUNK",
    ASSET_CHUNK_ACK = "ASSET_CHUNK_ACK",
    ASSET_COMMIT = "ASSET_COMMIT",
    ASSET_READY = "ASSET_READY",
    ASSET_ERROR = "ASSET_ERROR",

    PLAY_REQUEST = "PLAY_REQUEST",
    PLAY_CANCEL = "PLAY_CANCEL",
    PLAY_ACCEPTED = "PLAY_ACCEPTED",
    PLAY_STARTED = "PLAY_STARTED",
    PLAY_COMPLETED = "PLAY_COMPLETED",
    PLAY_INTERRUPTED = "PLAY_INTERRUPTED",
    PLAY_CANCELLED = "PLAY_CANCELLED",
    PLAY_FAILED = "PLAY_FAILED",
    PLAY_EXPIRED = "PLAY_EXPIRED",
    PLAY_REJECTED = "PLAY_REJECTED",
    GUIDANCE_STATE = "GUIDANCE_STATE",
}

local messageSequence = 0

local function now()
    return os.epoch("utc")
end

-- function: Return the configured logical speaker group without requiring a config migration.
function Protocol.groupId(config)
    local speaker = type(config) == "table" and config.speaker or nil
    if type(speaker) ~= "table" then
        return "default"
    end

    if type(speaker.groupId) == "string" and speaker.groupId ~= "" then
        return speaker.groupId
    end

    local shared = type(speaker.shared) == "table" and speaker.shared or nil
    if type(shared) == "table"
        and type(shared.protocol) == "string"
        and shared.protocol ~= ""
    then
        return shared.protocol
    end

    return "default"
end

-- function: Open every attached modem for rednet and return whether networking is usable.
function Protocol.openNetwork(logger)
    if type(rednet) ~= "table" or type(rednet.open) ~= "function" then
        return false
    end

    local opened = false
    local modems = { peripheral.find("modem") }
    for _, modem in ipairs(modems) do
        local okName, name = pcall(peripheral.getName, modem)
        if okName and name then
            local alreadyOpen = type(rednet.isOpen) == "function" and rednet.isOpen(name)
            if alreadyOpen then
                opened = true
            else
                local ok = pcall(rednet.open, name)
                opened = opened or ok
            end
        end
    end

    if not opened and logger then
        logger.warn("Announcement C/S network unavailable: no usable modem found")
    end

    return opened
end

-- function: Build one protocol envelope.
function Protocol.message(groupId, action, payload, instanceId)
    messageSequence = messageSequence + 1
    local computerId = os.getComputerID()

    return {
        system = Protocol.SYSTEM,
        version = Protocol.VERSION,
        groupId = tostring(groupId),
        action = action,
        senderId = computerId,
        instanceId = instanceId,
        messageId = ("%s:%s:%s"):format(
            tostring(computerId),
            tostring(now()),
            tostring(messageSequence)
        ),
        sentAt = now(),
        payload = payload or {},
    }
end

-- function: Return whether a message belongs to this protocol and logical group.
function Protocol.matches(message, groupId)
    return type(message) == "table"
        and message.system == Protocol.SYSTEM
        and message.version == Protocol.VERSION
        and tostring(message.groupId) == tostring(groupId)
        and type(message.action) == "string"
end

-- function: Send one point-to-point protocol message.
function Protocol.send(targetId, groupId, action, payload, instanceId)
    targetId = tonumber(targetId)
    if not targetId then
        return false
    end

    local ok = pcall(
        rednet.send,
        targetId,
        Protocol.message(groupId, action, payload, instanceId),
        Protocol.REDNET_PROTOCOL
    )
    return ok
end

-- function: Broadcast one protocol message.
function Protocol.broadcast(groupId, action, payload, instanceId)
    local ok = pcall(
        rednet.broadcast,
        Protocol.message(groupId, action, payload, instanceId),
        Protocol.REDNET_PROTOCOL
    )
    return ok
end

return Protocol
