local Protocol = require("core.protocol")

local PlaybackClient = {}
PlaybackClient.__index = PlaybackClient

local RETRY_SECONDS = 0.5

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

-- function: Send cancellation for the active request through local or rednet transport.
function PlaybackClient:_sendCancel(requestId)
    if self.localServer then
        self.localServer:cancel(os.getComputerID(), requestId)
        return true
    end

    return Protocol.send(
        self.serverId,
        self.groupId,
        Protocol.ACTION.PLAY_CANCEL,
        { requestId = requestId },
        self.instanceId
    )
end

-- function: Cancel the current submitted request when a higher local priority supersedes it.
function PlaybackClient:_cancelCurrent()
    if not self.current or self.current.cancelRequested then
        return false
    end

    self.current.cancelRequested = true
    self:_sendCancel(self.current.requestId)
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

-- function: Return a matching lifecycle packet from local or rednet transport.
function PlaybackClient:_matchingResponse(event, requestId)
    local message = nil

    if event[1] == Protocol.PLAYBACK_EVENT then
        message = event[2]
    elseif event[1] == "rednet_message"
        and tonumber(event[2]) == self.serverId
        and event[4] == Protocol.REDNET_PROTOCOL
    then
        message = event[3]
    end

    if type(message) ~= "table"
        or not Protocol.matches(message, self.groupId)
        or type(message.payload) ~= "table"
        or message.payload.requestId ~= requestId
    then
        return nil
    end

    return message
end

-- function: Wait for one lifecycle response, retrying the idempotent request/cancel on packet loss.
function PlaybackClient:_waitResponse(request)
    local retryTimer = nil
    if not self.localServer then
        retryTimer = os.startTimer(RETRY_SECONDS)
    end

    while true do
        local event = { os.pullEvent() }
        local message = self:_matchingResponse(event, request.requestId)
        if message then
            if retryTimer and type(os.cancelTimer) == "function" then
                os.cancelTimer(retryTimer)
            end
            return message
        end

        if retryTimer and event[1] == "timer" and event[2] == retryTimer then
            if self.current
                and self.current.requestId == request.requestId
                and self.current.cancelRequested
            then
                self:_sendCancel(request.requestId)
            else
                -- Reusing requestId is intentional: the Server deduplicates this
                -- retry and returns the latest lifecycle state without replaying.
                self:_submit(request)
            end
            retryTimer = os.startTimer(RETRY_SECONDS)
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

    self:_submit(request)

    local started = false

    while true do
        local message = self:_waitResponse(request)
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
