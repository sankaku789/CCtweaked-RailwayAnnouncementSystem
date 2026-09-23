local GuidanceServer = {}
GuidanceServer.__index = GuidanceServer

local DEFAULT_PATH = "audio/guidance/bell.dfpwm"
local DEFAULT_INTERVAL_SECONDS = 5
local DEFAULT_PRIORITY = -1
local CLIENT_LEASE_MS = 3500
local CHECK_SECONDS = 0.05

local function now()
    return os.epoch("utc")
end

-- function: Create the server-side shared guidance bell service.
function GuidanceServer.new(options, logger)
    options = type(options) == "table" and options or {}

    local intervalSeconds = tonumber(options.intervalSeconds) or DEFAULT_INTERVAL_SECONDS
    if intervalSeconds <= 0 then
        intervalSeconds = DEFAULT_INTERVAL_SECONDS
    end

    local initialDelaySeconds = math.max(0, tonumber(options.initialDelaySeconds) or 0)
    local path = type(options.path) == "string" and options.path or DEFAULT_PATH
    if path == "" then
        path = DEFAULT_PATH
    end

    local self = setmetatable({
        enabled = options.enabled == true,
        path = path,
        priority = tonumber(options.priority) or DEFAULT_PRIORITY,
        initialDelaySeconds = initialDelaySeconds,
        intervalSeconds = intervalSeconds,
        logger = logger,
        clients = {},
        nextBellAt = nil,
        playbackServer = nil,
        guidanceRequestId = nil,
        requestSequence = 0,
    }, GuidanceServer)

    if self.enabled and self:_validFile() then
        self.nextBellAt = now() + (self.initialDelaySeconds * 1000)
    elseif self.enabled and logger then
        logger.warn("Guidance bell disabled because audio was not found: " .. tostring(self.path))
        self.enabled = false
    end

    return self
end

-- function: Return whether the configured bell audio exists.
function GuidanceServer:_validFile()
    return type(self.path) == "string"
        and self.path ~= ""
        and fs.exists(self.path)
        and not fs.isDir(self.path)
end

-- function: Attach the authoritative playback server.
function GuidanceServer:setPlaybackServer(server)
    self.playbackServer = server
end

-- function: Create fresh per-client state for one boot instance.
function GuidanceServer:_newClientState(instanceId)
    return {
        instanceId = instanceId,
        revision = -1,
        blocked = false,
        resumeAt = nil,
        lastSeen = now(),
    }
end

-- function: Refresh one client's lease and reset revision history after a client reboot.
function GuidanceServer:touchClient(clientId, instanceId)
    clientId = tonumber(clientId)
    if not clientId then
        return nil
    end

    local state = self.clients[clientId]
    local changedInstance = state
        and instanceId ~= nil
        and state.instanceId ~= nil
        and tostring(instanceId) ~= tostring(state.instanceId)

    if not state or changedInstance then
        local removedConstraint = state
            and (state.blocked == true
                or (tonumber(state.resumeAt) ~= nil and tonumber(state.resumeAt) > now()))
        state = self:_newClientState(instanceId)
        self.clients[clientId] = state

        if removedConstraint and self.nextBellAt == nil then
            self.nextBellAt = now() + (self.initialDelaySeconds * 1000)
        end
    else
        if state.instanceId == nil and instanceId ~= nil then
            state.instanceId = instanceId
        end
        state.lastSeen = now()
    end

    return state
end

-- function: Apply one revisioned guidance state from a client.
function GuidanceServer:updateClient(clientId, incoming, instanceId)
    clientId = tonumber(clientId)
    if not clientId or type(incoming) ~= "table" then
        return false
    end

    local revision = tonumber(incoming.revision)
    if revision == nil then
        return false
    end

    local state = self:touchClient(clientId, instanceId)
    if state and revision < (tonumber(state.revision) or -1) then
        state.lastSeen = now()
        return false
    end

    local wasBlocked = state and state.blocked == true or false
    local blocked = incoming.blocked == true
    local resumeAt = tonumber(incoming.resumeAt)
    if blocked then
        resumeAt = nil
    elseif resumeAt and resumeAt <= now() then
        resumeAt = nil
    end

    self.clients[clientId] = {
        instanceId = instanceId or (state and state.instanceId) or nil,
        revision = revision,
        blocked = blocked,
        resumeAt = resumeAt,
        lastSeen = now(),
    }

    if blocked then
        self.nextBellAt = nil
        if self.playbackServer then
            self.playbackServer:interruptGuidance()
        end
    elseif resumeAt then
        if self.nextBellAt == nil or self.nextBellAt < resumeAt then
            self.nextBellAt = resumeAt
        end
    elseif wasBlocked and self.nextBellAt == nil then
        self.nextBellAt = now() + (self.initialDelaySeconds * 1000)
    end

    return true
end

-- function: Remove expired client states so a crashed client cannot block guidance forever.
function GuidanceServer:_pruneClients()
    local current = now()
    local removedConstraint = false

    for clientId, state in pairs(self.clients) do
        if current - (tonumber(state.lastSeen) or 0) > CLIENT_LEASE_MS then
            if state.blocked == true
                or (tonumber(state.resumeAt) ~= nil and tonumber(state.resumeAt) > current)
            then
                removedConstraint = true
            end
            self.clients[clientId] = nil
        end
    end

    if removedConstraint and self.nextBellAt == nil then
        self.nextBellAt = current + (self.initialDelaySeconds * 1000)
    end
end

-- function: Return whether any live client currently suppresses guidance.
function GuidanceServer:_constraint()
    local current = now()
    local resumeAt = nil

    for _, state in pairs(self.clients) do
        if state.blocked == true then
            return true, nil
        end

        local candidate = tonumber(state.resumeAt)
        if candidate and candidate > current and (resumeAt == nil or candidate > resumeAt) then
            resumeAt = candidate
        end
    end

    return false, resumeAt
end

-- function: Record playback lifecycle transitions that affect the bell cadence.
function GuidanceServer:onPlaybackFinished(request, completed, completedAt)
    if not self.enabled then
        return
    end

    completedAt = tonumber(completedAt) or now()

    if request.internalGuidance == true then
        self.guidanceRequestId = nil
        if completed then
            self.nextBellAt = completedAt + (self.intervalSeconds * 1000)
        else
            -- Leave the deadline unresolved until the normal request which
            -- interrupted this bell finishes and publishes its own policy.
            self.nextBellAt = nil
        end
        return
    end

    local blocked, resumeAt = self:_constraint()
    if blocked then
        self.nextBellAt = nil
    elseif resumeAt then
        self.nextBellAt = resumeAt
    else
        local intervalAt = completedAt + (self.intervalSeconds * 1000)
        if self.nextBellAt == nil or self.nextBellAt < intervalAt then
            self.nextBellAt = intervalAt
        end
    end
end

-- function: Queue one internal guidance request when the shared speaker is idle and due.
function GuidanceServer:_tryQueueBell()
    if not self.enabled or not self.playbackServer or self.guidanceRequestId ~= nil then
        return
    end

    self:_pruneClients()

    local blocked, resumeAt = self:_constraint()
    if blocked then
        self.nextBellAt = nil
        return
    end

    if resumeAt then
        if self.nextBellAt == nil or self.nextBellAt < resumeAt then
            self.nextBellAt = resumeAt
        end
        return
    end

    -- Never invent a new initial-delay deadline while normal playback is active
    -- or queued. Its completion/state transition decides the correct restart
    -- policy (for example passing uses interval, departure uses initial delay).
    if not self.playbackServer:isIdle() then
        return
    end

    if self.nextBellAt == nil then
        self.nextBellAt = now() + (self.initialDelaySeconds * 1000)
        return
    end

    if now() < self.nextBellAt then
        return
    end

    self.requestSequence = self.requestSequence + 1
    local requestId = ("guidance:%s:%s"):format(
        tostring(os.getComputerID()),
        tostring(self.requestSequence)
    )

    if self.playbackServer:submitInternal({
        requestId = requestId,
        priority = self.priority,
        createdAt = now(),
        segments = { self.path },
        internalGuidance = true,
        label = "guidance_bell",
    }) then
        self.guidanceRequestId = requestId
        self.nextBellAt = nil
    end
end

-- function: Run the shared guidance cadence loop.
function GuidanceServer:run()
    if not self.enabled then
        while true do
            sleep(60)
        end
    end

    if self.logger then
        self.logger.info(("Guidance server enabled (initial=%.1fs interval=%.1fs)"):format(
            self.initialDelaySeconds,
            self.intervalSeconds
        ))
    end

    while true do
        self:_tryQueueBell()
        sleep(CHECK_SECONDS)
    end
end

return GuidanceServer
