package.path = "/src/?.lua;/src/?/init.lua;" .. package.path

local app = require("app")

local ok, err = pcall(app.run)
if not ok then
    printError("Railway Announcement System stopped: " .. tostring(err))
end
