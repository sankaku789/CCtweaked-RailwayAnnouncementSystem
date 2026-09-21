local BLOCK_SIZE = 512
local COPY_CHUNK_SIZE = 16 * 1024
local AUDIO_ROOT = "/audio"
local DEPARTURE_MELODY_PATH = "/audio/melody/departure.dfpwm"

-- function: Remove trailing NUL bytes and spaces from one TAR header field.
local function cleanField(value)
    local zero = value:find("\0", 1, true)
    if zero then
        value = value:sub(1, zero - 1)
    end

    value = value:gsub("%s+$", "")
    return value
end

-- function: Parse an octal number from one TAR header field.
local function parseOctal(value, fieldName)
    value = cleanField(value):gsub("^%s+", "")
    if value == "" then
        return 0
    end

    local parsed = tonumber(value, 8)
    if not parsed then
        error("Invalid TAR " .. tostring(fieldName) .. " field: " .. tostring(value), 0)
    end

    return parsed
end

-- function: Read exactly the requested number of bytes from a transferred file.
local function readExact(handle, count)
    if count <= 0 then
        return ""
    end

    local chunks = {}
    local total = 0

    while total < count do
        local chunk = handle.read(count - total)
        if not chunk or #chunk == 0 then
            if total == 0 then
                return nil
            end

            error(("Unexpected end of TAR archive (%d/%d bytes read)"):format(total, count), 0)
        end

        chunks[#chunks + 1] = chunk
        total = total + #chunk
    end

    return table.concat(chunks)
end

-- function: Discard a fixed number of bytes from a transferred file without buffering the whole range.
local function skipBytes(handle, count)
    local remaining = count

    while remaining > 0 do
        local chunkSize = math.min(COPY_CHUNK_SIZE, remaining)
        local chunk = readExact(handle, chunkSize)
        if not chunk then
            error("Unexpected end of TAR archive while skipping data", 0)
        end
        remaining = remaining - #chunk
    end
end

-- function: Check whether one TAR block consists entirely of zero bytes.
local function isZeroBlock(block)
    for index = 1, #block do
        if block:byte(index) ~= 0 then
            return false
        end
    end

    return true
end

-- function: Validate the checksum stored in one TAR header block.
local function validateChecksum(header)
    local expected = parseOctal(header:sub(149, 156), "checksum")
    local actual = 0

    for index = 1, BLOCK_SIZE do
        if index >= 149 and index <= 156 then
            actual = actual + 32
        else
            actual = actual + header:byte(index)
        end
    end

    if actual ~= expected then
        error(("Invalid TAR header checksum (expected %d, got %d)"):format(expected, actual), 0)
    end
end

-- function: Parse the path, size, type, and format marker from one TAR header block.
local function parseHeader(header)
    validateChecksum(header)

    local name = cleanField(header:sub(1, 100))
    local prefix = cleanField(header:sub(346, 500))
    if prefix ~= "" then
        name = prefix .. "/" .. name
    end

    local magic = cleanField(header:sub(258, 263))
    magic = magic:gsub("%s+$", "")
    if magic ~= "" and magic ~= "ustar" then
        error("Unsupported TAR format: expected ustar-compatible archive", 0)
    end

    return {
        name = name,
        size = parseOctal(header:sub(125, 136), "size"),
        typeFlag = header:sub(157, 157),
    }
end

-- function: Normalize and validate an archive path before placing it under the audio directory.
local function normalizeEntryPath(path)
    if type(path) ~= "string" then
        error("Invalid TAR entry path", 0)
    end

    if path:find("\\", 1, true) then
        error("TAR entry paths must use forward slashes: " .. path, 0)
    end

    while path:sub(1, 2) == "./" do
        path = path:sub(3)
    end

    path = path:gsub("/+$", "")
    if path == "" then
        return nil
    end

    if path:sub(1, 1) == "/" or path:match("^%a:") then
        error("Absolute TAR paths are not allowed: " .. path, 0)
    end

    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == "." or part == ".." then
            error("Unsafe TAR path component in: " .. path, 0)
        end
        parts[#parts + 1] = part
    end

    if #parts == 0 then
        return nil
    end

    if parts[1] == "audio" then
        error("TAR root must match the contents of audio/, not contain an outer audio/ directory", 0)
    end

    return table.concat(parts, "/")
end

-- function: Ensure a directory and all of its parents exist.
local function ensureDirectory(path)
    if path == "" or path == "/" then
        return
    end

    if fs.exists(path) then
        if not fs.isDir(path) then
            error("Expected directory but found file: " .. tostring(path), 0)
        end
        return
    end

    local parent = fs.getDir(path)
    if parent ~= "" and parent ~= path then
        ensureDirectory(parent)
    end

    fs.makeDir(path)
end

-- function: Ensure the parent directory for one imported audio file exists.
local function ensureParent(path)
    local parent = fs.getDir(path)
    if parent ~= "" then
        ensureDirectory(parent)
    end
end

-- function: Stream one TAR file payload into an open destination handle.
local function copyEntryData(input, output, size)
    local remaining = size

    while remaining > 0 do
        local chunkSize = math.min(COPY_CHUNK_SIZE, remaining)
        local chunk = readExact(input, chunkSize)
        if not chunk then
            error("Unexpected end of TAR archive while reading audio data", 0)
        end

        output.write(chunk)
        remaining = remaining - #chunk
    end
end

-- function: Stream a transferred file into an open destination handle until end of file.
local function copyTransferredData(input, output)
    local total = 0

    while true do
        local chunk = input.read(COPY_CHUNK_SIZE)
        if not chunk or #chunk == 0 then
            return total
        end

        output.write(chunk)
        total = total + #chunk
    end
end

-- function: Copy one regular TAR entry into a temporary file and atomically replace the destination.
local function writeEntryFile(input, target, size)
    ensureParent(target)

    local temporary = target .. ".import"
    if fs.exists(temporary) then
        fs.delete(temporary)
    end

    local output = fs.open(temporary, "wb")
    if not output then
        error("Could not open temporary audio file: " .. temporary, 0)
    end

    local ok, copyError = pcall(copyEntryData, input, output, size)
    output.close()

    if not ok then
        if fs.exists(temporary) then
            fs.delete(temporary)
        end
        error(copyError, 0)
    end

    if fs.exists(target) then
        if fs.isDir(target) then
            fs.delete(temporary)
            error("Expected audio file but found directory: " .. target, 0)
        end
        fs.delete(target)
    end

    fs.move(temporary, target)
end

-- function: Copy one transferred file into a temporary file and atomically replace the destination.
local function writeTransferredFile(input, target)
    ensureParent(target)

    local temporary = target .. ".import"
    if fs.exists(temporary) then
        fs.delete(temporary)
    end

    local output = fs.open(temporary, "wb")
    if not output then
        error("Could not open temporary audio file: " .. temporary, 0)
    end

    local ok, result = pcall(copyTransferredData, input, output)
    output.close()

    if not ok then
        if fs.exists(temporary) then
            fs.delete(temporary)
        end
        error(result, 0)
    end

    if fs.exists(target) then
        if fs.isDir(target) then
            fs.delete(temporary)
            error("Expected audio file but found directory: " .. target, 0)
        end
        fs.delete(target)
    end

    fs.move(temporary, target)
    return result
end

-- function: Extract supported DFPWM files from a TAR stream into the local audio directory.
local function extractTar(handle)
    ensureDirectory(AUDIO_ROOT)

    local importedFiles = 0
    local importedBytes = 0
    local skippedEntries = 0

    while true do
        local header = readExact(handle, BLOCK_SIZE)
        if not header then
            break
        end

        if isZeroBlock(header) then
            break
        end

        local entry = parseHeader(header)
        local typeFlag = entry.typeFlag
        local relativePath

        if typeFlag == "0" or typeFlag == "\0" or typeFlag == "" or typeFlag == "5" then
            relativePath = normalizeEntryPath(entry.name)
        end

        if typeFlag == "5" then
            if relativePath then
                ensureDirectory(fs.combine(AUDIO_ROOT, relativePath))
            end
            skipBytes(handle, entry.size)
        elseif typeFlag == "0" or typeFlag == "\0" or typeFlag == "" then
            if relativePath and relativePath:lower():sub(-6) == ".dfpwm" then
                local target = fs.combine(AUDIO_ROOT, relativePath)
                writeEntryFile(handle, target, entry.size)
                importedFiles = importedFiles + 1
                importedBytes = importedBytes + entry.size
                print("Audio -> " .. relativePath)
            else
                skipBytes(handle, entry.size)
                skippedEntries = skippedEntries + 1
                if relativePath then
                    print("Skip non-DFPWM -> " .. relativePath)
                end
            end
        else
            skipBytes(handle, entry.size)
            skippedEntries = skippedEntries + 1
            print(("Skip TAR entry type %q -> %s"):format(typeFlag, entry.name))
        end

        local padding = (BLOCK_SIZE - (entry.size % BLOCK_SIZE)) % BLOCK_SIZE
        skipBytes(handle, padding)
    end

    return importedFiles, importedBytes, skippedEntries
end

-- function: Import one transferred DFPWM file as the default departure melody.
local function importDepartureMelody(handle)
    local importedBytes = writeTransferredFile(handle, DEPARTURE_MELODY_PATH)
    return importedBytes
end

-- function: Close every transferred file except the first supported import file.
local function selectImportFile(transferredFiles)
    local selected
    local selectedKind

    for _, file in ipairs(transferredFiles.getFiles()) do
        local name = tostring(file.getName())
        local lowerName = name:lower()

        if not selected and lowerName:sub(-4) == ".tar" then
            selected = file
            selectedKind = "tar"
            print("Importing TAR -> " .. name)
        elseif not selected and lowerName:sub(-6) == ".dfpwm" then
            selected = file
            selectedKind = "departure_melody"
            print("Importing departure melody -> " .. name)
        else
            print("Ignore transfer -> " .. name)
            file.close()
        end
    end

    return selected, selectedKind
end

-- function: Wait until the user drag-and-drops a supported audio import file onto this computer.
local function waitForImportFile()
    while true do
        print("Drag and drop audio_pack.tar or a departure melody .dfpwm onto this computer.")
        local _, transferredFiles = os.pullEvent("file_transfer")
        local file, kind = selectImportFile(transferredFiles)

        if file then
            return file, kind
        end

        printError("No .tar or .dfpwm file was included in the transfer.")
    end
end

-- function: Import one drag-and-dropped audio file into the local audio directory.
local function main()
    print("Railway Announcement Audio Importer")
    print("TAR root must match the contents of /audio (approach/, class/, destination/, ...).")
    print("A single .dfpwm file is installed as /audio/melody/departure.dfpwm.")

    local file, kind = waitForImportFile()

    if kind == "departure_melody" then
        local ok, importedBytes = pcall(importDepartureMelody, file)
        file.close()

        if not ok then
            printError("Departure melody import failed: " .. tostring(importedBytes))
            return
        end

        print(("Departure melody installed: %s (%d byte(s))."):format(
            DEPARTURE_MELODY_PATH,
            importedBytes
        ))
        return
    end

    local ok, importedFiles, importedBytes, skippedEntries = pcall(extractTar, file)
    file.close()

    if not ok then
        printError("Audio import failed: " .. tostring(importedFiles))
        return
    end

    print(("Import complete: %d file(s), %d byte(s), %d skipped entry(s)."):format(
        importedFiles,
        importedBytes,
        skippedEntries
    ))
end

main()
