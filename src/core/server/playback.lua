local Protocol = require("core.protocol")

local PlaybackServer = {}
PlaybackServer.__index = PlaybackServer

local function now()
    return os.epoch("utc")
end

local function priorityOf(request)
    return tonumber(request.priority) or 0
end

-- function: Create the authoritative playback server and global queue.
function PlaybackServer.new(options)
    local self = setmetatable({
        player = options.player,
        logger = options.logger,
        guidance = options.guidance,
        groupId = options.groupId,
        instanceId = options.instanceId,
        queue = {},
        sequence = 0,
        current = nil,
        seen = {},
    }, PlaybackServer)

    if self.guidance then
        self.guidance:setPlaybackServer(self)
    end
    return self
end

-- function: Reply through local event transport or rednet.
function PlaybackServer:_reply(clientId, action, payload)
    local message = Protocol.message(self.groupId, action, payload, self.instanceId)

    if tonumber(clientId) == os.getComputerID() then
        os.queueEvent(Protocol.PLAYBACK_EVENT, message)
        return true
    end

    local ok = pcall(rednet.send, clientId, message, Protocol.REDNET_PROTOCOL)
    return ok
end

-- function: Validate a client playback request without interpreting railway type.
function PlaybackServer:_validate(sourceId, request)
    if type(request) ~= "table" then
        return false, "request must be a table"
    end
    if type(request.requestId) ~= "string" or request.requestId == "" then
        return false, "requestId is required"
    end
    if type(request.segments) ~= "table" or #request.segments == 0 then
        return false, "segments are required"
    end
    if tonumber(sourceId) == nil then
        return false, "sourceId is invalid"
    end
    return true
end

-- function: Return the highest-priority oldest server-received queued item.
function PlaybackServer:_bestIndex()
    local bestIndex = nil
    local bestPriority = nil
    local bestSequence = nil

    for index, request in ipairs(self.queue) do
        local priority = priorityOf(request)
        local sequence = tonumber(request.serverSequence) or math.huge
        if bestIndex == nil
            or priority > bestPriority
            or (priority == bestPriority and sequence < bestSequence)
        then
            bestIndex = index
            bestPriority = priority
            bestSequence = sequence
        end
    end

    return bestIndex
end

-- function: Remove a queued guidance bell superseded by normal work or policy.
function PlaybackServer:_dropQueuedGuidanceBelow(priority)
    priority = tonumber(priority) or 0

    for index = #self.queue, 1, -1 do
        local request = self.queue[index]
        if request.internalGuidance == true and priority > priorityOf(request) then
            table.remove(self.queue, index)
            if self.guidance then
                self.guidance:onPlaybackFinished(request, false, now())
            end
        end
    end
end

-- function: Add one request to the authoritative queue.
function PlaybackServer:_enqueue(request)
    if request.internalGuidance ~= true then
        self:_dropQueuedGuidanceBelow(priorityOf(request))
    end

    self.sequence = self.sequence + 1
    request.serverSequence = self.sequence
    self.queue[#self.queue + 1] = request
    os.queueEvent(Protocol.SERVER_QUEUE_EVENT)

    if self.current and priorityOf(request) > priorityOf(self.current) then
        self.player:interruptBelow(priorityOf(request))
    end
end

-- function: Submit a client request, deduplicating by source and request ID.
function PlaybackServer:submit(sourceId, request)
    sourceId = tonumber(sourceId)
    local valid, reason = self:_validate(sourceId, request)
    if not valid then
        if sourceId then
            self:_reply(sourceId, Protocol.ACTION.PLAY_REJECTED, {
                requestId = type(request) == "table" and request.requestId or nil,
                reason = reason,
            })
        end
        return false
    end

    local seenKey = ("%s:%s"):format(tostring(sourceId), request.requestId)
    local seen = self.seen[seenKey]
    if seen then
        self:_reply(sourceId, seen.action or Protocol.ACTION.PLAY_ACCEPTED, seen.payload or {
            requestId = request.requestId,
            duplicate = true,
        })
        return true
    end

    local queued = {
        requestId = request.requestId,
        sourceId = sourceId,
        priority = tonumber(request.priority) or 0,
        createdAt = tonumber(request.createdAt) or now(),
        expiresAt = tonumber(request.expiresAt),
        segments = request.segments,
        label = request.label,
        internalGuidance = false,
    }

    self.seen[seenKey] = {
        action = Protocol.ACTION.PLAY_ACCEPTED,
        payload = { requestId = queued.requestId },
    }

    self:_reply(sourceId, Protocol.ACTION.PLAY_ACCEPTED, {
        requestId = queued.requestId,
        acceptedAt = now(),
    })
    self:_enqueue(queued)
    return true
end

-- function: Submit one server-internal request such as the shared guidance bell.
function PlaybackServer:submitInternal(request)
    if type(request) ~= "table"
        or type(request.requestId) ~= "string"
        or type(request.segments) ~= "table"
        or #request.segments == 0
    then
        return false
    end

    local queued = {
        requestId = request.requestId,
        sourceId = 0,
        priority = tonumber(request.priority) or 0,
        createdAt = tonumber(request.createdAt) or now(),
        expiresAt = tonumber(request.expiresAt),
        segments = request.segments,
        label = request.label,
        internalGuidance = request.internalGuidance == true,
    }
    self:_enqueue(queued)
    return true
end

-- function: Cancel one queued or active request from its owning client.
function PlaybackServer:cancel(sourceId, requestId)
    sourceId = tonumber(sourceId)
    requestId = tostring(requestId or "")
    if not sourceId or requestId == "" then
        return false
    end

    local seenKey = ("%s:%s"):format(tostring(sourceId), requestId)
    local seen = self.seen[seenKey]
    if seen and seen.action ~= Protocol.ACTION.PLAY_ACCEPTED then
        self:_reply(sourceId, seen.action, seen.payload or { requestId = requestId })
        return true
    end

    for index = #self.queue, 1, -1 do
        local request = self.queue[index]
        if request.sourceId == sourceId and request.requestId == requestId then
            table.remove(self.queue, index)
            self:_finishClientRequest(request, Protocol.ACTION.PLAY_CANCELLED, {
                requestId = requestId,
                cancelledAt = now(),
            })
            return true
        end
    end

    if self.current
        and self.current.sourceId == sourceId
        and self.current.requestId == requestId
    then
        self.current.cancelRequested = true
        self.player:interrupt()
        return true
    end

    local payload = {
        requestId = requestId,
        cancelledAt = now(),
    }
    self.seen[seenKey] = {
        action = Protocol.ACTION.PLAY_CANCELLED,
        payload = payload,
    }
    self:_reply(sourceId, Protocol.ACTION.PLAY_CANCELLED, payload)
    return true
end

-- function: Interrupt a currently playing guidance bell when policy becomes blocked.
function PlaybackServer:interruptGuidance()
    local changed = false

    for index = #self.queue, 1, -1 do
        local request = self.queue[index]
        if request.internalGuidance == true then
            table.remove(self.queue, index)
            changed = true
            if self.guidance then
                self.guidance:onPlaybackFinished(request, false, now())
            end
        end
    end

    if self.current and self.current.internalGuidance == true then
        self.current.cancelRequested = true
        changed = self.player:interrupt() or changed
    end

    if changed then
        os.queueEvent(Protocol.SERVER_QUEUE_EVENT)
    end
    return changed
end

-- function: Return whether no request is playing or waiting.
function PlaybackServer:isIdle()
    return self.current == nil and #self.queue == 0
end

-- function: Store and send a terminal lifecycle event for a client request.
function PlaybackServer:_finishClientRequest(request, action, payload)
    if request.sourceId == 0 then
        return
    end

    local seenKey = ("%s:%s"):format(tostring(request.sourceId), request.requestId)
    self.seen[seenKey] = {
        action = action,
        payload = payload,
    }
    self:_reply(request.sourceId, action, payload)
end

-- function: Return the next non-expired queued request.
function PlaybackServer:_pop()
    while true do
        local index = self:_bestIndex()
        if not index then
            return nil
        end

        local request = table.remove(self.queue, index)
        if request.expiresAt and request.expiresAt < now() then
            self:_finishClientRequest(request, Protocol.ACTION.PLAY_EXPIRED, {
                requestId = request.requestId,
                expiredAt = now(),
            })
        else
            return request
        end
    end
end

-- function: Wait until the authoritative queue contains a playable request.
function PlaybackServer:_waitNext()
    while true do
        local request = self:_pop()
        if request then
            return request
        end
        os.pullEvent(Protocol.SERVER_QUEUE_EVENT)
    end
end

-- function: Process queued requests sequentially while allowing network-side interruption.
function PlaybackServer:_processQueue()
    while true do
        local request = self:_waitNext()
        self.current = request
        request.cancelRequested = false

        if self.logger and not request.internalGuidance then
            self.logger.info(("Server playing: %s priority=%s source=%s"):format(
                tostring(request.label or request.requestId),
                tostring(request.priority),
                tostring(request.sourceId)
            ))
        end

        local startedAt = nil
        local completed = false
        local ok, result = pcall(function()
            return self.player:playSegments(
                request.segments,
                request.priority,
                function(epoch)
                    startedAt = tonumber(epoch) or now()
                    if request.sourceId ~= 0 then
                        self:_reply(request.sourceId, Protocol.ACTION.PLAY_STARTED, {
                            requestId = request.requestId,
                            startedAt = startedAt,
                        })
                    end
                end,
                request.label
            )
        end)

        if ok then
            completed = result == true
        end

        local completedAt = now()
        if request.sourceId ~= 0 then
            if not ok then
                self:_finishClientRequest(request, Protocol.ACTION.PLAY_FAILED, {
                    requestId = request.requestId,
                    failedAt = completedAt,
                    reason = tostring(result),
                })
            elseif completed then
                self:_finishClientRequest(request, Protocol.ACTION.PLAY_COMPLETED, {
                    requestId = request.requestId,
                    startedAt = startedAt,
                    completedAt = completedAt,
                })
            elseif request.cancelRequested then
                self:_finishClientRequest(request, Protocol.ACTION.PLAY_CANCELLED, {
                    requestId = request.requestId,
                    startedAt = startedAt,
                    cancelledAt = completedAt,
                })
            else
                self:_finishClientRequest(request, Protocol.ACTION.PLAY_INTERRUPTED, {
                    requestId = request.requestId,
                    startedAt = startedAt,
                    interruptedAt = completedAt,
                })
            end
        end

        if self.guidance then
            self.guidance:onPlaybackFinished(request, completed, completedAt)
        end

        self.current = nil
        os.queueEvent(Protocol.SERVER_QUEUE_EVENT)
    end
end

-- function: Apply client liveness and embedded guidance state from heartbeat traffic.
function PlaybackServer:observeClientPresence(clientId, payload)
    if not self.guidance then
        return
    end

    self.guidance:touchClient(clientId)
    if type(payload) == "table" and type(payload.guidanceState) == "table" then
        self.guidance:updateClient(clientId, payload.guidanceState)
    end
end

-- function: Apply an explicit client guidance state packet.
function PlaybackServer:observeGuidanceState(clientId, state)
    if self.guidance then
        self.guidance:updateClient(clientId, state)
    end
end

-- function: Receive remote client playback and guidance traffic.
function PlaybackServer:_monitorNetwork()
    while true do
        local _, senderId, message, protocol = os.pullEvent("rednet_message")
        if protocol == Protocol.REDNET_PROTOCOL and Protocol.matches(message, self.groupId) then
            senderId = tonumber(senderId)
            local payload = message.payload or {}

            if message.action == Protocol.ACTION.PLAY_REQUEST then
                self:submit(senderId, payload)
            elseif message.action == Protocol.ACTION.PLAY_CANCEL then
                self:cancel(senderId, payload.requestId)
            elseif message.action == Protocol.ACTION.GUIDANCE_STATE then
                self:observeGuidanceState(senderId, payload)
            elseif message.action == Protocol.ACTION.CLIENT_PRESENCE then
                self:observeClientPresence(senderId, payload)
            end
        end
    end
end

-- function: Run network intake, global queue processing, and the server guidance service.
function PlaybackServer:run()
    local guidanceTask = function()
        if self.guidance then
            self.guidance:run()
        else
            while true do
                sleep(60)
            end
        end
    end

    parallel.waitForAll(
        function()
            self:_monitorNetwork()
        end,
        function()
            self:_processQueue()
        end,
        guidanceTask
    )
end

return PlaybackServer
