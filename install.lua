local REPOSITORY = "sankaku789/CCtweaked-RailwayAnnouncementSystem"
local DEFAULT_REF = "main"
local INSTALL_ROOT = "/"

local RUNTIME_FILES = {
    "startup.lua",
    "import_audio.lua",

    "src/app.lua",

    "src/adapter/mtr.lua",
    "src/adapter/none.lua",

    "src/audio/guidance_bell.lua",
    "src/audio/player.lua",
    "src/audio/segment.lua",

    "src/core/announcement_queue.lua",
    "src/core/composer.lua",
    "src/core/scheduler.lua",
    "src/core/guidance_scheduler.lua",
    "src/core/track_state.lua",
    "src/core/protocol.lua",

    "src/core/client/assets.lua",
    "src/core/client/coordinator.lua",
    "src/core/client/guidance.lua",
    "src/core/client/playback.lua",
    "src/core/client/scheduler.lua",

    "src/core/server/assets.lua",
    "src/core/server/guidance.lua",
    "src/core/server/playback.lua",

    "src/hardware/railway_input.lua",
    "src/hardware/redstone_input.lua",
    "src/hardware/speakers.lua",

    "src/metadata/cache.lua",
    "src/metadata/provider.lua",

    "src/util/log.lua",
}

local PRESERVED_FILES = {
    "config.lua",
    "announcement_patterns/main.lua",
    "announcement_patterns/composites.lua",
    "announcement_patterns/segments.lua",
    "announcement_patterns/route_options.lua",
}

local REFRESHABLE_PATTERN_FILES = {
    ["announcement_patterns/main.lua"] = true,
    ["announcement_patterns/composites.lua"] = true,
    ["announcement_patterns/segments.lua"] = true,
}

local AUDIO_DIRECTORIES = {
    "audio/melody",
    "audio/guidance",
    "audio/approach",
    "audio/departure",
    "audio/stopped",
    "audio/next_train",
    "audio/track",
    "audio/track/ni",
    "audio/track/wo",
    "audio/class",
    "audio/destination",
    "audio/destination/desu",
    "audio/destination/mairimasu",
    "audio/station",
    "audio/options",
}

local LEGACY_FILES = {
    "app.lua",
    "audio/player.lua",
    "audio/segment.lua",
    "src/hardware/shared_speakers.lua",
    "src/core/shared_guidance.lua",
    "src/core/shared_guidance_policy.lua",
}

local LEGACY_DIRECTORIES = {
    "adapter",
    "announcement",
    "core",
    "hardware",
    "metadata",
    "util",
}

local LEGACY_PATTERN_FILES = {
    {
        source = "data/patterns.lua",
        target = "announcement_patterns/main.lua",
    },
    {
        source = "data/segments.lua",
        target = "announcement_patterns/segments.lua",
    },
    {
        source = "data/route_options.lua",
        target = "announcement_patterns/route_options.lua",
    },
}

local LEGACY_AUDIO_FILES = {
    {
        source = "audio/approach/melody.dfpwm",
        target = "audio/melody/approach.dfpwm",
    },
    {
        source = "audio/arrival/melody.dfpwm",
        target = "audio/melody/arrival.dfpwm",
    },
    {
        source = "audio/departure/melody.dfpwm",
        target = "audio/melody/departure.dfpwm",
    },
}

local function ensureDirectory(path)
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then
        fs.makeDir(parent)
    end
end

local function rawUrl(ref, path)
    return ("https://raw.githubusercontent.com/%s/%s/%s"):format(
        REPOSITORY,
        ref,
        path
    )
end

local function readHttp(url)
    local response, err = http.get(url)
    if not response then
        return nil, err
    end

    local body = response.readAll()
    response.close()
    return body
end

local function download(ref, path)
    local body, err = readHttp(rawUrl(ref, path))
    if not body then
        error(("Failed to download %s: %s"):format(path, tostring(err)))
    end

    local target = fs.combine(INSTALL_ROOT, path)
    ensureDirectory(target)

    local handle = fs.open(target, "w")
    if not handle then
        error("Failed to open for writing: " .. target)
    end
    handle.write(body)
    handle.close()
end

local function downloadIfMissing(ref, path)
    local target = fs.combine(INSTALL_ROOT, path)
    if fs.exists(target) then
        return false
    end

    download(ref, path)
    return true
end

local function migrateFile(source, target)
    source = fs.combine(INSTALL_ROOT, source)
    target = fs.combine(INSTALL_ROOT, target)

    if not fs.exists(source) or fs.exists(target) then
        return false
    end

    ensureDirectory(target)
    fs.copy(source, target)
    print(("Migrated %s -> %s"):format(source, target))
    return true
end

local function cleanupLegacyFiles()
    for _, path in ipairs(LEGACY_FILES) do
        local target = fs.combine(INSTALL_ROOT, path)
        if fs.exists(target) and not fs.isDir(target) then
            fs.delete(target)
        end
    end
end

local function cleanupLegacyDirectories()
    for _, path in ipairs(LEGACY_DIRECTORIES) do
        local target = fs.combine(INSTALL_ROOT, path)
        if fs.exists(target) and fs.isDir(target) then
            fs.delete(target)
        end
    end
end

local function parseArgs(args)
    local ref = DEFAULT_REF
    local refreshPatterns = false

    for _, value in ipairs(args) do
        if value == "--refresh-patterns" then
            refreshPatterns = true
        elseif value:sub(1, 2) == "--" then
            error("Unknown option: " .. value)
        else
            ref = value
        end
    end

    return ref, refreshPatterns
end

local function install(ref, refreshPatterns)
    print(("Installing Railway Announcement System from %s..."):format(ref))

    for _, directory in ipairs(AUDIO_DIRECTORIES) do
        local target = fs.combine(INSTALL_ROOT, directory)
        if not fs.exists(target) then
            fs.makeDir(target)
        end
    end

    for _, migration in ipairs(LEGACY_PATTERN_FILES) do
        migrateFile(migration.source, migration.target)
    end

    for _, migration in ipairs(LEGACY_AUDIO_FILES) do
        migrateFile(migration.source, migration.target)
    end

    for _, path in ipairs(RUNTIME_FILES) do
        download(ref, path)
        print("Updated " .. path)
    end

    for _, path in ipairs(PRESERVED_FILES) do
        if refreshPatterns and REFRESHABLE_PATTERN_FILES[path] then
            download(ref, path)
            print("Refreshed " .. path)
        elseif downloadIfMissing(ref, path) then
            print("Installed " .. path)
        else
            print("Preserved " .. path)
        end
    end

    cleanupLegacyFiles()
    cleanupLegacyDirectories()

    print("Install complete.")
    print("Run 'reboot' to start the system.")
end

local args = { ... }
local ref, refreshPatterns = parseArgs(args)
install(ref, refreshPatterns)
