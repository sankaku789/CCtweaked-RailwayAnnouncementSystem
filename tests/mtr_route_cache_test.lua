package.path = "./src/?.lua;" .. package.path

local nowMs = 0
os.epoch = function()
    return nowMs
end

local requests = {}

http = {
    get = function(url)
        requests[#requests + 1] = url
        return {
            readAll = function()
                return "{}"
            end,
            close = function() end,
        }
    end,
    post = function()
        error("unexpected MTR POST request")
    end,
}

local responsePayload = nil
textutils = textutils or {}
textutils.unserializeJSON = function()
    return responsePayload
end

local MtrAdapter = require("adapter.mtr")

local function routeMapPayload(routes)
    return { status = 200, data = { routes = routes } }
end

local function stationRequestCount()
    local count = 0
    for _, url in ipairs(requests) do
        if url:find("/mtr/api/map/stations-and-routes", 1, true) then
            count = count + 1
        end
    end
    return count
end

local hiddenRouteId = "5974863621745288138"
local visibleRouteId = "-5902564984660562616"

-- Cached within the TTL: repeated lookups and getMetadata share one request.
local adapter = MtrAdapter.new({
    baseUrl = "http://mtr.test",
    routeMapTtlMs = 30000,
})
responsePayload = routeMapPayload({
    { id = "52EAFACECB8823CA", hidden = true },
    { id = "AE15E06B69A5ED48", hidden = false },
})

assert(adapter:_isHiddenRoute(hiddenRouteId) == true)
assert(stationRequestCount() == 1)
assert(adapter:_isHiddenRoute(visibleRouteId) == false)
assert(stationRequestCount() == 1)
assert(adapter:_isHiddenRoute("42") == false)
assert(stationRequestCount() == 1)

local arrival = { routeId = hiddenRouteId, isTerminating = false }
function adapter:_requestArrival()
    return arrival
end

local metadata = adapter:getMetadata({})
assert(metadata.hidden == true)
assert(adapter:getMetadata({}).hidden == true)
assert(stationRequestCount() == 1)

-- After the TTL the map is fetched again and reflects changed hidden status.
nowMs = 30000
responsePayload = routeMapPayload({
    { id = "52EAFACECB8823CA", hidden = false },
})
assert(adapter:_isHiddenRoute(hiddenRouteId) == false)
assert(stationRequestCount() == 2)
assert(adapter:_isHiddenRoute(hiddenRouteId) == false)
assert(stationRequestCount() == 2)

-- A response without routes is an error and is not cached.
nowMs = 60000
requests = {}
responsePayload = { status = 200, data = { stations = {} } }
local ok, requestError = pcall(adapter._isHiddenRoute, adapter, hiddenRouteId)
assert(ok == false)
assert(tostring(requestError):find("does not contain routes", 1, true) ~= nil)
assert(stationRequestCount() == 1)

responsePayload = routeMapPayload({
    { id = "52EAFACECB8823CA", hidden = true },
})
assert(adapter:_isHiddenRoute(hiddenRouteId) == true)
assert(stationRequestCount() == 2)

-- Invalid route ID formats return false without any HTTP request.
nowMs = 90000
requests = {}
local fresh = MtrAdapter.new({ baseUrl = "http://mtr.test" })
responsePayload = routeMapPayload({
    { id = "52EAFACECB8823CA", hidden = true },
})
assert(fresh:_isHiddenRoute(nil) == false)
assert(fresh:_isHiddenRoute("") == false)
assert(fresh:_isHiddenRoute("not-a-route-id") == false)
assert(fresh:_isHiddenRoute("12x") == false)
assert(stationRequestCount() == 0)

print("mtr route cache tests passed")
