package.path = "./src/?.lua;" .. package.path

local MtrAdapter = require("adapter.mtr")
local Composer = require("core.composer")

local adapter = MtrAdapter.new({})
local arrival = { routeId = "-8442318287410092952", isTerminating = false }
local routes = {
    { id = "8AD6DC3F36232468", hidden = true },
    { id = "AE15E06B69A5ED48", hidden = false },
    { id = "52EAFACECB8823CA", hidden = true },
    { id = "8000000000000000", hidden = true },
    { id = "7FFFFFFFFFFFFFFF", hidden = true },
    { id = "0000000000000001", hidden = true },
}
function adapter:_requestArrival()
    return arrival
end
function adapter:_requestMap(endpoint)
    assert(endpoint == "stations-and-routes")
    return { routes = routes }
end

local hidden = adapter:getMetadata({})
assert(hidden.hidden == true and hidden.terminating == false)
assert(adapter:_isHiddenRoute("5974863621745288138") == true)
assert(adapter:_isHiddenRoute("-5902564984660562616") == false)
assert(adapter:_isHiddenRoute("-9223372036854775808") == true)
assert(adapter:_isHiddenRoute("9223372036854775807") == true)
assert(adapter:_isHiddenRoute("1") == true)
assert(adapter:_isHiddenRoute(nil) == false)
assert(adapter:_isHiddenRoute("42") == false)

local composer = Composer.new({
    approach = { "normal" },
    approach_out_of_service = { "out_of_service" },
    next_train = { "next" },
}, {
    resolve = function(_, id)
        return { id }
    end,
})
for _, metadata in ipairs({
    { terminating = true, hidden = false },
    hidden,
    { terminating = true, hidden = true },
}) do
    local items = composer:compose({ type = "approach" }, metadata)
    assert(items[1] == "out_of_service")
    local nextItems = composer:compose({ type = "next_train" }, metadata)
    assert(#nextItems == 0)
end
local normal = composer:compose({ type = "approach" }, { hidden = false, terminating = false })
assert(normal[1] == "normal")
local nextItems = composer:compose({ type = "next_train" }, { hidden = false, terminating = false })
assert(nextItems[1] == "next")

arrival.isTerminating = true
arrival.routeId = "-5902564984660562616"
local terminating = adapter:getMetadata({})
assert(terminating.terminating == true and terminating.hidden == false)

print("hidden route tests passed")
