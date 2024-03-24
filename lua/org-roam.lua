-------------------------------------------------------------------------------
-- ORG-ROAM.LUA
--
-- Main entrypoint into the org-roam neovim plugin.
-------------------------------------------------------------------------------

-- Verify that we have orgmode available
if not pcall(require, "orgmode") then
    error("missing dependency: orgmode")
end

local database = require("org-roam.database")
local setup = require("org-roam.setup")

---@class org-roam.OrgRoam
local M = {}

---Called to initialize the org-roam plugin.
---@param opts org-roam.Config
function M.setup(opts)
    setup(opts)

    -- Load the database asynchronously
    database.load(function() end)
end

return M
