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

-- function: Select the printable ASCII display name used for exact configuration matching.
local function asciiName(value)
    local selected = englishPart(value)
    if not selected or not isPrintableAscii(selected) then
        return nil
    end

    return selected
end

-- function: Match a configured station or platform name exactly against raw or English MTR text.
local function nameMatches(value, expected)
    if type(value) ~= "string" or type(expected) ~= "string" then
        return false
    end

    expected = trim(expected)
    if expected == "" then
        return false
    end

    if trim(value) == expected then
        return true
    end

    return asciiName(value) == expected
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
        platformIdHex = type(cfg.platformIdHex) == "string" and trim(cfg.platformIdHex) or "",
        stationName = type(cfg.stationName) == "string" and trim(cfg.stationName) or "",
        platformName = type(cfg.platformName) == "string" and trim(cfg.platformName) or "",
        stationIdHex = nil,
    }, MtrAdapter)
end

-- function: Request and decode one TSC system-map HTTP endpoint.
function MtrAdapter:_requestMap(endpoint, requestBody, keepRouteIdsExact)
    if not self.baseUrl then
        error("MTR adapter baseUrl is not configured")
    end

    if type(http) ~= "table" or type(http.get) ~= "function" or type(http.post) ~= "function" then
        error("CC:Tweaked HTTP API is unavailable")
    end

    local url = ("%s/mtr/api/map/%s?dimension=%d"):format(
        self.baseUrl,
        endpoint,
        self.dimension
    )

    local response, requestError, errorResponse
    if requestBody ~= nil then
        response, requestError, errorResponse = http.post(
            url,
            textutils.serializeJSON(requestBody),
            {
                ["Content-Type"] = "application/json",
                ["Accept"] = "application/json",
            }
        )
    else
        response, requestError, errorResponse = http.get(url, {
            ["Accept"] = "application/json",
        })
    end

    if not response then
        if errorResponse then
            errorResponse.close()
        end
        error(("MTR %s request failed: %s"):format(endpoint, tostring(requestError)))
    end

    local raw = readResponse(response)
    if keepRouteIdsExact then
        raw = preserveRouteIds(raw)
    end

    local payload = textutils.unserializeJSON(raw)
    if type(payload) ~= "table" then
        error(("MTR %s response is not valid JSON"):format(endpoint))
    end

    local payloadStatus = tonumber(payload.status)
    if payloadStatus ~= nil and payloadStatus ~= 200 then
        error(("MTR %s API returned status %s: %s"):format(
            endpoint,
            tostring(payload.status),
            tostring(payload.text)
        ))
    end

    return payload.data
end

-- function: Resolve the configured station name to one exact TSC station hex ID.
function MtrAdapter:_resolveStationIdHex()
    if self.stationIdHex then
        return self.stationIdHex
    end

    if self.stationName == "" then
        error("MTR adapter stationName is not configured")
    end

    local data = self:_requestMap("stations-and-routes", nil, false)
    local stations = type(data) == "table" and data.stations or nil
    if type(stations) ~= "table" then
        error("MTR stations-and-routes response does not contain stations")
    end

    local matchedId = nil
    local matchCount = 0

    for _, station in ipairs(stations) do
        if type(station) == "table" and nameMatches(station.name, self.stationName) then
            if type(station.id) == "string" and trim(station.id) ~= "" then
                matchedId = trim(station.id)
                matchCount = matchCount + 1
            end
        end
    end

    if matchCount == 0 then
        error("MTR station was not found by exact name: " .. self.stationName)
    end

    if matchCount > 1 then
        error("MTR station name matched more than one station: " .. self.stationName)
    end

    self.stationIdHex = matchedId
    return matchedId
end

-- function: Build an arrivals request for a direct platform ID or configured station name.
function MtrAdapter:_buildArrivalsRequest()
    if self.platformIdHex ~= "" then
        return {
            platformIdsHex = { self.platformIdHex },
            maxCountPerPlatform = 1,
            maxCountTotal = 1,
        }, true
    end

    if self.platformName == "" then
        error("MTR adapter platformName is not configured")
    end

    return {
        stationIdsHex = { self:_resolveStationIdHex() },
        maxCountPerPlatform = 1,
        maxCountTotal = 0,
    }, false
end

-- function: Request the next arrival for the configured MTR platform.
function MtrAdapter:_requestArrival()
    local requestBody, directPlatform = self:_buildArrivalsRequest()
    local data = self:_requestMap("arrivals", requestBody, true)
    local arrivals = type(data) == "table" and data.arrivals or nil

    if type(arrivals) ~= "table" then
        return nil
    end

    if directPlatform then
        return arrivals[1]
    end

    for _, arrival in ipairs(arrivals) do
        if type(arrival) == "table" and nameMatches(arrival.platformName, self.platformName) then
            return arrival
        end
    end

    return nil
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
