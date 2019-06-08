--[[ 
   Proof of concept of Dynamic Team by MooreaTV moorea@ymail.com

   Join secret/protect channel
   Broadcast periodically slot # and name for a while (or until all acked)
   Stop as soon as you see slot1 (unless you are slot 1)
   Read from slot1 the team list
   Slot1 (master) reading the other slots

   [todo have isboxer just save the team list and slot # more directly
   so we don't have to hook and use variables/that team structure in macros
   instead of generating the same hardcoded stuff we end up search/replacing into.
   ]] --
--
-- our name, our empty default (and unused) anonymous ns
local addon, ns = ...

CreateFrame("frame", "DynamicBoxer", UIParent) -- this creates the global table/ns of namesake

local DB = DynamicBoxer

ISBoxer.MoLibInstallInto(DB, "DynBoxer") -- copy the library here under our (shorter) name (and not ISBoxer)

-- TODO: for something actually secure, this must be generated and kept secret
-- also consider using bnet communication as a common case is all characters are from same bnet

DB.Channel = string.gsub(select(2, BNGetInfo()), "#", "") -- also support multiple bnet/make this confirgurable
-- this should be secure, unique,... and/or ask the user to /dbox secret <something> and save it
-- or a StaticPopupDialogs / StaticPopup_Show
DB.Secret = "PrototypeSecret12345"

DB.debug = 1

DB.teamComplete = false
DB.maxIter = 1
DB.refresh = 5

DB.chatPrefix = "dbox0" -- protocol version in prefix
DB.channelId = nil

-- hook/replace isboxer functions by ours, keeping the original for post hook
DB.isbHooks = {LoadBinds = isboxer.LoadBinds, SetMacro = isboxer.SetMacro}

function DB.LoadBinds()
  DB:Debug("Hooked LoadBinds()")
  DB.ReconstructTeam()
  DB.isbHooks["LoadBinds"]()
end

function DB.SetMacro(username, key, macro, ...)
  DB:Debug("Hooked SetMacro(%, %, %, %)", username, key, macro, DB.Dump(...))
  DB.isbHooks["SetMacro"](username, key, macro, ...)
end

for k, v in pairs(DB.isbHooks) do
  isboxer[k] = DB[k]
end

-- Reverse engineer what isboxer will hopefully be providing more directly soon
-- (isboxer.CharacterSet.Members isn't always set when making teams without realm)
function DB.ReconstructTeam()
  if DB.ISBTeam then
    DB:Debug("Already know team to be % and my index % (isb members %)", DB.ISBTeam, DB.ISBIndex, isboxer.CharacterSet.Members)
    return
  end
  local prev = isboxer.SetMacro
  DB.ISBTeam = {}
  -- parse the text which looks like
  -- "/assist [nomod:alt,mod:lshift,nomod:ctrl]CHAR1;[nomod:alt,mod:rshift,nomod:ctrl]CHAR2;[nomod:alt,nomod:shift,mod:lctrl]CHAR3;..."
  isboxer.SetMacro = function(macro, key, text)
    if macro ~= "FTLAssist" then
      return
    end
    for x in text:gmatch("]([^;]+)[;\n]") do
      table.insert(DB.ISBTeam, x)
      if x == isboxer.Character.ActualName then
        DB.ISBIndex = #DB.ISBTeam
      end
    end
  end
  isboxer.Character_LoadBinds()
  isboxer.SetMacro = prev
  DB:Debug("Found team to be % and my index % (while isb members is %)", DB.ISBTeam, DB.ISBIndex, isboxer.CharacterSet.Members)
end

function DB.Sync()
  if DB.maxIter <= 0 or DB.teamComplete then
    -- TODO: unregister the event/cb/timer/ticker
    -- DB:Debug("CB shouldn't be called when maxIter is " .. DB.maxIter .. " or teamComplete is " ..
    --                     tostring(DB.teamComplete))
    return
  end
  if not DB.channelId then
    DB.DynamicInit()
  end
  DB.maxIter = DB.maxIter - 1
  DB:Debug("Sync CB called for slot % actual %, our fullname is %, maxIter is now %", DB.slot, DB.actual, DB.fullName, DB.maxIter)
  if not DB.ISBIndex then
    DB:Debug("We don't know our slot/actual yet")
    return
  end
  local payload = tostring(DB.ISBIndex) .. " " .. DB.fullName .. " " .. DB.ISBTeam[DB.DBISBIndex] .. " msg " .. tostring(DB.maxIter)
  local ret = C_ChatInfo.SendAddonMessage(DB.chatPrefix, payload, "CHANNEL", DB.channelId)
  DB:Debug("Message success % on chanId %", ret, DB.channelId)
end

DB.EventD = {

  CHAT_MSG_ADDON = function(self, event, prefix, data, channel, sender, zoneChannelID, localID, name, instanceID)
    self:Debug("OnChatEvent called for % e=% channel=% p=% data=% from % z=%, lid=%, name=%, instance=%", self:GetName(), event,
               channel, prefix, data, sender, zoneChannelID, localID, name, instanceID)
  end,

  PLAYER_ENTERING_WORLD = function(self, ...)
    self:Debug("OnPlayerEnteringWorld " .. DB.Dump(...))
    DB.Sync()
  end,

  CHANNEL_COUNT_UPDATE = function(self, event, displayIndex, count) -- TODO: never seem to fire
    self:Debug("OnChannelCountUpdate didx=%, count=%", displayIndex, count)
  end,

  CHAT_MSG_CHANNEL_JOIN = DB.DebugEvCall,

  CHAT_MSG_CHANNEL_LEAVE = DB.DebugEvCall

}

function DB:OnEvent(event, ...)
  DB:Debug("OnEvent called for % e=%", self:GetName(), event)
  local handler = self.EventD[event]
  if handler then
    return handler(self, event, ...)
  end
  DB:Print("Unexpected event without handler " .. event, 1, 0, 0)
end

function DB.DynamicSetup(slot, actual)
  DB.slot = slot
  DB.actual = actual
  local ret = C_ChatInfo.RegisterAddonMessagePrefix(DB.chatPrefix)
  DB:Debug("Prefix register success % in dynamic setup % %", ret, slot, actual)
  isboxer.Character.ActualName = actual
  isboxer.Character.QualifiedName = DB.fullName
  return true -- TODO: only return true if we are good to go (but then the sync may take a while and fail later)
end

function DB.DynamicInit(slot, actual)
  DB:Debug("Delayed init called")
  DB:MoLibInit()
  DB.Join()
end

function DB.Join()
  -- First check if we have joined the last std channel and reschedule if not
  -- (so our channel doesn't end up as first one, and /1, /2 etc are normal)
  local id, name, instanceID = GetChannelName(1)
  DB:Debug("Checking std channel, res % name % instanceId %", id, name, instanceID)
  if id <= 0 then
    DB:Debug("Not yet in std channel, retrying in 1 sec")
    C_Timer.After(1, DB.Join)
    return
  end
  DB.fullName = DB:GetMyFQN()
  DB.ReconstructTeam()
  -- First join the std channels to make sure we end up being at the end and not first
  -- for _, c in next, {"General", "Trade", "LocalDefense", "LookingForGroup", "World"} do
  --   type, name = JoinPermanentChannel(c)
  --   DB:Debug("Joined channel " .. c .. ", type " .. (type or "<nil>") .. " name " .. (name or "<unset>"))
  -- end
  local t, n = JoinTemporaryChannel(DB.Channel, DB.Secret, 99)
  DB.channelId = GetChannelName(DB.Channel)
  DB:Debug("Joined channel % type % name % id %", DB.Channel, t, n, DB.channelId)
  return DB.channelId
end

function DB.Help(msg)
  DB:Print("DynamicBoxer: " .. msg .. "\n" .. "/dbox join -- join channel.\n" .. "/dbox more... coming...later...")
end

function DB.Slash(arg)
  if #arg == 0 then
    DB.Help("commands")
    return
  end
  local cmd = string.lower(string.sub(arg, 1, 1))
  local posRest = string.find(arg, " ")
  local rest = ""
  if not (posRest == nil) then
    rest = string.sub(arg, posRest + 1)
  end
  if cmd == "j" then
    -- join
    DB.Join()
  elseif cmd == "q" then
    -- query 
    -- for debug, needs exact match:
  elseif arg == "debug on" then
    -- debug
    DB.debug = 1
    DB:Print("DynamicBoxer Debug ON")
  elseif arg == "debug off" then
    -- debug
    DB.debug = nil
    DB:Print("DynamicBoxer Debug OFF")
  else
    DB.Help("unknown command \"" .. arg .. "\", usage:")
  end
end

SlashCmdList["DynamicBoxer_Slash_Command"] = DB.Slash

SLASH_DynamicBoxer_Slash_Command1 = "/dbox"
SLASH_DynamicBoxer_Slash_Command2 = "/dynamicboxer"

DB:SetScript("OnEvent", DB.OnEvent)
for k, _ in pairs(DB.EventD) do
  DB:RegisterEvent(k)
end

DB:Debug("dbox file loaded")
DB.ticker = C_Timer.NewTicker(DB.refresh, DB.Sync)