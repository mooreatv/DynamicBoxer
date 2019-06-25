--[[
   Initialization needed before loading ISBoxer patches
   ]] --
--
-- our name, our empty default (and unused) anonymous ns
local addon, ns = ...

local shortName = "DynBoxer"

-- this creates the global table/ns of namesake
-- we can't use DynamicBoxer as that's already created by MoLib
-- alternatively we can change the order of molib and this lua but
-- then we can't use Debug() at top level
-- Another alternative is to put our frame on DB.frame which may be cleaner (TODO/to consider)
CreateFrame("frame", shortName, UIParent)

local DB = DynBoxer

_G[addon]:MoLibInstallInto(DB, shortName)
