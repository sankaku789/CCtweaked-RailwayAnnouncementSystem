local REPOSITORY = "sankaku789/CCtweaked-RailwayAnnouncementSystem"
local DEFAULT_REF = "main"
local INSTALL_ROOT = "/"

local PROGRAM_FILES = {
    "startup.lua",
    "app.lua",
    "config.lua",

    "adapter/mtr.lua",
    "adapter/none.lua",

    "announcement/patterns.lua",
    "announcement/segments.lua",

    "audio/player.lua",
    "audio/segment.lua",

    "core/announcement_queue.lua",
    "core/composer.lua",
    "core/scheduler.lua",
    "core/track_state.lua",

    "hardware/railway_input.lua",
    "hardware/redstone_input.lua",
    "hardware/speakers.lua",

    "metadata/cache.lua",
    "metadata/provider.lua",

    "util/log.lua",
}

local AUDIO_DIRECTORIES = {
    "audio/approach",
    "audio/arrival",
    "audio/departure",
    "audio/passing",
    "audio/stopped",
    "audio/next_train",
    "audio/track",
    "audio/class",
    "audio/destination",
}

local arguments = { ... }
local ref = arguments[1] or DEFAULT_REF

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

-- function: Download one text file from GitHub and replace the local copy atomically.
local function downloadFile(repositoryPath)
    local target = targetPath(repositoryPath)

    if repositoryPath == "config.lua" and fs.exists(target) then
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

-- function: Create all directories reserved for DFPWM announcement assets.
local function createAudioDirectories()
    for _, repositoryPath in ipairs(AUDIO_DIRECTORIES) do
        ensureDirectory(targetPath(repositoryPath))
        print("Audio dir -> " .. repositoryPath)
    end
end

-- function: Install or update all runtime source files while preserving local configuration and audio.
local function install()
    if type(http) ~= "table" or type(http.get) ~= "function" then
        error("CC:Tweaked HTTP API is unavailable")
    end

    print(("Installing CCtweaked Railway Announcement System (%s)..."):format(ref))

    for _, repositoryPath in ipairs(PROGRAM_FILES) do
        downloadFile(repositoryPath)
    end

    createAudioDirectories()

    print("Installation complete.")
    print("config.lua and existing audio files were preserved.")
end

install()
