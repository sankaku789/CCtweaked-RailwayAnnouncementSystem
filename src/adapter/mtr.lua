local MtrAdapter = {}
MtrAdapter.__index = MtrAdapter

-- function: Trim leading and trailing ASCII whitespace.
local function trim(value)
    return value:match("^%s*(.-)%s*$")
end

-- function: Check whether a string contains printable ASCII characters only.
local function isPrintableAscii(value)
    if type(value) ~= "string" or value == "" then
        return false
    end

    for index = 1, #value do
        local byte = value:byte(index)
        if byte < 32 or byte > 126 then
            return false
        end
    end

    return true
end

-- function: Split one MTR multilingual value without assuming any language order.
local function nameParts(value)
    local result = {}
    if type(value) ~= "string" then
        return result
    end

    local startIndex = 1
    while true do
        local separator = value:find("|", startIndex, true)
        local part

        if separator then
            part = value:sub(startIndex, separator - 1)
        else
            part = value:sub(startIndex)
        end

        part = trim(part)
        if part ~= "" then
            result[#result + 1] = part
        end

        if not separator then
            break
        end
        startIndex = separator + 1
    end

    return result
end

-- function: Extract a printable ASCII part of an MTR multilingual name regardless of its position.
local function englishPart(value)
    for _, part in ipairs(nameParts(value)) do
        if isPrintableAscii(part) then
            return part
        end
    end

    return nil
end

-- function: Select the printable ASCII display name used for normalized asset IDs.
local function asciiName(value)
    return englishPart(value)
end

-- function: Match a configured station or platform name against any MTR multilingual component.
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

    for _, part in ipairs(nameParts(value)) do
        if part == expected then
            return true
        end
    end

    return false
end

-- function: Normalize an MTR ASCII name into a case-insensitive audio asset ID.
local function normalizeAssetId(value)
    local english = asciiName(value)
    if not english then
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

-- function: Normalize configured fallback train class IDs.
local function normalizeTrainClassIds(values)
    local result = {}

    if type(values) ~= "table" then
        return result
    end

    for _, value in ipairs(values) do
        if type(value) == "string" then
            local normalized = value:lower()
            normalized = normalized:gsub("[^a-z0-9]+", "_")
            normalized = normalized:gsub("^_+", "")
            normalized = normalized:gsub("_+$", "")

            if normalized ~= "" then
                result[#result + 1] = normalized
            end
        end
    end

    return result
end

-- function: Resolve a configured fallback train class by matching any ASCII route-number component.
local function classIdFromRouteNumber(value, trainClassIds)
    local selected = asciiName(value)
    if not selected then
        return nil
    end

    local normalized = selected:lower()
    normalized = normalized:gsub("[^a-z0-9]+", "_")
    normalized = normalized:gsub("^_+", "")
    normalized = normalized:gsub("_+$", "")

    if normalized == "" then
        return nil
    end

    local searchable = "_" .. normalized .. "_"
    for _, classId in ipairs(trainClassIds or {}) do
        if searchable:find("_" .. classId .. "_", 1, true) then
            return classId
        end
    end

    return nil
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

-- function: Read the MTR platform name from the announcement track context.
local function platformNameFromContext(context)
    local track = type(context) == "table" and context.track or nil
    if type(track) ~= "string" and type(track) ~= "number" then
        error("MTR adapter track context is not configured")
    end

    local platformName = trim(tostring(track))
    if platformName == "" then
        error("MTR adapter track context is not configured")
    end

    return platformName
end

-- function: Count serialized MTR car details from one arrival response.
local function carCountFromArrival(arrival)
    local cars = type(arrival) == "table" and arrival.cars or nil
    if type(cars) ~= "table" then
        return nil
    end

    local count = #cars
    if count <= 0 then
        return nil
    end

    return count
end

-- function: Return the dwell interval in milliseconds from one MTR arrival response.
local function dwellTimeFromArrival(arrival)
    local arrivalTime = type(arrival) == "table" and tonumber(arrival.arrival) or nil
    local departureTime = type(arrival) == "table" and tonumber(arrival.departure) or nil

    if not arrivalTime or not departureTime or departureTime < arrivalTime then
        error("MTR arrival response does not contain a valid dwell interval")
    end

    return departureTime - arrivalTime
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

    return raw:gsub('(\"routeId\"%s*:%s*)(%-?%d+)', function(prefix, routeId)
        return prefix .. '\"' .. routeId .. '\"'
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
        trainClassIds = normalizeTrainClassIds(cfg.trainClasses),
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

-- function: Inspect distinct dwell timings for the configured station and platform name.
function MtrAdapter:getPlatformDwellTiming(context)
    if self.platformIdHex ~= "" then
        local arrival = self:_requestArrival(context)
        if not arrival then
            error("MTR platform dwell time is unavailable for the direct platform ID")
        end

        return {
            dynamic = false,
            candidateCount = 1,
            dwellTimeMs = dwellTimeFromArrival(arrival),
        }
    end

    local stationIdHex = self:_resolveStationIdHex()
    local platformName = platformNameFromContext(context)
    local data = self:_requestMap("stations-and-routes", nil, false)
    local routes = type(data) == "table" and data.routes or nil
    if type(routes) ~= "table" then
        error("MTR stations-and-routes response does not contain routes")
    end

    local dwellCandidates = {}
    local candidateCount = 0
    local singleDwellTime = nil

    for _, route in ipairs(routes) do
        local stations = type(route) == "table" and route.stations or nil
        if type(stations) == "table" then
            for _, station in ipairs(stations) do
                local stationId = type(station) == "table" and station.id or nil
                local candidate = type(station) == "table" and tonumber(station.dwellTime) or nil

                if type(stationId) == "string"
                    and trim(stationId) == stationIdHex
                    and nameMatches(station.name, platformName)
                    and candidate
                    and candidate >= 0
                    and dwellCandidates[candidate] == nil
                then
                    dwellCandidates[candidate] = true
                    candidateCount = candidateCount + 1
                    if candidateCount == 1 then
                        singleDwellTime = candidate
                    end
                end
            end
        end
    end

    if candidateCount == 0 then
        error(("MTR platform dwell time was not found: station=%s platform=%s"):format(
            self.stationName,
            platformName
        ))
    end

    if candidateCount == 1 then
        return {
            dynamic = false,
            candidateCount = 1,
            dwellTimeMs = singleDwellTime,
        }
    end

    return {
        dynamic = true,
        candidateCount = candidateCount,
        dwellTimeMs = nil,
    }
end

-- function: Return the dwell time of the train currently selected for this platform.
function MtrAdapter:getCurrentPlatformDwellTimeMs(context)
    local arrival = self:_requestArrival(context)
    if not arrival then
        error("MTR current platform dwell time is unavailable")
    end

    return dwellTimeFromArrival(arrival)
end

-- function: Return the dwell time in milliseconds for the configured platform.
function MtrAdapter:getPlatformDwellTimeMs(context)
    local timing = self:getPlatformDwellTiming(context)
    if timing.dynamic then
        return self:getCurrentPlatformDwellTimeMs(context)
    end

    return timing.dwellTimeMs
end

-- function: Build an arrivals request for a direct platform ID or the announcement track context.
function MtrAdapter:_buildArrivalsRequest(context)
    if self.platformIdHex ~= "" then
        return {
            platformIdsHex = { self.platformIdHex },
            maxCountPerPlatform = 1,
            maxCountTotal = 1,
        }, true, nil
    end

    local platformName = platformNameFromContext(context)
    return {
        stationIdsHex = { self:_resolveStationIdHex() },
        maxCountPerPlatform = 1,
        maxCountTotal = 0,
    }, false, platformName
end

-- function: Request the next arrival for the platform identified by the announcement track context.
function MtrAdapter:_requestArrival(context)
    local requestBody, directPlatform, platformName = self:_buildArrivalsRequest(context)
    local data = self:_requestMap("arrivals", requestBody, true)
    local arrivals = type(data) == "table" and data.arrivals or nil

    if type(arrivals) ~= "table" then
        return nil
    end

    if directPlatform then
        return arrivals[1]
    end

    for _, arrival in ipairs(arrivals) do
        if type(arrival) == "table" and nameMatches(arrival.platformName, platformName) then
            return arrival
        end
    end

    return nil
end

-- function: Return normalized train metadata, car count, route ID, and terminating status for the next MTR arrival.
function MtrAdapter:getMetadata(context)
    local arrival = self:_requestArrival(context)
    if not arrival then
        return nil
    end

    -- Train class comes from the printable ASCII component of routeNumber,
    -- independent of whether Japanese or English is stored first.
    local classId = normalizeAssetId(arrival.routeNumber)
    if not classId then
        classId = classIdFromRouteNumber(arrival.routeNumber, self.trainClassIds)
    end

    local destinationId = normalizeAssetId(arrival.destination)
    local carCount = carCountFromArrival(arrival)
    local terminating = arrival.isTerminating == true
    local routeId = type(arrival.routeId) == "string" and trim(arrival.routeId) or nil

    if routeId == "" then
        routeId = nil
    end

    if not classId and not destinationId and not carCount and not terminating and not routeId then
        return nil
    end

    return {
        class = classId,
        destination = destinationId,
        carCount = carCount,
        terminating = terminating,
        routeId = routeId,
    }
end

return MtrAdapter
