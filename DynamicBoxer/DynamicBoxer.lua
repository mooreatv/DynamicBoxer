--[[
   DynamicBoxer: Dynamic Team Multiboxing by MooreaTV moorea@ymail.com (c) 2019 All rights reserved
   Licensed under LGPLv3 - No Warranty
   (contact the author if you need a different license)

   Evolved from prototype/proof of concept to usuable for "prod", here is how it currently works:

   New (1.2) idea:
   UI only shows what to copy from slot 1 into slot 2..N
   Includes slot1's name and a secret
   all 2..N msg slot1, 2 cases:
   - everyone is on same realm: use channel
   - cross realm boxing: slot1 can reply with team composition; we record slot1s and team affinity
   UI to re copy paste credentials when logging a new team member cross realm

   Join secret protected channel
   Send our slot id and name and whether this is a reload which requires getting everyone else's data again
   Anytime someone joins the channel or we get a message we first flag, resend our info(*)
   Rewrite all the macros with correct character names for slot

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

-- We considered using bnet communication as a common case is all characters are from same bnet
-- See Issue #5, unfortunately seems impossible to see self logged in characters (even though you can see all your friends)
-- (also ideally innerspace or isboxer suite would generate a secure channel/password combo so we don't even
-- need the UI/one time setup)

-- For now we use a regular (private) randomized addon channel with random password
DB.Channel = ""
DB.Secret = ""
DB.MasterName = ""
DB.MasterToken = nil -- Nil will force UI/dialog setup (unless already saved in saved vars)
DB.teamHistory = {}
DB.currentCount = 0 -- how many characters from the team have been mapped (ie size of sorted team)
DB.expectedCount = 0 -- how many slots we expect to see/map

-- to force all debugging on even before saved vars are loaded
-- DB.debug = 9

DB.maxIter = 1 -- We really only need to send the message once (and resend when seeing join from others, batched)
DB.refresh = 1
DB.totalRetries = 0
DB.maxRetries = 20 -- after 20s we stop/give up

DB.chatPrefix = "dbox0" -- protocol version in prefix
DB.channelId = nil
DB.enabled = true -- set to false if the users cancels out of the UI
DB.randomIdLen = 8 -- we generate 8 characters long random ids
DB.tokenMinLen = DB.randomIdLen * 2 + 2 + 4
DB.configVersion = 1 -- bump up to support conversion (and update the ADDON_LOADED handler)

DB.manual = 0 -- testing manual mode, 0 is off, number is slot id

-- Returns if we should be operating (basically if isboxer has a static team defined)
function DB:IsActive()
  return self.enabled and (isboxer.Character_LoadBinds or self.manual > 0)
end

-- Replace team members in original macro text by the dynamic one.
function DB:Replace(macro)
  self:Debug(8, "macro before : %", macro)
  local count = 0
  -- Deal with issue#10 by doing 2 passes first longest origin to SLOTXX then SLOTXX to actual, to avoid
  -- any possible source/destination overlap (step 2/2, step 1, the sorting is further below)
  for k, v in ipairs(self.SortedTeam) do -- ipairs stops at first hole but we removed holes in SortTeam
    local o = v.orig
    local n = v.new
    local s = v.slot
    v.slotStr = string.format("SLOT%02d", s) -- up to 99 slots, should be enough, mutates the original, it's ok
    local c
    self:Debug(9, "#%: for s=% o=% -> i=% (n=%)", k, s, o, v.slotStr, n)
    macro, c = DB.ReplaceAll(macro, o, v.slotStr)
    count = count + c
  end
  for k, v in ipairs(self.SortedTeam) do
    local o = v.orig
    local n = v.new
    local s = v.slot
    local c
    self:Debug(9, "#%: for s=% i=% -> n=% (o=%)", k, s, v.slotStr, n, o)
    macro, c = DB.ReplaceAll(macro, v.slotStr, n)
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
    DB:Warning("Manual mode, no isboxer binding, simulating slot %", DB.manual)
    DB.ISBIndex = DB.manual
    DB.ISBTeam[DB.ISBIndex] = DB.format("Slot%", DB.ISBIndex)
  end
  isboxer.SetMacro = prev
  DB:Debug("Found isbteam to be % and my index % (while isb members is %)", DB.ISBTeam, DB.ISBIndex,
           isboxer.CharacterSet.Members)
  DB.Team[DB.ISBIndex] = {orig = DB.ISBTeam[DB.ISBIndex], new = DB.shortName, slot = DB.ISBIndex}
  DB:Debug("Team map initial value = %", DB.Team)
  -- detect team changes, keep unique teams
  local teamStr = table.concat(DB.ISBTeam, " ")
  if not DB.teamHistory[teamStr] then
    DB:Warning("New (isboxer) team detected, will show master token for copy paste until team is complete.")
    DB.newTeam = true
  end
  DB.teamHistory[teamStr] = GetServerTime()
  dynamicBoxerSaved.teamHistory = DB.teamHistory
  DB.currentCount = DB:SortTeam() -- will be 1
  DB.expectedCount = #DB.ISBTeam
  DB:Debug("Unique team string key is %, updated in history, expecting a team of size #", teamStr, DB.expectedCount)
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

-- Deal with issue#10 by sorting by inverse of length, to replace most specific first (step 1/2)

function DB:SortTeam()
  local presentCount = 0
  self.SortedTeam = {}
  -- remove holes before sorting (otherwise it doesn't work in a way that is usuable, big gotcha)
  for _, v in pairs(self.Team) do
    if v then
      table.insert(self.SortedTeam, v)
      presentCount = presentCount + 1
    end
  end
  table.sort(self.SortedTeam, function(a, b)
    return #a.orig > #b.orig
  end)
  self:Debug(1, "Team map (sorted by longest orig name first) is now % - size %", self.SortedTeam, presentCount)
  return presentCount
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
  local s, r = DB.SplitFullname(realname)
  if r == DB.myRealm then
    DB:Debug(3, "% is on our realm so using %", realname, s)
    realname = s -- use the short name without realm when on same realm, using full name breaks (!)
  end
  if DB.newTeam and DB.ISBIndex == 1 and DB.currentCount < DB.expectedCount then
    DB:Debug(1, "New team detected, on master, showing current token")
    DB:ShowTokenUI()
  end
  if DB.Team[idx] and DB.Team[idx].new == realname then
    DB:Debug("Already known mapping, skipping % %", idx, realname)
    return
  end
  DB.Team[idx] = {orig = internalname, new = realname, slot = idx}
  if EMAApi then
    EMAApi.AddMember(realname)
  end
  local oldCount = DB.currentCount
  DB.currentCount = DB:SortTeam()
  local teamComplete = (DB.currentCount >= DB.expectedCount and DB.currentCount ~= oldCount)
  -- if team is complete, hide the show button
  if DB.newTeam and DB.ISBIndex == 1 and teamComplete then
    DB:Debug(1, "Team complete, hiding current token dialog")
    DB:HideTokenUI()
  end
  isboxer.NextButton = 1 -- reset the buttons
  -- call normal LoadBinds (with output/warning hooked). TODO: maybe wait/batch/don't do it 5 times in small amount of time
  self.ISBO.LoadBinds()
  DB:Print(DB.format("New mapping for slot %, dynamically set ISBoxer character to %", idx, realname), 0, 1, 1)
  if teamComplete then
    DB:Print(DB.format("This completes the team of %, get multiboxing and thank you for using DynamicBoxer!", DB.currentCount), 0, 1, 1)
  end
end

function DB:ChatAddonMsg(event, prefix, data, channel, sender, zoneChannelID, localID, name, instanceID)
  DB:Debug(7, "OnChatEvent called for % e=% channel=% p=% data=% from % z=%, lid=%, name=%, instance=%", self:GetName(),
           event, channel, prefix, data, sender, zoneChannelID, localID, name, instanceID)
  if channel ~= "CHANNEL" or instanceID ~= DB.joinedChannel then
    DB:Debug(9, "wrong channel % or instance % vs %, skipping!", channel, instanceID, DB.joinedChannel)
    return -- not our message(s)
  end
  DB:ProcessMessage(sender, data)
end

DB.EventD = {
  CHAT_MSG_ADDON = DB.ChatAddonMsg,

  BN_CHAT_MSG_ADDON = DB.ChatAddonMsg,

  PLAYER_ENTERING_WORLD = function(self, ...)
    self:Debug("OnPlayerEnteringWorld " .. DB.Dump(...))
    DB.Sync()
  end,

  CHANNEL_COUNT_UPDATE = function(self, _event, displayIndex, count) -- Note: never seem to fire
    self:Debug("OnChannelCountUpdate didx=%, count=%", displayIndex, count)
  end,

  CHAT_MSG_CHANNEL_JOIN = function(self, _event, _text, playerName, _languageName, _channelName, _playerName2,
                                   _specialFlags, _zoneChannelID, _channelIndex, channelBaseName)
    if channelBaseName == self.joinedChannel then
      self:Debug("Join on our channel by %", playerName)
      self["maxIter"] = 1
    end
  end,

  CHAT_MSG_CHANNEL_LEAVE = function(self, ...)
    self:DebugEvCall(1, ...)
  end,

  UPDATE_BINDINGS = function(self, ...)
    self:DebugEvCall(1, ...)
  end,

  BN_CONNECTED = function(self, ...)
    self:DebugEvCall(1, ...)
  end,

  BN_DISCONNECTED = function(self, ...)
    self:DebugEvCall(1, ...)
  end,

  BN_FRIEND_INFO_CHANGED = function(self, ...)
    self:DebugEvCall(3, ...)
  end,

  BN_INFO_CHANGED = function(self, ...)
    self:DebugEvCall(3, ...)
  end,

  ADDON_LOADED = function(self, _event, name)
    self:Debug(9, "Addon % loaded", name)
    if name ~= addon then
      return -- not us, return
    end
    DB:Print("DynamicBoxer " .. DB.manifestVersion .. " by MooreaTv: type /dbox for command list/help.")
    if dynamicBoxerSaved then
      if not dynamicBoxerSaved.configVersion or dynamicBoxerSaved.configVersion ~= DB.configVersion then
        -- Support conversion from 1 to 2 etc...
        DB:Error(
          "Invalid/unexpected config version (%, we expect %), sorry conversion not available, starting from scratch!",
          dynamicBoxerSaved.configVersion, DB.configVersion)
      else
        local valid, masterName, tok1, tok2 -- start nil
        if not dynamicBoxerSaved.MasterToken then
          -- allow nil/unset master token
          DB:Warning("Token isn't set yet...")
        else
          valid, masterName, tok1, tok2 = DB:ParseToken(dynamicBoxerSaved.MasterToken)
        end
        if dynamicBoxerSaved.MasterToken and not valid then
          DB:Error("Master token % is invalid, resetting...", dynamicBoxerSaved.FooBar)
        else
          DB.deepmerge(DB, nil, dynamicBoxerSaved)
          DB.MasterName = masterName
          DB.Channel = tok1
          DB.Secret = tok2
          self:Debug(3, "Loaded valid saved vars %", dynamicBoxerSaved)
          return
        end
      end
    end
    -- (re)Init saved vars
    self:Debug("Initialized empty saved vars")
    dynamicBoxerSaved = {}
    dynamicBoxerSaved.configVersion = DB.configVersion
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
  if DB.inUI then
    DB:Debug(3, "Still in UI, skipping init/join...")
    return
  end
  if not DB:IsActive() then
    DB:Print("DynamicBoxer: No static team/not running under innerspace or user abort... skipping...")
    return
  end
  if not DB.MasterToken or #DB.MasterToken == 0 then
    DB.ForceInit()
    return -- Join will be called at the positive end of the dialog
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
  if not DB.Channel or #DB.Channel == 0 or not DB.Secret or #DB.Secret == 0 then
    DB:Error("Channel and or Password are empty - this should not be reached/happen")
    return
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
             "/dbox show -- shows the current token string.\n" ..
             "/dbox set tokenstring -- sets the token string (but using the UI is better)\n" ..
             "/dbox m -- send mapping again\n" .. "/dbox join -- (re)join channel.\n" ..
             "/dbox debug on/off/level -- for debugging on at level or off.\n" ..
             "/dbox r -- show random id generator.\n" .. "/dbox dump global -- to dump a global.")
end

function DB:SetSaved(name, value)
  self[name] = value
  dynamicBoxerSaved[name] = value
  DB:Debug("(Saved) Setting % set to % - dynamicBoxerSaved=%", name, value, dynamicBoxerSaved)
end

function DB.SetupChange()
  -- re do initialization
  if DB.joinedChannel then
    DB:Debug("Re-init requested, leaving %: %", DB.joinedChannel, LeaveChannelByName(DB.joinedChannel))
    DB.enabled = false
    DB.joinedChannel = nil
    DB.channelId = nil
    DB.joinDone = false
  end
end

function DB.ForceInit()
  DB.SetupChange()
  DB.fullName = DB:GetMyFQN() -- usually set in reconstruct team but we can call /dbox i for testing without isboxer on
  DB:SetupUI()
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
    DB:ForceInit()
  elseif arg == "reset" then
    -- require reset to be spelled out (other r* are the random gen)
    dynamicBoxerSaved = nil -- any subsequent DB:SetSaved will fail...
    DB:Warning("State reset per request, please /reload !")
    -- C_UI.Reload() -- in theory we could reload for them but that seems bad form
  elseif cmd == "r" then
    -- random id generator (misc bonus util)
    DB.RandomGeneratorUI()
  elseif cmd == "m" then
    -- message again
    DB.maxIter = 1
    DB.totalRetries = 0
    DB.Sync()
  elseif cmd == "s" then
    -- show ui or set token depending on argument
    if #rest >= DB.tokenMinLen then
      local valid, masterName, tok1, tok2 = DB:ParseToken(rest)
      if not valid then
        DB:Warning("Invalid token set attempt for % !", rest)
      else
        DB:Warning("Valid token, change accepted")
        DB:SetSaved("MasterToken", rest)
        DB.Channel = tok1
        DB.Secret = tok2
        DB.MasterName = masterName
        DB.SetupChange()
        DB.enabled = true
        DB:Join()
        return
      end
    end
    -- if above didn't match, failed/didn't return, then fall back to showing UI
    DB:ShowTokenUI()
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
