local REPOSITORY = "sankaku789/CCtweaked-RailwayAnnouncementSystem"
local DEFAULT_REF = "main"
local INSTALL_ROOT = "/"

local RUNTIME_FILES = {
    "startup.lua",
    "import_audio.lua",

    "src/app.lua",

    "src/adapter/mtr.lua",
    "src/adapter/none.lua",

    "src/audio/player.lua",
    "src/audio/segment.lua",

    "src/core/announcement_queue.lua",
    "src/core/composer.lua",
    "src/core/scheduler.lua",
    "src/core/track_state.lua",

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
    "announcement_patterns/segments.lua",
    "announcement_patterns/route_options.lua",
}

local REFRESHABLE_PATTERN_FILES = {
    ["announcement_patterns/main.lua"] = true,
    ["announcement_patterns/segments.lua"] = true,
}

local AUDIO_DIRECTORIES = {
    "audio/approach",
    "audio/approach_destination",
    "audio/arrival",
    "audio/departure",
    "audio/passing",
    "audio/stopped",
    "audio/next_train",
    "audio/track",
    "audio/class",
    "audio/destination_sentence",
    "audio/station",
    "audio/options",
}

local LEGACY_FILES = {
    "app.lua",
    "audio/player.lua",
    "audio/segment.lua",
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

-- function: Build a raw GitHub URL for one repository path.
local function rawUrl(path)
    return ("https://raw.githubusercontent.com/%s/%s/%s"):format(REPOSITORY, ref, path)
end

-- function: Resolve one repository path inside the computer root directory.
local function targetPath(path)
    return fs.combine(INSTALL_ROOT, path)
end

-- function: Ensure a directory exists and is usable as a directory.
local function ensureDirectory(path)
    if fs.exists(path) then
        if not fs.isDir(path) then
            error("Expected directory but found file: " .. tostring(path))
        end
        return
    end

    fs.makeDir(path)
end

-- function: Ensure the parent directory for a target file exists.
local function ensureParent(path)
    local parent = fs.getDir(path)
    if parent ~= "" then
        ensureDirectory(parent)
    end
end

-- function: Download one text file from GitHub and optionally preserve an existing local copy.
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

    local temporary = target .. ".download"
    if fs.exists(temporary) then
        fs.delete(temporary)
    end

    local handle = fs.open(temporary, "w")
    if not handle then
        error("Could not open temporary file: " .. temporary)
    end

    handle.write(content)
    handle.close()

    if fs.exists(target) then
        if fs.isDir(target) then
            fs.delete(temporary)
            error("Expected file but found directory: " .. target)
        end
        fs.delete(target)
    end

    fs.move(temporary, target)
    print("Install -> " .. repositoryPath)
end

-- function: Move legacy data files into the announcement_patterns directory without overwriting local files.
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

-- function: Create all directories reserved for DFPWM announcement assets.
local function createAudioDirectories()
    for _, repositoryPath in ipairs(AUDIO_DIRECTORIES) do
        ensureDirectory(targetPath(repositoryPath))
        print("Audio dir -> " .. repositoryPath)
    end
end

-- function: Remove source files left behind by the pre-src directory layout.
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

-- function: Install or update runtime sources while preserving station-specific configuration and audio.
local function install()
    if type(http) ~= "table" or type(http.get) ~= "function" then
        error("CC:Tweaked HTTP API is unavailable")
    end

    print(("Installing CCtweaked Railway Announcement System (%s)..."):format(ref))

    if refreshPatterns then
        print("Default announcement patterns will be refreshed.")
    end

    migrateLegacyPatternFiles()

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
