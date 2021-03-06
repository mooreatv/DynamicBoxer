--[[
   Initialization needed before loading ISBoxer patches
   ]] --
--
-- our name, our empty default (and unused) anonymous ns
local addon, _ns = ...

local shortName = "DynBoxer"

-- this creates the global table/ns of namesake
-- we can't use DynamicBoxer as that's already created by MoLib
-- alternatively we can change the order of molib and this lua but
-- then we can't use Debug() at top level
-- Another alternative is to put our frame on DB.frame which may be cleaner (TODO/to consider)
CreateFrame("frame", shortName, UIParent)

local DB = _G[shortName]

_G[addon]:MoLibInstallInto(DB, "DynamicBoxer")

DB.L = DB:GetLocalization()

-- Make sure if we (or more likely, another addon) has errors the user notices/reports the bug
if C_CVar then
  -- bfa onward
  C_CVar.SetCVar("scriptErrors", 1)
  C_CVar.SetCVar("fstack_preferParentKeys", 0)
elseif SetCVar then
  -- classic version
  SetCVar("scriptErrors", 1)
end

-- WowOpenBox
DB.WOB = _G.WowOpenBox
-- Global machine wide SavedVars
DB.GSV = _G.Blizzard_Console_SavedVars
