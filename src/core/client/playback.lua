local Protocol = require("core.protocol")

local PlaybackClient = {}
PlaybackClient.__index = PlaybackClient

local TERMINAL_ACTIONS = {
    [Protocol.ACTION.PLAY_COMPLETED] = true,
    [Protocol.ACTION.PLAY_INTERRUPTED] = true,
    [Protocol.ACTION.PLAY_CANCELLED] = true,
    [Protocol.ACTION.PLAY_FAILED] = true,
    [Protocol.ACTION.PLAY_EXPIRED] = true,
    [Protocol.ACTION.PLAY_REJECTED] = true,
}

-- function: Create a playback proxy bound to one announcement server.
function PlaybackClient.new(options)
    return setmetatable({
        groupId = options.groupId,
        serverId = options.serverId,
        instanceId = options.instanceId,
        localServer = options.localServer,
        logger = options.logger,
        requestSequence = 0,
        current = nil,
    }, PlaybackClient)
end

-- function: Build a request ID unique to this boot instance.
function PlaybackClient:_nextRequestId()
    self.requestSequence = self.requestSequence + 1
    return ("%s:%s"):format(tostring(self.instanceId), tostring(self.requestSequence))
end

-- function: Submit one playback request through local or rednet transport.
function PlaybackClient:_submit(payload)
    if self.localServer then
        self.localServer:submit(os.getComputerID(), payload)
        return true
    end

    return Protocol.send(
        self.serverId,
        self.groupId,
        Protocol.ACTION.PLAY_REQUEST,
        payload,
        self.instanceId
    )
end

-- function: Cancel the current submitted request when a higher local priority supersedes it.
function PlaybackClient:_cancelCurrent()
    if not self.current or self.current.cancelRequested then
        return false
    end

    self.current.cancelRequested = true
    if self.localServer then
        self.localServer:cancel(os.getComputerID(), self.current.requestId)
    else
        Protocol.send(
            self.serverId,
            self.groupId,
            Protocol.ACTION.PLAY_CANCEL,
            { requestId = self.current.requestId },
            self.instanceId
        )
    end
    return true
end

-- function: Cancel an outstanding lower-priority local request.
function PlaybackClient:interruptBelow(priority)
    priority = tonumber(priority) or 0
    if not self.current or priority <= self.current.priority then
        return false
    end

    return self:_cancelCurrent()
end

-- function: Wait for one lifecycle response for the active request.
function PlaybackClient:_waitResponse(requestId)
    while true do
        local event = { os.pullEvent() }

        if event[1] == Protocol.PLAYBACK_EVENT then
            local message = event[2]
            if type(message) == "table"
                and Protocol.matches(message, self.groupId)
                and type(message.payload) == "table"
                and message.payload.requestId == requestId
            then
                return message
            end
        elseif event[1] == "rednet_message" then
            local senderId = tonumber(event[2])
            local message = event[3]
            local protocol = event[4]

            if senderId == self.serverId
                and protocol == Protocol.REDNET_PROTOCOL
                and Protocol.matches(message, self.groupId)
                and type(message.payload) == "table"
                and message.payload.requestId == requestId
            then
                return message
            end
        end
    end
end

-- function: Submit one composed announcement and wait for its terminal lifecycle event.
function PlaybackClient:playSegments(segments, priority, onAudioStarted, announcementType, expiresAt)
    local requestId = self:_nextRequestId()
    local request = {
        requestId = requestId,
        priority = tonumber(priority) or 0,
        createdAt = os.epoch("utc"),
        expiresAt = tonumber(expiresAt),
        segments = segments,
        label = type(announcementType) == "string" and announcementType or nil,
    }

    self.current = {
        requestId = requestId,
        priority = request.priority,
        cancelRequested = false,
    }

    if not self:_submit(request) then
        self.current = nil
        return false
    end

    local started = false

    while true do
        local message = self:_waitResponse(requestId)
        local action = message.action
        local payload = message.payload or {}

        if action == Protocol.ACTION.PLAY_STARTED and not started then
            started = true
            if onAudioStarted then
                onAudioStarted(tonumber(payload.startedAt) or os.epoch("utc"))
            end
        elseif TERMINAL_ACTIONS[action] then
            self.current = nil
            return action == Protocol.ACTION.PLAY_COMPLETED
        end
    end
end

return PlaybackClient
