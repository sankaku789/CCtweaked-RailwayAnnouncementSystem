local Protocol = require("core.protocol")

local Coordinator = {}
Coordinator.__index = Coordinator

local BINDING_PATH = "/.railway_announcement_server"
local DISCOVERY_SECONDS = 0.5
local CLAIM_SECONDS = 0.4
local HEARTBEAT_SECONDS = 1
local SERVER_LEASE_MS = 3500
local REBOOT_DELAY_SECONDS = 0.5

local function now()
    return os.epoch("utc")
end

local function serializeBinding(groupId, serverId)
    return textutils.serialize({
        groupId = tostring(groupId),
        serverId = tonumber(serverId),
    })
end

-- function: Create a coordinator for one logical speaker group.
function Coordinator.new(config, logger)
    local groupId = Protocol.groupId(config)
    local computerId = os.getComputerID()

    return setmetatable({
        config = config,
        logger = logger,
        groupId = groupId,
        computerId = computerId,
        instanceId = ("%s:%s"):format(tostring(computerId), tostring(now())),
        serverId = nil,
        serverInstanceId = nil,
        isServer = false,
        lastServerSeenAt = nil,
        localServer = nil,
        guidanceProvider = nil,
        networkReady = false,
    }, Coordinator)
end

-- function: Read a persisted server binding for the current group.
function Coordinator:_loadBinding()
    if not fs.exists(BINDING_PATH) or fs.isDir(BINDING_PATH) then
        return nil
    end

    local handle = fs.open(BINDING_PATH, "r")
    if not handle then
        return nil
    end

    local content = handle.readAll()
    handle.close()

    local data = textutils.unserialize(content)
    if type(data) == "number" then
        data = { groupId = self.groupId, serverId = data }
    end

    if type(data) ~= "table"
        or tostring(data.groupId) ~= tostring(self.groupId)
        or tonumber(data.serverId) == nil
    then
        return nil
    end

    return tonumber(data.serverId)
end

-- function: Persist the selected server for future boots.
function Coordinator:_saveBinding(serverId)
    local temporary = BINDING_PATH .. ".tmp"
    local handle = fs.open(temporary, "w")
    if not handle then
        error("Could not persist announcement server binding")
    end

    handle.write(serializeBinding(self.groupId, serverId))
    handle.close()

    if fs.exists(BINDING_PATH) then
        fs.delete(BINDING_PATH)
    end
    fs.move(temporary, BINDING_PATH)
end

-- function: Reboot after a short delay when the bound server cannot be trusted.
function Coordinator:_reboot(reason)
    if self.logger then
        self.logger.warn(reason)
    end
    sleep(REBOOT_DELAY_SECONDS)
    os.reboot()
end

-- function: Receive matching protocol traffic until a deadline.
function Coordinator:_receiveUntil(deadline)
    while true do
        local remaining = (deadline - now()) / 1000
        if remaining <= 0 then
            return nil, nil
        end

        local senderId, message = rednet.receive(Protocol.REDNET_PROTOCOL, remaining)
        if not senderId then
            return nil, nil
        end

        if Protocol.matches(message, self.groupId) then
            return tonumber(senderId), message
        end
    end
end

-- function: Return one valid server presence whose sender owns the advertised ID.
function Coordinator:_serverPresence(senderId, message, expectedServerId)
    if message.action ~= Protocol.ACTION.SERVER_PRESENCE then
        return nil, nil
    end

    local advertisedId = tonumber((message.payload or {}).serverId) or tonumber(senderId)
    senderId = tonumber(senderId)
    if not senderId or advertisedId ~= senderId then
        return nil, nil
    end

    if expectedServerId ~= nil and advertisedId ~= tonumber(expectedServerId) then
        return nil, nil
    end

    return advertisedId, message.instanceId
end

-- function: Discover a specific server or any existing server during startup.
function Coordinator:_discover(expectedServerId)
    Protocol.broadcast(
        self.groupId,
        Protocol.ACTION.SERVER_DISCOVER,
        { expectedServerId = expectedServerId },
        self.instanceId
    )

    local deadline = now() + (DISCOVERY_SECONDS * 1000)

    while now() < deadline do
        local senderId, message = self:_receiveUntil(deadline)
        if not senderId then
            break
        end

        local serverId, serverInstanceId = self:_serverPresence(
            senderId,
            message,
            expectedServerId
        )
        if serverId then
            return serverId, serverInstanceId
        end
    end

    return nil, nil
end

-- function: Elect one server on first boot using a deterministic computer-ID tie-break.
function Coordinator:_claimServer()
    local winner = self.computerId

    -- Repeat the claim window so a computer which was still finishing discovery
    -- cannot miss an earlier lower-ID claim and incorrectly elect itself.
    for _ = 1, 3 do
        Protocol.broadcast(
            self.groupId,
            Protocol.ACTION.SERVER_CLAIM,
            { candidateId = winner },
            self.instanceId
        )

        local deadline = now() + (CLAIM_SECONDS * 1000)
        while now() < deadline do
            local senderId, message = self:_receiveUntil(deadline)
            if not senderId then
                break
            end

            local serverId, serverInstanceId = self:_serverPresence(senderId, message, nil)
            if serverId then
                return serverId, serverInstanceId
            end

            if message.action == Protocol.ACTION.SERVER_CLAIM then
                local candidateId = tonumber((message.payload or {}).candidateId) or senderId
                if candidateId < winner then
                    winner = candidateId
                end
            end
        end
    end

    return winner, winner == self.computerId and self.instanceId or nil
end

-- function: Resolve this computer's fixed server binding for the current boot.
function Coordinator:initialize()
    local boundServerId = self:_loadBinding()
    self.networkReady = Protocol.openNetwork(self.logger)

    -- Without a modem the only safe runtime is local C/S. Do not create a new
    -- persistent binding here: if networking is added later, normal discovery
    -- and election must still run instead of preserving an accidental split-brain.
    if not self.networkReady then
        if boundServerId and boundServerId ~= self.computerId then
            self:_reboot(("Bound announcement server %s requires network; rebooting"):format(
                tostring(boundServerId)
            ))
        end

        self.serverId = self.computerId
        self.serverInstanceId = self.instanceId
        self.isServer = true
        self.lastServerSeenAt = now()

        if self.logger then
            self.logger.info("No modem available; using local Client/Server transport.")
        end
        return self
    end

    if boundServerId then
        self.serverId = boundServerId
        self.isServer = boundServerId == self.computerId

        if self.isServer then
            self.serverInstanceId = self.instanceId
            self.lastServerSeenAt = now()
            if self.logger then
                self.logger.info(("Announcement server binding restored: self (%s)"):format(
                    tostring(self.serverId)
                ))
            end
            return self
        end

        local discovered, serverInstanceId = self:_discover(boundServerId)
        if discovered ~= boundServerId then
            self:_reboot(("Bound announcement server %s not found; rebooting"):format(
                tostring(boundServerId)
            ))
        end

        self.serverInstanceId = serverInstanceId
        self.lastServerSeenAt = now()
        if self.logger then
            self.logger.info(("Announcement server binding restored: %s"):format(
                tostring(self.serverId)
            ))
        end
        return self
    end

    local existing, serverInstanceId = self:_discover(nil)
    if existing then
        self.serverId = existing
        self.serverInstanceId = serverInstanceId
        self.isServer = existing == self.computerId
        self.lastServerSeenAt = now()
        self:_saveBinding(existing)

        if self.logger then
            self.logger.info(("Announcement server discovered and bound: %s"):format(
                tostring(existing)
            ))
        end
        return self
    end

    local winner, winnerInstanceId = self:_claimServer()
    self.serverId = winner
    self.serverInstanceId = winnerInstanceId
    self.isServer = winner == self.computerId
    self.lastServerSeenAt = now()
    self:_saveBinding(winner)

    if self.logger then
        self.logger.info(("Announcement server elected and bound: %s%s"):format(
            tostring(winner),
            self.isServer and " (self)" or ""
        ))
    end

    return self
end

-- function: Attach the local server instance after bootstrap when this computer owns the role.
function Coordinator:setLocalServer(server)
    self.localServer = server
end

-- function: Supply the latest client guidance state for heartbeat recovery.
function Coordinator:setGuidanceProvider(provider)
    self.guidanceProvider = provider
end

-- function: Return the currently selected server ID.
function Coordinator:getServerId()
    return self.serverId
end

-- function: Return whether this computer owns the fixed server role.
function Coordinator:ownsServer()
    return self.isServer == true
end

-- function: Return this boot instance identifier.
function Coordinator:getInstanceId()
    return self.instanceId
end

-- function: Return this logical speaker group ID.
function Coordinator:getGroupId()
    return self.groupId
end

-- function: Broadcast server presence or send a client heartbeat once.
function Coordinator:_heartbeat()
    local guidanceState = nil
    if type(self.guidanceProvider) == "function" then
        local ok, state = pcall(self.guidanceProvider)
        if ok then
            guidanceState = state
        end
    end

    if self.isServer then
        if self.networkReady then
            Protocol.broadcast(
                self.groupId,
                Protocol.ACTION.SERVER_PRESENCE,
                { serverId = self.computerId },
                self.instanceId
            )
        end

        if self.localServer then
            self.localServer:observeClientPresence(self.computerId, {
                guidanceState = guidanceState,
                instanceId = self.instanceId,
            })
        end
        return
    end

    Protocol.send(
        self.serverId,
        self.groupId,
        Protocol.ACTION.CLIENT_PRESENCE,
        {
            guidanceState = guidanceState,
            instanceId = self.instanceId,
        },
        self.instanceId
    )
end

-- function: Handle coordination messages after startup.
function Coordinator:_monitorNetwork()
    if not self.networkReady then
        while true do
            sleep(60)
        end
    end

    while true do
        local _, senderId, message, protocol = os.pullEvent("rednet_message")
        if protocol == Protocol.REDNET_PROTOCOL and Protocol.matches(message, self.groupId) then
            senderId = tonumber(senderId)

            if self.isServer and message.action == Protocol.ACTION.SERVER_DISCOVER then
                Protocol.send(
                    senderId,
                    self.groupId,
                    Protocol.ACTION.SERVER_PRESENCE,
                    { serverId = self.computerId },
                    self.instanceId
                )
            elseif not self.isServer and senderId == self.serverId then
                local advertisedId, advertisedInstanceId = self:_serverPresence(
                    senderId,
                    message,
                    self.serverId
                )
                if advertisedId then
                    if self.serverInstanceId
                        and advertisedInstanceId
                        and advertisedInstanceId ~= self.serverInstanceId
                    then
                        self:_reboot(("Bound announcement server %s restarted; rebooting"):format(
                            tostring(self.serverId)
                        ))
                    end

                    if self.serverInstanceId == nil then
                        self.serverInstanceId = advertisedInstanceId
                    end
                    self.lastServerSeenAt = now()
                end
            end
        end
    end
end

-- function: Fail-stop a client when its bound server lease expires.
function Coordinator:_watchServer()
    if self.isServer then
        while true do
            sleep(60)
        end
    end

    while true do
        sleep(0.25)
        if now() - (tonumber(self.lastServerSeenAt) or 0) > SERVER_LEASE_MS then
            self:_reboot(("Bound announcement server %s lease expired; rebooting"):format(
                tostring(self.serverId)
            ))
        end
    end
end

-- function: Run heartbeat, discovery responses, and the bound-server watchdog.
function Coordinator:run()
    parallel.waitForAll(
        function()
            while true do
                self:_heartbeat()
                sleep(HEARTBEAT_SECONDS)
            end
        end,
        function()
            self:_monitorNetwork()
        end,
        function()
            self:_watchServer()
        end
    )
end

return Coordinator
