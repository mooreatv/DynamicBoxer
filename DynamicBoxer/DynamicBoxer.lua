--[[
   Dynamic Team by MooreaTV moorea@ymail.com (c) 2019 All rights reserved
   Licensed under LGPLv3 - No Warranty

   Evolving from prototype/proof of concept to usuable for "prod", here is how it currently works:

   Join secret protected channel
   Send our slot id and name and whether this is a reload which requires getting everyone else's data again
   Anytime someone joins the channel or we get a message we first flag, resend our info(*)

   *: the send is smart as it's not actually sending right away but just renabling a periodic send within the
  next interval, that way we don't send 4 times the same thing in short sequence when everyone first logs

   We could also:
     Broadcast periodically slot # and name for a while (or until all acked)
     Stop as soon as you see slot1 (unless you are slot 1)
     Read from slot1 the team list
     Slot1 (master) reading the other slots

   [todo have isboxer just save the team list and slot # more directly
   so we don't have to hook and ideally isboxer would use variables/that team structure in macros
   instead of generating the same hardcoded stuff we end up search/replacing into.
   ]] --
--
-- our name, our empty default (and unused) anonymous ns
local addon, ns = ...

-- Created by DBoxInit
local DB = DynBoxer

-- Battlenet default channel suffix (DynamicBoxer4 will be prefixed in all cases to final channel name)
function DB.DefaultChannel()
  local _, bnetId = BNGetInfo()
  if bnetId and #bnetId > 0 then
    return string.gsub(bnetId, "#", "")
  end
  DB:Warning("No battlenet unique id available, please pick a unique channel manually")
  return ""
end

-- TODO: consider using bnet communication as a common case is all characters are from same bnet
-- (also ideally innerspace or isboxer suite would generate a secure channel/password combo so we don't even
-- need the UI/one time setup)
-- For now we use a regular (private) addon channel (initialized based on battlenet id to be unique)
-- This is just the default assuming a single bnet but can be changed by the user to match on all windows
DB.Channel = DB.DefaultChannel()
DB.Secret = "" -- Empty will force UI/dialog setup (unless already saved in saved vars)

-- to force all debugging on even before saved vars are loaded
-- DB.debug = 9

DB.maxIter = 1 -- We really only need to send the message once (and resend when seeing join from others, batched)
DB.refresh = 1
DB.totalRetries = 0
DB.maxRetries = 20 -- after 20s we stop/give up

DB.chatPrefix = "dbox0" -- protocol version in prefix
DB.channelId = nil
DB.enabled = true -- set to false if the users cancels out of the UI
DB.minSecretLength = 5 -- at least 5 characters for channel password

DB.manual = false -- testing manual mode

-- Returns if we should be operating (basically if isboxer has a static team defined)
function DB:IsActive()
  return self.enabled and (isboxer.Character_LoadBinds or self.manual)
end

-- Replace team members in original macro text by the dynamic one.
function DB:Replace(macro)
  self:Debug(8, "macro before : %", macro)
  local count = 0
  for _, v in ipairs(self.Team) do
    local o = v.orig
    local n = v.new
    -- TODO: probably should do this local/remote determination once when setting the value instead of each time
    local s, r = DB.SplitFullname(n)
    if r == DB.myRealm then
      n = s -- use the short name without realm when on same realm, using full name breaks (!)
    end
    local c
    -- self:Debug("o=%, n=%", o, n)
    macro, c = macro:gsub(o, n) -- TODO: will not work if one character is substring of another, eg foo and foobar
    count = count + c
  end
  if count > 0 then
    self:Debug(8, "macro after %: %", count, macro)
  end
  return macro
end

-- hook/replace isboxer functions by ours, keeping the original for post hook

DB.isboxeroutput = true -- Initially we let isboxer print/warn/output, but only the first time

-- ISBoxer Hooks
DB.ISBH = {} -- new functions
DB.ISBO = {} -- original functions

function DB.ISBH.LoadBinds()
  DB:Debug("Hooked LoadBinds()")
  DB.ReconstructTeam()
  -- Avoid the mismatch complaint:
  isboxer.Character.ActualName = GetUnitName("player")
  isboxer.Character.QualifiedName = DB.fullName
  DB.ISBO.LoadBinds()
  DB.isboxeroutput = false -- only warn/output once
end

function DB.ISBH.SetMacro(username, key, macro, ...)
  DB:Debug(9, "Hooked SetMacro(%, %, %, %)", username, key, macro, DB.Dump(...))
  macro = DB:Replace(macro)
  DB.ISBO.SetMacro(username, key, macro, ...)
end

function DB.ISBH.Output(...)
  DB:Debug(7, "Isb output " .. DB.Dump(...))
  if DB.isboxeroutput then
    DB.ISBO.Output(...)
  end
end

function DB.ISBH.Warning(...)
  DB:Debug(7, "Isb warning " .. DB.Dump(...))
  if DB.isboxeroutput then
    DB.ISBO.Warning(...)
  end
end

for k, v in pairs(DB.ISBH) do
  DB:Debug(3, "Changing/hooking isboxer % will call %", k, v)
  DB.ISBO[k] = isboxer[k]
  isboxer[k] = v
end

function DB.SplitFullname(fullname)
  return fullname:match("(.+)-(.+)")
end

-- Reverse engineer what isboxer will hopefully be providing more directly soon
-- (isboxer.CharacterSet.Members isn't always set when making teams without realm)
function DB.ReconstructTeam()
  if DB.ISBTeam then
    DB:Debug("Already know team to be % and my index % (isb members %)", DB.ISBTeam, DB.ISBIndex,
             isboxer.CharacterSet.Members)
    return
  end
  if not DB:IsActive() then
    DB:Print("DynamicBoxer skipping team reconstruction as there is no isboxer team (not running under innerspace).")
    return
  end
  DB.fullName = DB:GetMyFQN()
  DB.shortName, DB.myRealm = DB.SplitFullname(DB.fullName)
  local prev = isboxer.SetMacro
  DB.ISBTeam = {}
  -- parse the text which looks like (note the ]xxx; delimiters for most but \n at the end)
  -- "/assist [nomod:alt,mod:lshift,nomod:ctrl]FIRST;[nomod:alt,mod:rshift,nomod:ctrl]SECOND;...[nomod:alt...,mod:lctrl]LAST\n""
  DB.ISBIndex = 0 -- not set but init for manual mode
  isboxer.SetMacro = function(macro, _key, text)
    if macro ~= "FTLAssist" then
      return
    end
    for x in text:gmatch("%]([^;]+)[;\n]") do
      table.insert(DB.ISBTeam, x)
      if x == isboxer.Character.ActualName then
        DB.ISBIndex = #DB.ISBTeam
      end
    end
  end
  if isboxer.Character_LoadBinds then
    isboxer.Character_LoadBinds()
  else
    DB:Warning("Manual mode, no isboxer binding")
  end
  isboxer.SetMacro = prev
  DB:Debug("Found team to be % and my index % (while isb members is %)", DB.ISBTeam, DB.ISBIndex,
           isboxer.CharacterSet.Members)
  DB.Team[DB.ISBIndex] = {orig = DB.ISBTeam[DB.ISBIndex], new = DB.fullName}
  DB:Debug("Team map initial value = %", DB.Team)
end

-- the first time, ie after /reload - we will force a resync
DB.firstMsg = 1

function DB.Sync()
  DB:Debug(9, "DB:Sync maxIter %", DB.maxIter)
  if DB.maxIter <= 0 or not DB:IsActive() then
    return
  end
  if not DB.channelId then
    DB.DynamicInit()
  end
  if not DB.channelId then
    return -- for now keep trying until we get a channel
  end
  DB.maxIter = DB.maxIter - 1
  DB:Debug("Sync CB called for slot % our fullname is %, maxIter is now %", DB.ISBIndex, DB.fullName, DB.maxIter)
  if not DB.ISBIndex then
    DB:Debug("We don't know our slot/actual yet")
    return
  end
  local payload = tostring(DB.ISBIndex) .. " " .. DB.fullName .. " " .. DB.ISBTeam[DB.ISBIndex] .. " " .. DB.firstMsg ..
                    " msg " .. tostring(DB.maxIter)
  local ret = C_ChatInfo.SendAddonMessage(DB.chatPrefix, payload, "CHANNEL", DB.channelId)
  DB:Debug("Message success % on chanId %", ret, DB.channelId)
  if ret then
    DB.firstMsg = 0
  else
    DB:Debug("failed to send, will retry % / %", DB.totalRetries, DB.maxRetries)
    DB.totalRetries = DB.totalRetries + 1
    if DB.totalRetries >= DB.maxRetries then
      DB:Error("Giving up sending/syncing after % retries. Use /dbox j to try again later", DB.totalRetries)
      return
    end
    if DB.maxIter <= 0 then
      DB.maxIter = 1
    end
  end
end

DB.Team = {}

function DB:ProcessMessage(from, data)
  local idxStr, realname, internalname, forceStr = data:match("^([^ ]+) ([^ ]+) ([^ ]+) ([^ ]+)") -- or strplit(" ", data)
  DB:Debug("from %, got idx=% realname=% internal name=% first/force=%", from, idxStr, realname, internalname, forceStr)
  if from ~= realname then
    DB:Error("skipping unexpected mismatching name % != %", from, realname)
    return
  end
  local idx = tonumber(idxStr)
  if not idx then
    DB:Error("invalid non numerical idx %", idxStr)
    return
  end
  local force = tonumber(forceStr)
  if not force then
    DB:Error("invalid non numerical first/force flag %", forceStr)
    return
  end
  if force == 1 then
    DB:Debug("Got a reload/first from peer while our maxIter is %", DB.maxIter)
    if DB.maxIter <= 0 then
      DB.maxIter = 1 -- resend at next round
    end
  end
  if DB.Team[idx] and DB.Team[idx].new == realname then
    DB:Debug("Already known mapping, skipping % %", idx, realname)
    return
  end
  DB.Team[idx] = {orig = internalname, new = realname}
  DB:Debug("Team map is now %", DB.Team)
  if EMAApi then
    EMAApi.AddMember(realname)
  end
  isboxer.NextButton = 1 -- reset the buttons
  -- call normal LoadBinds (with output/warning hooked). TODO: maybe wait/batch/don't do it 5 times in small amount of time
  self.ISBO.LoadBinds()
  DB:Print(DB.format("New mapping for slot %, dynamically set ISBoxer character to %", idx, realname), 0, 1, 1)
end

DB.EventD = {
  CHAT_MSG_ADDON = function(self, event, prefix, data, channel, sender, zoneChannelID, localID, name, instanceID)
    self:Debug(7, "OnChatEvent called for % e=% channel=% p=% data=% from % z=%, lid=%, name=%, instance=%",
               self:GetName(), event, channel, prefix, data, sender, zoneChannelID, localID, name, instanceID)
    if channel ~= "CHANNEL" or instanceID ~= DB.joinedChannel then
      self:Debug(9, "wrong channel % or instance % vs %, skipping!", channel, instanceID, DB.joinedChannel)
      return -- not our message(s)
    end
    self:ProcessMessage(sender, data)
  end,

  PLAYER_ENTERING_WORLD = function(self, ...)
    self:Debug("OnPlayerEnteringWorld " .. DB.Dump(...))
    DB.Sync()
  end,

  CHANNEL_COUNT_UPDATE = function(self, _event, displayIndex, count) -- TODO: never seem to fire
    self:Debug("OnChannelCountUpdate didx=%, count=%", displayIndex, count)
  end,

  CHAT_MSG_CHANNEL_JOIN = function(self, _event, _text, playerName, _languageName, _channelName, _playerName2,
                       _specialFlags, _zoneChannelID, _channelIndex, channelBaseName)
    if channelBaseName == self.joinedChannel then
      self:Debug("Join on our channel by %", playerName)
      self["maxIter"] = 1
    end
  end,

  CHAT_MSG_CHANNEL_LEAVE = DB.DebugEvCall,

  UPDATE_BINDINGS = DB.DebugEvCall,

  ADDON_LOADED = function(self, _event, name)
    self:Debug(9, "Addon % loaded", name)
    if name ~= addon then
      return -- not us, return
    end
    if dynamicBoxerSaved then
      DB.deepmerge(DB, nil, dynamicBoxerSaved)
      self:Debug(3, "Loaded saved vars %", dynamicBoxerSaved)
    else
      self:Debug("Initialized empty saved vars")
      dynamicBoxerSaved = {}
    end
  end
}

function DB:OnEvent(event, first, ...)
  DB:Debug(8, "OnEvent called for % e=% %", self:GetName(), event, first)
  local handler = self.EventD[event]
  if handler then
    return handler(self, event, first, ...)
  end
  DB:Error("Unexpected event without handler %", event)
end

function DB.DynamicInit()
  DB:Debug("Delayed init called")
  DB:MoLibInit()
  if not DB:IsActive() then
    DB:Print("DynamicBoxer: No static team/not running under innerspace or user abort... skipping...")
    return
  end
  if #DB.Secret < DB.minSecretLength then
    DB.ChannelUI()
    return -- Join will be called at the positive end of the 2 dialogs
  end
  DB.Join()
end

DB.joinDone = false -- because we reschedule the join from multiple place, lets do that only once

-- note: 2 sources of retry, the dynamic init and
function DB.Join()
  -- First check if we have joined the last std channel and reschedule if not
  -- (so our channel doesn't end up as first one, and /1, /2 etc are normal)
  local id, name, instanceID = GetChannelName(1)
  DB:Debug("Checking std channel, res % name % instanceId %", id, name, instanceID)
  if id <= 0 then
    DB:Debug("Not yet in std channel, retry later")
    return
  end
  if DB.joinDone then
    DB:Debug("Join already done. skipping this one") -- Sync will retry
    return
  end
  DB.joinDone = true
  DB.totalRetries = 0 -- try at most maxRetries (20) times after this point
  if DB.maxIter <= 0 then
    DB.maxIter = 1
  end
  DB.ReconstructTeam()
  local ret = C_ChatInfo.RegisterAddonMessagePrefix(DB.chatPrefix)
  DB:Debug("Prefix register success % in dynamic setup", ret)
  if not DB.Channel or #DB.Channel == 0 then
    DB:Warning("Channel is empty, will use 'demo' instead")
    DB.Channel = "demo"
  end
  DB.joinedChannel = "DynamicBoxer4" .. DB.Channel -- only alphanums seems legal, couldn't find better seperator than 4
  local t, n = JoinTemporaryChannel(DB.joinedChannel, DB.Secret)
  DB.channelId = GetChannelName(DB.joinedChannel)
  DB:Debug("Joined channel % / % type % name % id %", DB.joinedChannel, DB.Secret, t, n, DB.channelId)
  DB:Print(DB.format("Joined DynBoxer secure channel. This is slot % and dynamically setting ISBoxer character to %",
                     DB.ISBIndex, DB.fullName), 0, 1, 1)
  return DB.channelId
end

function DB.Help(msg)
  DB:Print("DynamicBoxer: " .. msg .. "\n" .. "/dbox init -- redo the one time channel/secret setup UI\n" ..
             "/dbox r -- show random id generator.\n" .. "/dbox c channel -- to change channel.\n" ..
             "/dbox s secret -- to change the secret.\n" .. "/dbox m -- send mapping again\n" ..
             "/dbox join -- (re)join channel.\n" .. "/dbox debug on/off/level -- for debugging on at level or off.\n" ..
             "/dbox dump global -- to dump a global.")
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
  local debugPrefix = "debug "
  if cmd == "j" then
    -- join
    DB.joinDone = false -- force rejoin code
    DB.Join()
  elseif cmd == "i" then
    -- re do initialization
    DB:ChannelUI()
  elseif cmd == "r" then
    -- random id generator (misc bonus util)
    StaticPopup_Show("DYNBOXER_RANDOM")
  elseif cmd == "m" then
    -- message again
    DB.maxIter = 1
    DB.totalRetries = 0
    DB.Sync()
  elseif cmd == "c" then
    -- change channel
    DB.SetSaved("Channel", rest)
  elseif cmd == "s" then
    -- change secret
    DB:SetSaved("Secret", rest)
    -- for debug, needs exact match (of start of "debug ..."):
  elseif arg:sub(1, #debugPrefix) == debugPrefix then
    -- debug
    local debugArg = arg:sub(#debugPrefix + 1)
    if debugArg == "on" then
      DB:SetSaved("debug", 1)
    elseif debugArg == "off" then
      DB:SetSaved("debug", nil)
    else
      DB:SetSaved("debug", tonumber(debugArg))
    end
    DB:Print(DB.format("DynBoxer debug now %", DB.debug))
  elseif cmd == "d" then
    -- dump
    DB:Print(DB.format("DynBoxer dump of % = " .. DB.Dump(_G[rest]), rest), .7, .7, .9)
  else
    DB.Help('unknown command "' .. arg .. '", usage:')
  end
end

SlashCmdList["DynamicBoxer_Slash_Command"] = DB.Slash

SLASH_DynamicBoxer_Slash_Command1 = "/dbox"
SLASH_DynamicBoxer_Slash_Command2 = "/dynamicboxer"

DB:SetScript("OnEvent", DB.OnEvent)
for k, _ in pairs(DB.EventD) do
  DB:RegisterEvent(k)
end

DB:Debug("dbox main file loaded")
DB.ticker = C_Timer.NewTicker(DB.refresh, DB.Sync)
