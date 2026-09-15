local Composer = {}
Composer.__index = Composer

local function add(list, path)
    if path then
        list[#list + 1] = path
    end
end

function Composer.new(config, resolver)
    return setmetatable({
        config = config,
        resolver = resolver,
    }, Composer)
end

function Composer:_composeApproach(request, metadata)
    local cfg = self.config.announcement.approach
    local segments = {}

    if cfg.melodyEnabled then
        add(segments, self.resolver:optional(cfg.melody))
    end

    -- Fixed speech segments are kept even when missing. The player will emit a warning.
    add(segments, cfg.soon)

    add(segments, self.resolver:fromId(cfg.trackDir, request.track))

    local classPath
    local destinationPath

    if metadata then
        classPath = self.resolver:fromId(cfg.classDir, metadata.class)
        destinationPath = self.resolver:fromId(cfg.destinationDir, metadata.destination)
    end

    if classPath and destinationPath then
        -- Only omit the generic "train" segment when both detailed segments can
        -- actually be spoken. Partial metadata falls back to the simple phrase.
        add(segments, classPath)
        add(segments, destinationPath)
    else
        add(segments, cfg.train)
    end

    add(segments, cfg.warning)

    if cfg.arrivalMelodyEnabled then
        add(segments, self.resolver:optional(cfg.arrivalMelody))
    end

    return segments
end

function Composer:_composeDeparture()
    local cfg = self.config.announcement.departure
    local segments = {}

    add(segments, self.resolver:optional(cfg.melody))

    if cfg.doorsClosingEnabled then
        add(segments, self.resolver:optional(cfg.doorsClosing))
    end

    return segments
end

function Composer:compose(request, metadata)
    if request.type == "approach" then
        return self:_composeApproach(request, metadata)
    elseif request.type == "departure" then
        return self:_composeDeparture()
    end

    return {}
end

return Composer
