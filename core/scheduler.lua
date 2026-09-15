local Scheduler = {}
Scheduler.__index = Scheduler

local function now()
    return os.epoch("utc")
end

function Scheduler.new(options)
    return setmetatable(options, Scheduler)
end

function Scheduler:_enqueue(typeName)
    local ttl

    if typeName == "approach" then
        ttl = self.config.queue.approachTtlMs
    elseif typeName == "departure" then
        ttl = self.config.queue.departureTtlMs
    end

    local request = {
        type = typeName,
        track = self.config.trackNumber,
        createdAt = now(),
    }

    if ttl and ttl > 0 then
        request.expiresAt = request.createdAt + ttl
    end

    local ok, reason = self.queue:enqueue(request)
    if not ok and self.logger then
        self.logger.warn(("Announcement skipped (%s): %s"):format(tostring(reason), typeName))
    end
end

function Scheduler:monitorInput()
    while true do
        self.input:waitForPulse()

        local transition = self.trackState:advance()
        if self.logger then
            self.logger.info(("%s -> %s"):format(transition.previous, transition.state))
        end

        if transition.event == "approach" then
            self:_enqueue("approach")
        elseif transition.event == "departure" then
            self:_enqueue("departure")
        end

        if transition.resetTo and self.logger then
            self.logger.info("Track state automatically reset to " .. transition.resetTo)
        end
    end
end

function Scheduler:processQueue()
    while true do
        local request = self.queue:waitPop()
        local metadata = self.metadataProvider:get(request)
        local segments = self.composer:compose(request, metadata)

        if #segments == 0 then
            if self.logger then
                self.logger.warn("Announcement has no playable segments: " .. tostring(request.type))
            end
        else
            if self.logger then
                self.logger.info(("Playing %s announcement (%d segment(s))."):format(
                    tostring(request.type),
                    #segments
                ))
            end

            self.player:playSegments(segments)
        end
    end
end

function Scheduler:run()
    parallel.waitForAll(
        function()
            self:monitorInput()
        end,
        function()
            self:processQueue()
        end
    )
end

return Scheduler
