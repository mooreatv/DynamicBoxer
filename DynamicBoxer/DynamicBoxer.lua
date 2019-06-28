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

   Todo: have isboxer just save the team list and slot # more directly
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
DB.masterHistory = DB:LRU(48) -- how many to keep
DB.currentCount = 0 -- how many characters from the team have been mapped (ie size of sorted team)
DB.expectedCount = 0 -- how many slots we expect to see/map

-- to force all debugging on even before saved vars are loaded
-- DB.debug = 9

DB.maxIter = 1 -- We really only need to send the message once (and resend when seeing join from others, batched)
DB.refresh = 2.5
DB.totalRetries = 0
DB.maxRetries = 20 -- after 20s we stop/give up

DB.chatPrefix = "dbox0" -- protocol version in prefix for the addon messages
DB.whisperPrefix = "DynamicBoxer:" -- chat prefix in case it goes to wrong toon, to make it clearer what it may be
DB.channelId = nil
DB.enabled = true -- set to false if the users cancels out of the UI
DB.randomIdLen = 8 -- we generate 8 characters long random ids
DB.tokenMinLen = DB.randomIdLen * 2 + 2 + 4
DB.configVersion = 1 -- bump up to support conversion (and update the ADDON_LOADED handler)

DB.manual = 0 -- testing manual mode, 0 is off, number is slot id

DB.EMA = _G.LibStub and _G.LibStub:GetLibrary("AceAddon-3.0", true)
DB.EMA = DB.EMA and DB.EMA:GetAddon("Team", true)

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
    macro, c = DB:ReplaceAll(macro, o, v.slotStr)
    count = count + c
  end
  for k, v in ipairs(self.SortedTeam) do
    local o = v.orig
    local n = v.new
    local s = v.slot
    local c
    self:Debug(9, "#%: for s=% i=% -> n=% (o=%)", k, s, v.slotStr, n, o)
    macro, c = DB:ReplaceAll(macro, v.slotStr, n)
    count = count + c
  end
  if count > 0 then
    self:Debug(8, "macro after %: %", count, macro)
  end
  return macro
end

-- hook/replace isboxer functions by ours, keeping the original for post hook

DB.isboxeroutput = true -- Initially we let isboxer print/warn/output, but only the first time

-- ISBoxer Hooks, only functions in the whole file not using : as isboxer original ones do not
DB.ISBH = {} -- new functions
DB.ISBO = {} -- original functions

function DB.ISBH.LoadBinds()
  DB:Debug("Hooked LoadBinds()")
  DB:ReconstructTeam()
  -- Avoid the mismatch complaint:
  isboxer.Character.ActualName = GetUnitName("player")
  isboxer.Character.QualifiedName = DB.fullName
  DB.ISBO.LoadBinds()
  DB.isboxeroutput = false -- only warn/output once
end

function DB.ISBH.SetMacro(username, key, macro, ...)
  DB:Debug(9, "Hooked SetMacro(%, %, %, %)", username, key, macro, DB:Dump(...))
  macro = DB:Replace(macro)
  DB.ISBO.SetMacro(username, key, macro, ...)
end

function DB.ISBH.Output(...)
  DB:Debug(7, "Isb output " .. DB:Dump(...))
  if DB.isboxeroutput then
    DB.ISBO.Output(...)
  end
end

function DB.ISBH.Warning(...)
  DB:Debug(7, "Isb warning " .. DB:Dump(...))
  if DB.isboxeroutput then
    DB.ISBO.Warning(...)
  end
end

for k, v in pairs(DB.ISBH) do
  DB:Debug(3, "Changing/hooking isboxer % will call %", k, v)
  DB.ISBO[k] = isboxer[k]
  isboxer[k] = v
end

function DB:SplitFullname(fullname)
  if type(fullname) ~= 'string' then
    DB:Debug(1, "trying to split non string %", fullname)
    return
  end
  return fullname:match("(.+)-(.+)")
end

-- Reverse engineer what isboxer will hopefully be providing more directly soon
-- (isboxer.CharacterSet.Members isn't always set when making teams without realm)
function DB:ReconstructTeam()
  if DB.ISBTeam then
    DB:Debug("Already know team to be % and my index % (isb members %)", DB.ISBTeam, DB.ISBIndex,
             isboxer.CharacterSet.Members)
    return
  end
  DB.fullName = DB:GetMyFQN()
  DB.faction = UnitFactionGroup("player")
  DB.shortName, DB.myRealm = DB:SplitFullname(DB.fullName)
  if not DB:IsActive() then
    DB:Print("DynamicBoxer skipping team reconstruction as there is no isboxer team (not running under innerspace).")
    return
  end
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
    DB.ISBTeam[DB.ISBIndex] = DB:format("Slot%", DB.ISBIndex)
  end
  isboxer.SetMacro = prev
  DB:Debug("Found isbteam to be % and my index % (while isb members is %)", DB.ISBTeam, DB.ISBIndex,
           isboxer.CharacterSet.Members)
  DB.Team[DB.ISBIndex] = {
    orig = DB.ISBTeam[DB.ISBIndex],
    new = DB.shortName,
    fullName = DB.fullName,
    slot = DB.ISBIndex
  }
  if DB.ISBIndex == 1 then
    DB.MasterName = DB.fullName
  end
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
  DB:Debug("Unique team string key is %, updated in history, expecting a team of size #%", teamStr, DB.expectedCount)
  if DB.EMA then
    DB.EMA.db.newTeamList = {}
    EMAApi.AddMember(DB.fullName)
    DB:Debug("Cleared EMA team")
  end
end

function DB:SameRealmAsMaster()
  local _, r = DB:SplitFullname(DB.MasterName)
  return DB.myRealm == r
end

function DB:WeAreMaster()
  return DB.ISBIndex == 1
end

function DB:DebugLogWrite(what)
  -- format is HH:MM:SS hundredsOfSec the 2 clock source aren't aligned so for deltas of
  -- 9 seconds or less, substract the 2 hundredsOfSec (and divide by 100 to get seconds)
  local ts = date("%H:%M:%S")
  ts = string.format("%s %03d ", ts, (1000 * select(2, math.modf(GetTime() / 10)) + 0.5))
  table.insert(dynamicBoxerSaved.debugLog, ts .. what)
end

DB.sentMessageCount = 0

function DB:SendDirectMessage(to, payload)
  DB.sentMessageCount = DB.sentMessageCount + 1
  DB:DebugLogWrite("To : " .. to .. " : " .. payload)
  local secureMessage, messageId = DB:CreateSecureMessage(payload, DB.Channel, DB.Secret)
  local toSend = DB.whisperPrefix .. secureMessage
  -- must stay under 255 bytes, we are around 96 bytes atm (depends on character name (accentuated characters count double)
  -- and realm length, the hash alone is 16 bytes)
  DB:Debug("About to send message #% id % to % len % msg=%", DB.sentMessageCount, messageId, to, #toSend, toSend)
  -- local ret = C_ChatInfo.SendAddonMessage(DB.chatPrefix, secureMessage, "WHISPER", DB.MasterName) -- doesn't work cross realm
  SendChatMessage(toSend, "WHISPER", nil, to) -- returns nothing even if successful (!)
  -- We would need to watch (asynchronously, for how long ?) for CHAT_MSG_WHISPER_INFORM for success or CHAT_MSG_SYSTEM for errors
  -- instead we'll expect to get a reply from the master and if we don't then we'll try another/not have mapping
  -- use the signature as message id, put it in our LRU for queue of msg waiting ack
  return messageId
end

function DB:InfoPayload(slot, firstFlag)
  local toonInfo = DB.Team[slot]
  local payload = tostring(slot) .. " " .. toonInfo.fullName .. " " .. toonInfo.orig .. " " .. firstFlag .. " msg " ..
                    tostring(DB.syncNum) .. "/" .. tostring(DB.sentMessageCount)
  DB:Debug("Created payload for slot %: %", slot, payload)
  return payload
end

-- the first time, ie after /reload - we will force a resync
DB.firstMsg = 1
DB.syncNum = 1

function DB.Sync() -- called as ticker so no :
  DB:Debug(9, "DB:Sync #% maxIter %", DB.syncNum, DB.maxIter)
  if DB.maxIter <= 0 or not DB:IsActive() then
    return
  end
  if not DB.channelId then
    DB:DynamicInit()
  end
  if not DB.channelId then
    return -- for now keep trying until we get a channel
  end
  DB.maxIter = DB.maxIter - 1
  DB:Debug("Sync #% called for slot % our fullname is %, maxIter is now %", DB.syncNum, DB.ISBIndex, DB.fullName,
           DB.maxIter)
  DB.syncNum = DB.syncNum + 1
  if not DB.ISBIndex then
    DB:Debug("We don't know our slot/actual yet")
    return
  end
  local payload = DB:InfoPayload(DB.ISBIndex, DB.firstMsg, DB.syncNum)
  -- redundant check but we can (and used to) have WeAreMaster true because of slot1/index
  -- and SameRealmAsMaster false because the master realm came from a previous token
  -- no point in resending if we are team complete (and not asked to resync)
  if not (DB:WeAreMaster() or DB:SameRealmAsMaster()) and ((DB.currentCount < DB.expectedCount) or DB.firstMsg == 1) then
    -- if we did just send a message we should wait next iteration
    local now = GetTime() -- higher rez than seconds
    if DB.lastDirectMessage and (now <= DB.lastDirectMessage + DB.refresh) then
      DB:Debug("Will postpone pinging master because we received a msg recently")
      DB.maxIter = DB.maxIter + 1
    else
      DB:Debug("Cross realm sync and team incomplete, pinging master %", DB.MasterName)
      DB:SendDirectMessage(DB.MasterName, payload)
      if DB.firstMsg == 1 and DB.maxIter <= 0 then
        DB:Debug("Cross realm sync, first time, increasing msg sync to 2 more")
        -- we have to sync twice to complete the team (if all goes well)
        DB.maxIter = 2 -- give it an extra attempt in case 1 slave is slow
      end
    end
  end
  local ret = C_ChatInfo.SendAddonMessage(DB.chatPrefix, payload, "CHANNEL", DB.channelId)
  DB:Debug("Channel Message send retcode is % on chanId %", ret, DB.channelId)
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

function DB:AddMaster(masterName)
  DB.masterHistory:add(DB.faction .. " " .. masterName)
  dynamicBoxerSaved.serializedMasterHistory = DB.masterHistory:toTable()
  self:Debug(1, "New master % list newest at the end: %", masterName, dynamicBoxerSaved.serializedMasterHistory)
end

-- Deal with issue#10 by sorting by inverse of length, to replace most specific first (step 1/2)

function DB:SortTeam()
  local presentCount = 0
  self.SortedTeam = {}
  self.TeamIdxByName = {}
  -- remove holes before sorting (otherwise it doesn't work in a way that is usuable, big gotcha)
  for _, v in pairs(self.Team) do
    if v then
      table.insert(self.SortedTeam, v)
      presentCount = presentCount + 1
      -- while at it create/maintains the reverse mapping name->index
      DB:Debug("v is %, v.fullName %", v, v.fullName)
      self.TeamIdxByName[v.fullName] = v.slot
    end
  end
  table.sort(self.SortedTeam, function(a, b)
    return #a.orig > #b.orig
  end)
  self:Debug(1, "Team map (sorted by longest orig name first) is now % - size %; reverse index is %", self.SortedTeam,
             presentCount, self.TeamIdxByName)
  return presentCount
end

DB.Team = {}
-- Too bad addon message don't work cross realm even through whisper
-- (and yet they work with BN friends BUT they don't work with yourself!)
-- TODO: refactor, this is too long / complicated for 1 function
function DB:ProcessMessage(source, from, data)
  local doForward = nil
  local channelMessage = (source == "CHANNEL")
  if not channelMessage then
    -- check authenticity (channel sends unsigned messages)
    local msg, lag, msgId = DB:VerifySecureMessage(data, DB.Channel, DB.Secret)
    if msg then
      DB:Debug(2, "Received valid secure message from % lag is %s, msg id is % part of full message %", from, lag,
               msgId, data)
      DB:DebugLogWrite("Frm: " .. from .. " : " .. msg .. " (lag " .. tostring(lag) .. ")")
      DB.lastDirectMessage = GetTime()
      if DB:WeAreMaster() then
        doForward = msg
      end
    else
      DB:Warning("Received invalid message from %: %", from, data)
      return
    end
    data = msg
  end
  local idxStr, realname, internalname, forceStr = data:match("^([^ ]+) ([^ ]+) ([^ ]+) ([^ ]+)") -- or strplit(" ", data)
  DB:Debug("on % from %, got idx=% realname=% internal name=% first/force=%", source, from, idxStr, realname,
           internalname, forceStr)
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
  if from ~= realname then
    -- Since 1.4 and secure message support allow relay/another toon to set other slots it knows
    DB:Debug("Fwded message from % about % (source is %)", from, realname, source)
  end
  if doForward then -- we are master when we are forwarding
    -- check for loops/sanity; that the data is really only about their slot
    if idx == 1 then
      if realname == DB.fullName then
        DB:Warning("Forwarding loop detected, dropping message from % about ourselves", from)
        return
      end
      DB:Error("Mis configuration, % sent a message that this % and % are master/have slot1!", from, DB.fullName,
               realname)
      return
    end
    -- TODO: count how many msg we sent to who so we don't get tricked (or bugged) into flood
    local ret = C_ChatInfo.SendAddonMessage(DB.chatPrefix, doForward, "CHANNEL", DB.channelId)
    DB:Debug("Channel Message FWD retcode is % on chanId %", ret, DB.channelId)
    -- We need to reply with our info (todo: ack the actual token/message id)
    -- TODO: schedule a sync when we have the full team
    local count = 0
    for k, _ in pairs(DB.Team) do
      local payload = DB:InfoPayload(k, 0, DB.sentMessageCount)
      -- skip our idx (unless force/first) and theirs
      if (k == 1 and force == 1) or (k ~= 1 and k ~= idx) then
        DB:SendDirectMessage(from, payload)
        count = count + 1
      end
    end
    DB:Debug("P2P Send % / % slots back to %", count, DB.expectedCount, from)
  end
  local shortName = realname
  local s, r = DB:SplitFullname(realname)
  if r == DB.myRealm then
    DB:Debug(3, "% is on our realm so using %", realname, s)
    shortName = s -- use the short name without realm when on same realm, using full name breaks (!)
  end
  -- we should do that after we joined our channel to get a chance to get completion
  if channelMessage and DB.newTeam and DB:WeAreMaster() and (DB.currentCount < DB.expectedCount) then
    DB:Debug(1, "New team detected, on master, showing current token")
    DB:ShowTokenUI()
  end
  if idx == DB.ISBIndex then
    DB:Debug("% message, about us, from % (real name claim is %)", source, from, realname)
    if realname ~= DB.fullName then
      DB:Warning("Bug? misconfig ? got a % message from % for our slot % with name % instead of ours (%)", source, from,
                 idx, realname, DB.fullName)
    end
    return
  end
  -- we returned already/ignoring self forwarded message with force=1
  if force == 1 then
    DB:Debug("Got a reload/first from peer % while our maxIter is %", idx, DB.maxIter)
    if DB.maxIter <= 0 then
      DB.maxIter = 1 -- resend at next round
    end
  end
  local previousMapping = nil -- is this a new slot info or a changed slot
  if DB.Team[idx] then
    previousMapping = DB.Team[idx]
    if previousMapping.fullName == realname then
      DB:Debug("Already known mapping, skipping % % (%)", idx, shortName, realname)
      return
    end
    DB:Debug("Change of character received for slot %: was % -> now %", idx, previousMapping.fullName, realname)
  end
  DB.Team[idx] = {orig = internalname, new = shortName, fullName = realname, slot = idx}
  if EMAApi then
    EMAApi.AddMember(realname)
  end
  local oldCount = DB.currentCount
  DB.currentCount = DB:SortTeam()
  local teamComplete = (DB.currentCount >= DB.expectedCount and DB.currentCount ~= oldCount)
  -- if team is complete, hide the show button
  if DB.newTeam and DB:WeAreMaster() and teamComplete then
    DB:Debug(1, "Team complete, hiding current token dialog")
    DB:HideTokenUI()
  end
  isboxer.NextButton = 1 -- reset the buttons
  -- call normal LoadBinds (with output/warning hooked). TODO: maybe wait/batch/don't do it 5 times in small amount of time
  self.ISBO.LoadBinds()
  if previousMapping then
    DB:Print(DB:format("Change of mapping for slot %, dynamically set ISBoxer character to % (%, was % before)", idx,
                       shortName, realname, previousMapping.fullName), 0, 1, 1)
  else
    DB:Print(DB:format("New mapping for slot %, dynamically set ISBoxer character to % (%)", idx, shortName, realname),
             0, 1, 1)
  end
  if idx == 1 then
    DB:AddMaster(realname)
  end
  if teamComplete then
    DB:Print(DB:format("This completes the team of %, get multiboxing and thank you for using DynamicBoxer!",
                       DB.currentCount), 0, 1, 1)
  end
  -- lastly once we have the full team (and if it changes later), set the EMA team to match the slot order, if EMA is present:
  if DB.currentCount == DB.expectedCount and DB.EMA then
    -- why is there an extra level of table? - adapted from FullTeamList in Core/Team.lua of EMA
    for name, info in pairs(DB.EMA.db.newTeamList) do
      local i = DB.TeamIdxByName[name]
      if i then
        -- set correct order
        info[1].order = i
      else
        -- remove toons not in our list
        DB:Debug("Removing % (%) from EMA team", name, info)
        DB.EMA.db.newTeamList[name] = nil
      end
    end
    -- kinda hard to find what is needed minimally to get the ema list to refresh in the order set above
    -- it might be DisplayGroupsForCharacterInGroupsList but that's not exposed
    -- neither SettingsTeamListScrollRefresh nor SettingsRefresh() work...
    DB.EMA:SendMessage(DB.EMA.MESSAGE_TEAM_ORDER_CHANGED)
    DB:Debug(1, "Ema team fully set.")
  end
end

function DB:ChatAddonMsg(event, prefix, data, channel, sender, zoneChannelID, localID, name, instanceID)
  DB:Debug(7, "OnChatEvent called for % e=% channel=% p=% data=% from % z=%, lid=%, name=%, instance=%", self:GetName(),
           event, channel, prefix, data, sender, zoneChannelID, localID, name, instanceID)
  if prefix == DB.chatPrefix and ((channel == "CHANNEL" and instanceID == DB.joinedChannel) or channel == "WHISPER") then
    DB:ProcessMessage(channel, sender, data)
    return
  end
  DB:Debug(9, "wrong prefix % or channel % or instance % vs %, skipping!", prefix, channel, instanceID, DB.joinedChannel)
  return -- not our message(s)
end

DB.EventD = {
  CHAT_MSG_ADDON = DB.ChatAddonMsg,

  BN_CHAT_MSG_ADDON = DB.ChatAddonMsg,

  PLAYER_ENTERING_WORLD = function(self, ...)
    self:Debug("OnPlayerEnteringWorld " .. DB:Dump(...))
    if DB.ticker then
      DB.ticker:Cancel() -- cancel previous one to resync timer
    end
    DB.Sync() -- first one at load
    DB.ticker = C_Timer.NewTicker(DB.refresh, DB.Sync) -- and one every refresh
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

  EXECUTE_CHAT_LINE = function(self, ...)
    self:DebugEvCall(2, ...)
  end,

  CLUB_MESSAGE_ADDED = function(self, ...)
    self:DebugEvCall(2, ...)
  end,

  CHAT_MSG_WHISPER = function(self, ...)
    self:DebugEvCall(2, ...)
  end,

  CHAT_MSG_COMMUNITIES_CHANNEL = function(self, ...)
    self:DebugEvCall(2, ...)
  end,

  CLUB_MESSAGE_HISTORY_RECEIVED = function(self, ...)
    self:DebugEvCall(2, ...)
  end,

  CHAT_MSG_BN_WHISPER_INFORM = function(self, ...)
    self:DebugEvCall(2, ...)
  end,

  CHAT_MSG_BN_WHISPER = function(self, ...)
    self:DebugEvCall(2, ...)
  end,

  ADDON_LOADED = function(self, _event, name)
    self:Debug(9, "Addon % loaded", name)
    if name ~= addon then
      return -- not us, return
    end
    DB:Print("DynamicBoxer " .. DB.manifestVersion .. " by MooreaTv: type /dbox for command list/help.")
    if dynamicBoxerSaved then
      -- always clear the one time log
      dynamicBoxerSaved.debugLog = {}
      if not dynamicBoxerSaved.configVersion or dynamicBoxerSaved.configVersion ~= DB.configVersion then
        -- Support conversion from 1 to 2 etc...
        DB:Error(
          "Invalid/unexpected config version (%, we expect %), sorry conversion not available, starting from scratch!",
          dynamicBoxerSaved.configVersion, DB.configVersion)
      else
        local valid, masterName, tok1, tok2 -- start nil
        if not dynamicBoxerSaved.MasterToken or #dynamicBoxerSaved.MasterToken == 0 then
          -- allow nil/unset master token
          DB:Warning("Token isn't set yet...")
          dynamicBoxerSaved.MasterToken = nil -- normalize to nil for next if
        else
          valid, masterName, tok1, tok2 = DB:ParseToken(dynamicBoxerSaved.MasterToken)
        end
        if dynamicBoxerSaved.MasterToken and not valid then
          DB:Error("Master token % is invalid, resetting...", dynamicBoxerSaved.MasterToken)
        else
          DB:deepmerge(DB, nil, dynamicBoxerSaved)
          DB.MasterName = masterName
          DB.Channel = tok1
          DB.Secret = tok2
          -- restore LRU.
          DB.masterHistory:fromTable(dynamicBoxerSaved.serializedMasterHistory)
          self:Debug(3, "Loaded valid saved vars %", dynamicBoxerSaved)
          return
        end
      end
    end
    -- (re)Init saved vars
    self:Debug("Initialized empty saved vars")
    dynamicBoxerSaved = {}
    dynamicBoxerSaved.configVersion = DB.configVersion
    dynamicBoxerSaved.debugLog = {}
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

function DB:DynamicInit()
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
    DB:ForceInit()
    return -- Join will be called at the positive end of the dialog
  end
  DB:Join()
end

DB.joinDone = false -- because we reschedule the join from multiple place, lets do that only once

-- note: 2 sources of retry, the dynamic init and
function DB:Join()
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
  DB.firstMsg = 1
  if DB.maxIter <= 0 then
    DB.maxIter = 1
  end
  DB:ReconstructTeam()
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
  DB:Print(DB:format("Joined DynBoxer secure channel. This is slot % and dynamically setting ISBoxer character to %",
                     DB.ISBIndex, DB.fullName), 0, 1, 1)
  return DB.channelId
end

function DB:Help(msg)
  DB:Print("DynamicBoxer: " .. msg .. "\n" .. "/dbox init -- redo the one time channel/secret setup UI\n" ..
             "/dbox show -- shows the current token string.\n" ..
             "/dbox set tokenstring -- sets the token string (but using the UI is better)\n" ..
             "/dbox m -- send mapping again\n" .. "/dbox join -- (re)join channel.\n" ..
             "/dbox debug on/off/level -- for debugging on at level or off.\n" ..
             "/dbox reset team||token||all -- resets team or token or all, respectively\n" ..
             "/dbox version -- shows addon version")
end

function DB:SetSaved(name, value)
  self[name] = value
  dynamicBoxerSaved[name] = value
  DB:Debug("(Saved) Setting % set to % - dynamicBoxerSaved=%", name, value, dynamicBoxerSaved)
end

function DB:SetupChange()
  -- re do initialization
  if DB.joinedChannel then
    DB:Debug("Re-init requested, leaving %: %", DB.joinedChannel, LeaveChannelByName(DB.joinedChannel))
    DB.enabled = false
    DB.joinedChannel = nil
    DB.channelId = nil
    DB.joinDone = false
  end
end

function DB:ForceInit()
  DB:SetupChange()
  DB.fullName = DB:GetMyFQN() -- usually set in reconstruct team but we can call /dbox i for testing without isboxer on
  DB:SetupUI()
end

function DB.Slash(arg) -- can't be a : because used directly as slash command
  if #arg == 0 then
    DB:Help("commands")
    return
  end
  DB:Debug("Got slash cmd: %", arg)
  local cmd = string.lower(string.sub(arg, 1, 1))
  local posRest = string.find(arg, " ")
  local rest = ""
  if not (posRest == nil) then
    rest = string.sub(arg, posRest + 1)
  end
  if cmd == "j" then
    -- join
    DB.joinDone = false -- force rejoin code
    DB:Join()
  elseif cmd == "v" then
    -- version
    DB:Print("DynamicBoxer " .. DB.manifestVersion .. " by MooreaTv")
  elseif cmd == "i" then
    -- re do initialization
    DB:ForceInit()
  elseif DB:StartsWith(arg, "reset") then
    -- require reset to be spelled out (other r* are the random gen)
    if rest == "team" then
      dynamicBoxerSaved.teamHistory = {}
      DB:Warning("Team history reset per request (next login will popup the token window until team is complete)")
    elseif rest == "token" then
      dynamicBoxerSaved.MasterToken = nil
      DB:Warning("Token cleared per request, will prompt for it at next login")
    elseif rest == "all" then
      dynamicBoxerSaved = nil -- any subsequent DB:SetSaved will fail...
      DB:Warning("State all reset per request, please /reload !")
      -- C_UI.Reload() -- in theory we could reload for them but that seems bad form
    else
      DB:Error("Use /dbox reset x -- where x is one of team, token, all")
    end
  elseif cmd == "r" then
    -- random id generator (misc bonus util)
    DB:RandomGeneratorUI()
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
        DB:AddMaster(masterName)
        DB:SetupChange()
        DB.enabled = true
        DB:Join()
        return
      end
    end
    -- if above didn't match, failed/didn't return, then fall back to showing UI
    DB:ShowTokenUI()
    -- for debug, needs exact match (of start of "debug ..."):
  elseif DB:StartsWith(arg, "debug") then
    -- debug
    if rest == "on" then
      DB:SetSaved("debug", 1)
    elseif rest == "off" then
      DB:SetSaved("debug", nil)
    else
      DB:SetSaved("debug", tonumber(rest))
    end
    DB:Print(DB:format("DynBoxer debug now %", DB.debug))
  elseif cmd == "d" then
    -- dump
    DB:Print(DB:format("DynBoxer dump of % = " .. DB:Dump(_G[rest]), rest), .7, .7, .9)
  else
    DB:Help('unknown command "' .. arg .. '", usage:')
  end
end

SlashCmdList["DynamicBoxer_Slash_Command"] = DB.Slash

SLASH_DynamicBoxer_Slash_Command1 = "/dbox"
SLASH_DynamicBoxer_Slash_Command2 = "/dynamicboxer"

DB:SetScript("OnEvent", DB.OnEvent)
for k, _ in pairs(DB.EventD) do
  DB:RegisterEvent(k)
end

-- DB.debug = 2
DB:Debug("dbox main file loaded")
