local Protocol = require("core.protocol")

local GuidanceClient = {}
GuidanceClient.__index = GuidanceClient

-- function: Create a client-side guidance state publisher.
function GuidanceClient.new(options)
    return setmetatable({
        groupId = options.groupId,
        serverId = options.serverId,
        instanceId = options.instanceId,
        localServer = options.localServer,
        logger = options.logger,
        revision = 0,
        blocked = false,
        resumeAt = nil,
        initialized = false,
    }, GuidanceClient)
end

-- function: Return the current state for heartbeat recovery.
function GuidanceClient:snapshot()
    return {
        revision = self.revision,
        blocked = self.blocked == true,
        resumeAt = tonumber(self.resumeAt),
    }
end

-- function: Publish the current state to the bound server.
function GuidanceClient:_publish()
    local state = self:snapshot()

    if self.localServer then
        self.localServer:observeGuidanceState(os.getComputerID(), state, self.instanceId)
        return true
    end

    return Protocol.send(
        self.serverId,
        self.groupId,
        Protocol.ACTION.GUIDANCE_STATE,
        state,
        self.instanceId
    )
end

-- function: Convert local railway policy into the server-facing guidance state.
function GuidanceClient:updateFromTrack(state, resumeAt, hold)
    -- Guidance is allowed only in the normal IDLE state. APPROACH and PLATFORM
    -- both suppress the bell, and any future non-IDLE state is safe by default.
    local blocked = state ~= "IDLE" or hold == true
    resumeAt = tonumber(resumeAt)

    if blocked then
        resumeAt = nil
    elseif resumeAt and resumeAt <= os.epoch("utc") then
        resumeAt = nil
    end

    if self.initialized
        and self.blocked == blocked
        and tonumber(self.resumeAt) == resumeAt
    then
        return false
    end

    self.initialized = true
    self.revision = self.revision + 1
    self.blocked = blocked
    self.resumeAt = resumeAt
    self:_publish()
    return true
end

return GuidanceClient
