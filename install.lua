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
    {
        source = "audio/approach/passing.dfpwm",
        target = "audio/approach/passing_train.dfpwm",
    },
}

local LEGACY_AUDIO_DIRECTORIES = {
    "audio/arrival",
    "audio/passing",
}

local arguments = { ... }
local ref = DEFAULT_REF
local refConfigured = false
local refreshPatterns = false

for _, argument in ipairs(arguments) do
    if argument == "--refresh-patterns" then
        refreshPatterns = true
    elseif argument:sub(1, 2) == "--" then
        error("Unknown installer option: " .. argument)
    elseif not refConfigured then
        ref = argument
        refConfigured = true
    else
        error("Unexpected installer argument: " .. argument)
    end
end

local function rawUrl(path)
    return ("https://raw.githubusercontent.com/%s/%s/%s"):format(REPOSITORY, ref, path)
end

local function targetPath(path)
    return fs.combine(INSTALL_ROOT, path)
end

local function ensureDirectory(path)
    if fs.exists(path) then
        if not fs.isDir(path) then
            error("Expected directory but found file: " .. tostring(path))
        end
        return
    end

    fs.makeDir(path)
end

local function ensureParent(path)
    local parent = fs.getDir(path)
    if parent ~= "" then
        ensureDirectory(parent)
    end
end

local function writeContent(path, content)
    local handle = fs.open(path, "w")
    if not handle then
        error("Could not open file for writing: " .. path)
    end

    handle.write(content)
    handle.close()
end

local function downloadFile(repositoryPath, preserveExisting)
    local target = targetPath(repositoryPath)

    if preserveExisting and fs.exists(target) then
        print("Keep -> " .. repositoryPath)
        return
    end

    ensureParent(target)

    local response, requestError = http.get(rawUrl(repositoryPath), {
        ["User-Agent"] = "CCtweaked-RailwayAnnouncementSystem-Installer",
    })

    if not response then
        error(("Download failed: %s (%s)"):format(repositoryPath, tostring(requestError)))
    end

    local content = response.readAll()
    response.close()

    if fs.exists(target) and fs.isDir(target) then
        error("Expected file but found directory: " .. target)
    end

    local temporary = target .. ".download"
    if fs.exists(temporary) then
        fs.delete(temporary)
    end

    local existingSize = 0
    if fs.exists(target) then
        existingSize = fs.getSize(target)
    end

    local spacePath = fs.getDir(target)
    if spacePath == "" then
        spacePath = INSTALL_ROOT
    end

    local freeSpace = fs.getFreeSpace(spacePath)
    local contentSize = #content

    -- Prefer atomic replacement when enough free space exists for a second copy.
    if type(freeSpace) ~= "number" or freeSpace >= contentSize then
        writeContent(temporary, content)

        if fs.exists(target) then
            fs.delete(target)
        end

        fs.move(temporary, target)
        print("Install -> " .. repositoryPath)
        return
    end

    -- The download is already complete in memory, so an update can safely reuse
    -- the space occupied by the old file instead of requiring two on-disk copies.
    if freeSpace + existingSize < contentSize then
        error(("Out of space installing %s: need %d bytes, available %d bytes after replacement"):format(
            repositoryPath,
            contentSize,
            freeSpace + existingSize
        ))
    end

    if fs.exists(target) then
        fs.delete(target)
    end

    writeContent(target, content)
    print("Install -> " .. repositoryPath .. " (in-place)")
end

local function migrateLegacyPatternFiles()
    for _, mapping in ipairs(LEGACY_PATTERN_FILES) do
        local source = targetPath(mapping.source)
        local target = targetPath(mapping.target)

        if fs.exists(source) and not fs.isDir(source) then
            if fs.exists(target) then
                print("Keep legacy -> " .. mapping.source)
            else
                ensureParent(target)
                fs.move(source, target)
                print(("Migrate -> %s -> %s"):format(mapping.source, mapping.target))
            end
        end
    end

    local legacyDirectory = targetPath("data")
    if fs.exists(legacyDirectory) and fs.isDir(legacyDirectory) then
        local remaining = fs.list(legacyDirectory)
        if #remaining == 0 then
            fs.delete(legacyDirectory)
            print("Remove legacy -> data/")
        end
    end
end

local function migrateLegacyAudioFiles()
    for _, mapping in ipairs(LEGACY_AUDIO_FILES) do
        local source = targetPath(mapping.source)
        local target = targetPath(mapping.target)

        if fs.exists(source) and not fs.isDir(source) then
            if fs.exists(target) then
                print("Keep legacy audio -> " .. mapping.source)
            else
                ensureParent(target)
                fs.move(source, target)
                print(("Migrate audio -> %s -> %s"):format(mapping.source, mapping.target))
            end
        end
    end

    for _, repositoryPath in ipairs(LEGACY_AUDIO_DIRECTORIES) do
        local path = targetPath(repositoryPath)
        if fs.exists(path) and fs.isDir(path) and #fs.list(path) == 0 then
            fs.delete(path)
            print("Remove legacy audio dir -> " .. repositoryPath .. "/")
        end
    end
end

local function migrateDfpwmDirectory(sourceRepositoryPath, targetRepositoryPath, label)
    local sourceDirectory = targetPath(sourceRepositoryPath)
    if not fs.exists(sourceDirectory) or not fs.isDir(sourceDirectory) then
        return
    end

    local targetDirectory = targetPath(targetRepositoryPath)

    for _, name in ipairs(fs.list(sourceDirectory)) do
        local source = fs.combine(sourceDirectory, name)

        if not fs.isDir(source) and name:sub(-6) == ".dfpwm" then
            local target = fs.combine(targetDirectory, name)

            if fs.exists(target) then
                print(("Keep legacy %s -> %s/%s"):format(label, sourceRepositoryPath, name))
            else
                ensureDirectory(targetDirectory)
                fs.move(source, target)
                print(("Migrate %s -> %s/%s -> %s/%s"):format(
                    label,
                    sourceRepositoryPath,
                    name,
                    targetRepositoryPath,
                    name
                ))
            end
        end
    end
end

local function migrateLegacyDestinationFiles()
    migrateDfpwmDirectory("audio/approach/destination", "audio/destination/mairimasu", "destination")
    migrateDfpwmDirectory("audio/approach_destination", "audio/destination/mairimasu", "destination")
    migrateDfpwmDirectory("audio/destination_sentence", "audio/destination/desu", "destination")
    migrateDfpwmDirectory("audio/destination", "audio/destination/desu", "destination")

    for _, repositoryPath in ipairs({
        "audio/approach/destination",
        "audio/approach_destination",
        "audio/destination_sentence",
    }) do
        local path = targetPath(repositoryPath)
        if fs.exists(path) and fs.isDir(path) and #fs.list(path) == 0 then
            fs.delete(path)
            print("Remove legacy destination dir -> " .. repositoryPath .. "/")
        end
    end
end

local function migrateLegacyTrackFiles()
    migrateDfpwmDirectory("audio/track/approach", "audio/track/ni", "track")
    migrateDfpwmDirectory("audio/track/passing", "audio/track/wo", "track")
    migrateDfpwmDirectory("audio/track", "audio/track/ni", "track")

    for _, repositoryPath in ipairs({ "audio/track/approach", "audio/track/passing" }) do
        local path = targetPath(repositoryPath)
        if fs.exists(path) and fs.isDir(path) and #fs.list(path) == 0 then
            fs.delete(path)
            print("Remove legacy track dir -> " .. repositoryPath .. "/")
        end
    end
end

local function createAudioDirectories()
    for _, repositoryPath in ipairs(AUDIO_DIRECTORIES) do
        ensureDirectory(targetPath(repositoryPath))
        print("Audio dir -> " .. repositoryPath)
    end
end

local function removeLegacyLayout()
    for _, repositoryPath in ipairs(LEGACY_FILES) do
        local path = targetPath(repositoryPath)
        if fs.exists(path) and not fs.isDir(path) then
            fs.delete(path)
            print("Remove legacy -> " .. repositoryPath)
        end
    end

    for _, repositoryPath in ipairs(LEGACY_DIRECTORIES) do
        local path = targetPath(repositoryPath)
        if fs.exists(path) and fs.isDir(path) then
            fs.delete(path)
            print("Remove legacy -> " .. repositoryPath .. "/")
        end
    end
end

local function install()
    if type(http) ~= "table" or type(http.get) ~= "function" then
        error("CC:Tweaked HTTP API is unavailable")
    end

    print(("Installing CCtweaked Railway Announcement System (%s)..."):format(ref))

    if refreshPatterns then
        print("Default announcement patterns will be refreshed.")
    end

    migrateLegacyPatternFiles()
    migrateLegacyAudioFiles()
    migrateLegacyDestinationFiles()
    migrateLegacyTrackFiles()

    for _, repositoryPath in ipairs(RUNTIME_FILES) do
        downloadFile(repositoryPath, false)
    end

    for _, repositoryPath in ipairs(PRESERVED_FILES) do
        local preserveExisting = not (refreshPatterns and REFRESHABLE_PATTERN_FILES[repositoryPath])
        downloadFile(repositoryPath, preserveExisting)
    end

    createAudioDirectories()
    removeLegacyLayout()

    print("Installation complete.")
    if refreshPatterns then
        print("config.lua, route options, and existing audio files were preserved.")
    else
        print("config.lua, announcement patterns, and existing audio files were preserved.")
    end
end

install()
