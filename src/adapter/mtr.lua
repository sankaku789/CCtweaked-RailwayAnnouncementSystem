local MtrAdapter = {}
MtrAdapter.__index = MtrAdapter

-- function: Trim leading and trailing ASCII whitespace.
local function trim(value)
    return value:match("^%s*(.-)%s*$")
end

-- function: Extract the English part of an MTR multilingual name.
local function englishPart(value)
    if type(value) ~= "string" then
        return nil
    end

    local firstPipe = value:find("|", 1, true)
    local selected

    if firstPipe then
        local remaining = value:sub(firstPipe + 1)
        local nextPipe = remaining:find("|", 1, true)

        if nextPipe then
            selected = remaining:sub(1, nextPipe - 1)
        else
            selected = remaining
        end
    else
        selected = value
    end

    selected = trim(selected)
    if selected == "" then
        return nil
    end

    return selected
end

-- function: Check whether a string contains printable ASCII characters only.
local function isPrintableAscii(value)
    for index = 1, #value do
        local byte = value:byte(index)
        if byte < 32 or byte > 126 then
            return false
        end
    end

    return true
end

-- function: Normalize an MTR English name into a case-insensitive audio asset ID.
local function normalizeAssetId(value)
    local english = englishPart(value)
    if not english or not isPrintableAscii(english) then
        return nil
    end

    local normalized = english:lower()
    normalized = normalized:gsub("[^a-z0-9]+", "_")
    normalized = normalized:gsub("^_+", "")
    normalized = normalized:gsub("_+$", "")

    if normalized == "" then
        return nil
    end

    return normalized
end

-- function: Remove trailing slashes from the configured MTR API base URL.
local function normalizeBaseUrl(value)
    if type(value) ~= "string" then
        return nil
    end

    value = trim(value)
    value = value:gsub("/+$", "")

    if value == "" then
        return nil
    end

    return value
end

-- function: Read and close a CC:Tweaked HTTP response handle.
local function readResponse(response)
    local body = response.readAll()
    response.close()
    return body
end

-- function: Preserve MTR route IDs as exact decimal strings before JSON decoding.
local function preserveRouteIds(raw)
    if type(raw) ~= "string" then
        return raw
    end

    return raw:gsub('("routeId"%s*:%s*)(%-?%d+)', function(prefix, routeId)
        return prefix .. '"' .. routeId .. '"'
    end)
end

-- function: Create an MTR metadata adapter.
function MtrAdapter.new(options)
    options = options or {}
    local cfg = options.mtr or options

    return setmetatable({
        baseUrl = normalizeBaseUrl(cfg.baseUrl),
        dimension = tonumber(cfg.dimension) or 0,
        platformIdHex = cfg.platformIdHex,
    }, MtrAdapter)
end

-- function: Request the next arrival for the configured MTR platform.
function MtrAdapter:_requestArrival()
    if not self.baseUrl then
        error("MTR adapter baseUrl is not configured")
    end

    if type(self.platformIdHex) ~= "string" or trim(self.platformIdHex) == "" then
        error("MTR adapter platformIdHex is not configured")
    end

    if type(http) ~= "table" or type(http.post) ~= "function" then
        error("CC:Tweaked HTTP API is unavailable")
    end

    local requestBody = textutils.serializeJSON({
        platformIdsHex = { trim(self.platformIdHex) },
        maxCountPerPlatform = 1,
        maxCountTotal = 1,
    })

    local url = ("%s/mtr/api/map/arrivals?dimension=%d"):format(
        self.baseUrl,
        self.dimension
    )

    local response, requestError, errorResponse = http.post(
        url,
        requestBody,
        {
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json",
        }
    )

    if not response then
        if errorResponse then
            errorResponse.close()
        end
        error("MTR arrivals request failed: " .. tostring(requestError))
    end

    local raw = preserveRouteIds(readResponse(response))
    local payload = textutils.unserializeJSON(raw)

    if type(payload) ~= "table" then
        error("MTR arrivals response is not valid JSON")
    end

    if tonumber(payload.status) ~= 200 then
        error(("MTR arrivals API returned status %s: %s"):format(
            tostring(payload.status),
            tostring(payload.text)
        ))
    end

    local data = payload.data
    if type(data) ~= "table" or type(data.arrivals) ~= "table" then
        return nil
    end

    return data.arrivals[1]
end

-- function: Return normalized train metadata, route ID, and terminating status for the next MTR arrival.
function MtrAdapter:getMetadata(_context)
    local arrival = self:_requestArrival()
    if not arrival then
        return nil
    end

    local classId = normalizeAssetId(arrival.routeNumber)
    local destinationId = normalizeAssetId(arrival.destination)
    local terminating = arrival.isTerminating == true
    local routeId = type(arrival.routeId) == "string" and trim(arrival.routeId) or nil

    if routeId == "" then
        routeId = nil
    end

    if not classId and not destinationId and not terminating and not routeId then
        return nil
    end

    return {
        class = classId,
        destination = destinationId,
        terminating = terminating,
        routeId = routeId,
    }
end

return MtrAdapter
