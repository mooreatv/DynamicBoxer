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

local shortName = "DynBoxer"

-- this creates the global table/ns of namesake
-- we can't use DynamicBoxer as that's already created by MoLib
-- alternatively we can change the order of molib and this lua but
-- then we can't use Debug() at top level
-- Another alternative is to put our frame on DB.frame which may be cleaner (TODO/to consider)
CreateFrame("frame", shortName, UIParent)

local DB = DynBoxer

DynamicBoxer.MoLibInstallInto(DB, shortName)

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
  -- Avoid the mismatch complaint:
  isboxer.Character.ActualName = GetUnitName("player")
  isboxer.Character.QualifiedName = DB.fullName
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
function DB:ReconstructTeam()
  if DB.ISBTeam then
    DB:Debug("Already know team to be % and my index % (isb members %)", DB.ISBTeam, DB.ISBIndex, isboxer.CharacterSet.Members)
    return
  end
  DB.fullName = DB:GetMyFQN()
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
  DB:Debug("Sync CB called for slot % our fullname is %, maxIter is now %", DB.ISBIndex, DB.fullName, DB.maxIter)
  if not DB.ISBIndex then
    DB:Debug("We don't know our slot/actual yet")
    return
  end
  local payload = tostring(DB.ISBIndex) .. " " .. DB.fullName .. " " .. DB.ISBTeam[DB.ISBIndex] .. " msg " .. tostring(DB.maxIter)
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

  CHAT_MSG_CHANNEL_LEAVE = DB.DebugEvCall,

  UPDATE_BINDINGS = DB.DebugEvCall,

  ADDON_LOADED = function(self, event, name)
    if name ~= addon then
      return -- not us, return
    end
    if dynamicBoxerSaved then
      DB.deepmerge(DB, nil, dynamicBoxerSaved)
      DB:Debug("Loaded saved vars %", dynamicBoxerSaved)
    else
      DB:Debug("Initialized empty saved vars")
      dynamicBoxerSaved = {}
    end
  end

}

function DB:OnEvent(event, first, ...)
  DB:Debug("OnEvent called for % e=% %", self:GetName(), event, first)
  local handler = self.EventD[event]
  if handler then
    return handler(self, event, first, ...)
  end
  DB:Print("Unexpected event without handler " .. event, 1, 0, 0)
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
  DB.ReconstructTeam()
  local ret = C_ChatInfo.RegisterAddonMessagePrefix(DB.chatPrefix)
  DB:Debug("Prefix register success % in dynamic setup % %", ret, slot, actual)
  -- First join the std channels to make sure we end up being at the end and not first
  -- for _, c in next, {"General", "Trade", "LocalDefense", "LookingForGroup", "World"} do
  --   type, name = JoinPermanentChannel(c)
  --   DB:Debug("Joined channel " .. c .. ", type " .. (type or "<nil>") .. " name " .. (name or "<unset>"))
  -- end
  local t, n = JoinTemporaryChannel(DB.Channel, DB.Secret)
  DB.channelId = GetChannelName(DB.Channel)
  DB:Debug("Joined channel % / % type % name % id %", DB.Channel, DB.Secret, t, n, DB.channelId)
  return DB.channelId
end

function DB.Help(msg)
  DB:Print("DynamicBoxer: " .. msg .. "\n" .. "/dbox c channel -- to change channel.\n" ..
             "/dbox s secret -- to change the secret.\n" .. "/dbox join -- (re)join channel.\n" ..
             "/dbox debug on/off -- for debugging on or off.\n" .. "/dbox dump global -- to dump a global.")
end

function DB:SetSaved(name, value)
  self[name] = value
  dynamicBoxerSaved[name] = value
  DB:Debug("(Saved) Setting % set to % - dynamicBoxerSaved=%", name, value, dynamicBoxerSaved)
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
  elseif cmd == "c" then
    -- change channel 
    DB.SetSaved("Channel", rest)
  elseif cmd == "s" then
    -- change secret
    DB:SetSaved("Secret", rest)
    -- for debug, needs exact match:
  elseif arg == "debug on" then
    -- debug
    DB:SetSaved("debug", 1)
    DB:Print("DynBoxer debug ON")
  elseif arg == "debug off" then
    -- debug
    DB:SetSaved("debug", nil)
    DB:Print("DynBoxer debug OFF")
  elseif cmd == "d" then
    -- dump
    DB:Print(DB.format("DynBoxer dump of % = " .. DB.Dump(_G[rest]), rest), 0, 1, 1)
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

-- This event too early and the realm isn't available yet
-- causing nil error trying to get the fully qualified name
isboxer.frame:UnregisterEvent("UPDATE_BINDINGS")

DB:Debug("dbox file loaded")
DB.ticker = C_Timer.NewTicker(DB.refresh, DB.Sync)
