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
local addon, _ns = ...

-- Created by DBoxInit
local DB = DynBoxer
local L = DB.L

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

DB.masterHistory = {}
DB.memberHistory = {}
for _, faction in ipairs(DB.Factions) do
  DB.masterHistory[faction] = DB:LRU(50)
  DB.memberHistory[faction] = DB:LRU(200)
end
DB.watched = DB:WatchedTable()

DB.currentCount = 0 -- how many characters from the team have been mapped (ie size of sorted team)
DB.expectedCount = 0 -- how many slots we expect to see/map

-- to force all debugging on even before saved vars are loaded
-- DB.debug = 8

DB.maxIter = 1 -- We really only need to send the message once (and resend when seeing join from others, batched)
DB.refresh = 2
DB.totalRetries = 0
DB.maxRetries = 20 -- after 20s we stop/give up

DB.chatPrefix = "dbox1" -- protocol version in prefix for the addon messages
DB.whisperPrefix = "DynamicBoxer~" -- chat prefix in case it goes to wrong toon, to make it clearer what it may be
DB.channelId = nil
DB.watched.enabled = true -- set to false if the users cancels out of the UI
DB.randomIdLen = 8 -- we generate 8 characters long random ids
DB.tokenMinLen = DB.randomIdLen * 2 + 2 + 4
DB.configVersion = 1 -- bump up to support conversion (and update the ADDON_LOADED handler)

DB.autoInvite = 1 -- so it's discovered/useful by default
DB.autoInviteSlot = 1
DB.autoRaid = true
DB.showIdAtStart = true

DB.manual = 0 -- testing manual mode, 0 is off, number is slot id
-- Set to actual expected size, or we'll start with 2 and extend as we get messages from higher slots
DB.manualTeamSize = 0
-- will be true when we find the isboxer character configured
DB.isboxerTeam = false

DB.EMA = _G.LibStub and _G.LibStub:GetLibrary("AceAddon-3.0", true)
DB.EMA = DB.EMA and DB.EMA:GetAddon("Team", true)

-- Returns if we should be operating (basically if isboxer has a static team defined)
function DB:IsActive()
  if self.watched.enabled and (isboxer.Character_LoadBinds or self.manual > 0) then
    return true -- so we don't return the LoadBinds function
  end
  return false
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
    if n then
      local c
      self:Debug(9, "#%: for s=% i=% -> n=% (o=%)", k, s, v.slotStr, n, o)
      macro, c = DB:ReplaceAll(macro, v.slotStr, n)
      count = count + c
    else
      self:Warning("Trying to replace slot #% with nil name!", k)
    end
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
  -- save the name
  if not DB.originalSlotName then
    DB.originalSlotName = isboxer.Character and isboxer.Character.ActualName
  end
  DB:ReconstructTeam()
  -- Avoid the mismatch complaint:
  isboxer.Character.ActualName = GetUnitName("player")
  isboxer.Character.QualifiedName = DB.fullName
  DB.ISBO.LoadBinds()
  DB.isboxeroutput = false -- only warn/output once
end

function DB.ISBH.SetMacro(username, key, macro, ...)
  DB:Debug(9, "Hooked SetMacro(%, %, %, %)", username, key, macro, DB:Dump(...))
  if DB.watched.enabled then
    macro = DB:Replace(macro)
  else
    DB:Debug("Skipping macro replace as we are not enabled...")
  end
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

-- short name -> fullname
function DB:NormalizeName(name)
  if name:match("(.+)-(.+)") then
    return name -- already has - so good to go
  else
    return name .. "-" .. DB.myRealm
  end
end
-- name -> shortest working name
function DB:ShortName(name)
  local s, r = DB:SplitFullname(name)
  if r == DB.myRealm then
    DB:Debug(4, "% is on our realm, using %", name, s)
    return s
  end
  return name
end

-- Potentially grow the manual team size (called with received idx which may be bigger than the default manual team size of 2)
function DB:ManualExtendTeam(oldSize, newSize)
  DB:Debug("Extending manual team from size % to %, isbt=%", oldSize, newSize, DB.isboxerTeam)
  if newSize <= oldSize then
    return -- nothing to extend
  end
  for i = oldSize + 1, newSize do
    DB.ISBTeam[i] = DB:format("Slot%", i)
  end
  DB.manualTeamSize = newSize
  DB.expectedCount = newSize
  DB:AddTeamStatusUI(DB.statusFrame)
end

function DB:ManualSetup()
  DB:Debug("ManualSetup called with DB.manual=% DB.manualTeamSize=%", DB.manual, DB.manualTeamSize)
  if not DB.manual or DB.manual < 1 then
    return
  end
  if DB.manualTeamSize == 0 then
    DB.manualTeamSize = math.max(2, DB.manual)
    DB:Debug("Guessing manual team size = %", DB.manualTeamSize)
  end
  DB:Warning("Manual mode, no isboxer binding, simulating slot % / %", DB.manual, DB.manualTeamSize)
  DB.ISBIndex = DB.manual
  DB.watched.slot = DB.ISBIndex
  if DB.manual == 1 then
    DB.MasterName = DB.fullName
  end
  DB:ManualExtendTeam(0, DB.manualTeamSize)
end

-- Reverse engineer what isboxer will hopefully be providing more directly soon
-- (isboxer.CharacterSet.Members isn't always set when making teams without realm)
function DB:ReconstructTeam()
  if DB.ISBTeam then
    DB:Debug(3, "Already know team to be % and my index % (isb members %)", DB.ISBTeam, DB.ISBIndex,
             isboxer.CharacterSet and isboxer.CharacterSet.Members)
    return
  end
  DB.fullName = DB:GetMyFQN()
  DB.faction = UnitFactionGroup("player")
  DB.shortName, DB.myRealm = DB:SplitFullname(DB.fullName)
  if not DB.watched.enabled then
    DB:Warning("Not enabled, not doing any mapping")
    return
  end
  if not DB:IsActive() then
    DB:PrintDefault(
      "DynamicBoxer skipping team reconstruction as there is no isboxer team (not running under innerspace).")
    return
  end
  local searchingFor = DB.originalSlotName or isboxer.Character and isboxer.Character.ActualName
  if not searchingFor or #searchingFor == 0 then
    if DB.manual <= 0 then
      DB:Error("Your isboxer.Character.ActualName is not set. please report your config/setup/how to reproduce.")
      return
    end
    DB:Warning("No isboxer.Character.ActualName but we have manual override for slot %", DB.manual)
  end
  local prev = isboxer.SetMacro
  DB.ISBTeam = {}
  DB.ISBIndex = -1 -- temp value to check for already set/dups/found below
  DB.IsbAssistMacro = "<not found>"
  -- parse the text which looks like (note the ]xxx; delimiters for most but \n at the end)
  -- "/assist [nomod:alt,mod:lshift,nomod:ctrl]FIRST;[nomod:alt,mod:rshift,nomod:ctrl]SECOND;...[nomod:alt...,mod:lctrl]LAST\n""
  isboxer.SetMacro = function(macro, _key, text)
    if macro ~= "FTLAssist" then
      return
    end
    DB.ISBAssistMacro = text
    for x in text:gmatch("%]([^;]+)[;\n]") do
      table.insert(DB.ISBTeam, x)
      if x == searchingFor then
        if DB.ISBIndex > 0 then
          DB:Warning("Duplicate entry for % found in %!", searchingFor, text)
        else
          DB.ISBIndex = #DB.ISBTeam
          DB.watched.slot = DB.ISBIndex
        end
      end
    end
  end
  if isboxer.Character_LoadBinds then
    isboxer.Character_LoadBinds()
    DB.isboxerTeam = true
  else
    DB.isboxerTeam = false
    DB:ManualSetup()
  end
  isboxer.SetMacro = prev
  if DB.ISBIndex <= 0 then
    DB.ISBIndex = nil -- set if back to unset
    DB:Error("Problem identifying this character isboxer.Character.ActualName=% " ..
               "in the isboxer macro FTLAssist=% - please report this problem/how to reproduce it", searchingFor,
             DB.ISBAssistMacro)
    return
  end
  DB:Debug("Found isbteam to be % and my index % (while isb members is %)", DB.ISBTeam, DB.ISBIndex,
           isboxer.CharacterSet and isboxer.CharacterSet.Members)
  DB.Team[DB.ISBIndex] = {
    orig = DB.ISBTeam[DB.ISBIndex],
    new = DB.shortName,
    fullName = DB.fullName,
    slot = DB.ISBIndex
  }
  DB.watched[DB.ISBIndex] = DB.fullName
  if DB.ISBIndex == 1 then
    DB.MasterName = DB.fullName
  end
  if DB.showIdAtStart then
    C_Timer.After(0.25, function()
      DB:ShowBigInfo(3.5)
    end)
  end
  DB:Debug("Team map initial value = %", DB.Team)
  -- detect team changes, keep unique teams
  local teamStr = table.concat(DB.ISBTeam, " ")
  if not DB.justInit and not DB.teamHistory[teamStr] then
    DB:Debug(
      "New (isboxer) team detected, will show master token for copy paste until team is complete (if this isn't first init).")
    DB.newTeam = true
  end
  DB.teamHistory[teamStr] = GetServerTime()
  dynamicBoxerSaved.teamHistory = DB.teamHistory
  DB.currentCount = DB:SortTeam() -- returns 1
  DB.expectedCount = #DB.ISBTeam
  if DB.expectedCount == DB.currentCount then
    -- basically a team of 1 / solo is already complete (don't pop up master token etc)
    DB:Warning("Solo / Team of % detected. Setup complete.", DB.expectedCount)
    DB.teamComplete = true
  end
  DB:AddTeamStatusUI(DB.statusFrame)
  DB:Debug("Unique team string key is %, updated in history, expecting a team of size #%", teamStr, DB.expectedCount)
  if DB.EMA then
    DB.EMA.db.newTeamList = {}
    EMAApi.AddMember(DB.fullName)
    DB:Debug("Cleared EMA team, set team to %", DB.fullName)
  end
end

DB.crossRealmMaster = nil

function DB:NewestCrossRealmMaster()
  local maxOthers = 10
  for v in DB.masterHistory[DB.faction]:iterateNewest() do
    maxOthers = maxOthers - 1
    if maxOthers <= 0 then
      break
    end
    if not DB:SameRealmAsUs(v) then
      return v
    end
  end
  return ""
end

function DB:CheckMasterFaction()
  if DB:WeAreMaster() then
    DB:Debug(3, "Not checking master history on master slot")
    return false
  end
  if DB.crossRealmMaster then
    DB:Debug(3, "already figured out cross realm master %", DB.crossRealmMaster)
    return true
  end
  DB.crossRealmMaster = "" -- so we don't print stuff again
  local master = DB:NewestCrossRealmMaster()
  if DB:SameRealmAsUs(DB.MasterName) then
    if master then
      DB:Warning("Trying crossrealm master %s from master history as attempt to find our cross realm master", master)
      DB.MasterName = master
      DB.crossRealmMaster = master
      return true
    end
    DB:PrintDefault("All recent masters, and the current token, are from same realm, will not try direct messages.")
    return false
  end
  if DB.masterHistory[DB.faction]:exists(DB.MasterName) then
    DB:PrintDefault("Using previously seen cross realm master token as is.")
    DB.crossRealmMaster = DB.MasterName
    return true
  end
  for _, faction in ipairs(DB.Factions) do
    if DB.masterHistory[faction]:exists(DB.MasterName) then
      DB:Debug(1, "Master % is wrong faction % vs ours %", DB.MasterName, faction, DB.faction)
      if master then
        DB:PrintInfo("Detected other faction (%) master %, will use ours (%) instead: %", faction, DB.MasterName,
                     DB.faction, master)
        DB.MasterName = master
        DB.crossRealmMaster = master
        return true
      end
      DB:Warning("Wrong master faction % and first time in this faction %, please paste the token from slot 1", faction,
                 DB.faction)
      DB:ShowAutoExchangeTokenUI()
      return false
    end
  end
  DB:PrintDefault("Never seen before master %, will try it...", DB.MasterName)
  DB.crossRealmMaster = DB.MasterName
  return true
end

function DB:SameRealmAsUs(fullName)
  local _, r = DB:SplitFullname(fullName)
  return DB.myRealm == r
end

function DB:SameRealmAsMaster()
  local _, r = DB:SplitFullname(DB.MasterName)
  return DB.myRealm == r
end

function DB:WeAreMaster()
  return DB.ISBIndex == 1
end

-- TODO: move to MoLib
function DB:DebugLogWrite(what)
  -- format is HH:MM:SS hundredsOfSec the 2 clock source aren't aligned so for deltas of
  -- 9 seconds or less, substract the 2 hundredsOfSec (and divide by 100 to get seconds)
  local ts = date("%H:%M:%S")
  ts = string.format("%s %03d ", ts, (1000 * select(2, math.modf(GetTime() / 10)) + 0.5))
  table.insert(dynamicBoxerSaved.debugLog, ts .. what)
end

function DB:InPartyWith(name)
  local shortName = DB:ShortName(name)
  local res = UnitInParty(shortName)
  DB:Debug("Checking in party with % -> % : %", name, shortName, res)
  return res
end

DB.sentMessageCount = 0

function DB:SendDirectMessage(to, payload)
  DB.sentMessageCount = DB.sentMessageCount + 1
  if to == DB.fullName then
    local msg = "Trying to send message to ourselves !"
    DB:Error(msg)
    return
  end
  if DB.sentMessageCount > 200 then
    DB:Error("Sent too many messages (loop?) - stopping now")
    return
  end
  local secureMessage, messageId = DB:CreateSecureMessage(payload, DB.Channel, DB.Secret)
  local inParty = DB:InPartyWith(to)
  local inPartyMarker
  if inParty then
    inPartyMarker = "*P*"
  else
    inPartyMarker = "   "
  end
  DB:DebugLogWrite(messageId .. " :   " .. inPartyMarker .. "    To: " .. to .. " : " .. payload)
  local toSend = DB.whisperPrefix .. secureMessage
  -- must stay under 255 bytes, we are around 96 bytes atm (depends on character name (accentuated characters count double)
  -- and realm length, the hash alone is 16 bytes)
  DB:Debug(2, "About to send message #% id % to % len % msg=%", DB.sentMessageCount, messageId, to, #toSend, toSend)
  if inParty then
    local ret = C_ChatInfo.SendAddonMessage(DB.chatPrefix, secureMessage, "RAID")
    DB:Debug("we are in party with %, used party/raid msg, ret=%", to, ret)
    if ret then
      return messageId -- mission accomplished
    end
    DB:Warning("Can't send party/raid addon message #%, reverting to whisper", DB.sentMessageCount)
  end
  SendChatMessage(toSend, "WHISPER", nil, to) -- returns nothing even if successful (!)
  -- We would need to watch (asynchronously, for how long ?) for CHAT_MSG_WHISPER_INFORM for success or CHAT_MSG_SYSTEM for errors
  -- instead we'll expect to get a reply from the master and if we don't then we'll try another/not have mapping
  -- use the signature as message id, put it in our LRU for queue of msg waiting ack
  return messageId
end

function DB:InfoPayload(slot, firstFlag)
  return DB:SlotCommand(slot, DB.Team[slot].fullName, firstFlag)
end

function DB:SlotCommand(slot, fullName, firstFlag)
  local payload =
    "S" .. tostring(slot) .. " " .. fullName .. " " .. firstFlag .. " msg " .. tostring(DB.syncNum) .. "/" ..
      tostring(DB.sentMessageCount)
  DB:Debug(3, "Created slot payload for slot %: %", slot, payload)
  return payload
end

-- the first time, ie after /reload - we will force a resync
DB.firstMsg = 1
DB.syncNum = 1

-- TODO: separate / disentangle  channel and direct message sync
function DB.Sync() -- called as ticker so no :
  DB:Debug(9, "DB:Sync #% maxIter %", DB.syncNum, DB.maxIter)
  if DB.maxIter <= 0 or not DB:IsActive() then
    return
  end
  if not DB.channelId then
    DB:DynamicInit()
  end
  if not DB.channelId then
    DB:Debug(8, "We don't have a channel id to do sync #% maxIter %", DB.syncNum, DB.maxIter)
    return -- for now keep trying until we get a channel
  end
  DB.maxIter = DB.maxIter - 1
  DB:Debug("Sync #% called for slot % our fullname is %, maxIter is now % firstMsg=%", DB.syncNum, DB.ISBIndex,
           DB.fullName, DB.maxIter, DB.firstMsg)
  DB.syncNum = DB.syncNum + 1
  if not DB.ISBIndex then
    DB:Debug("We don't know our slot/actual yet")
    return
  end
  local now = GetTime() -- higher rez than seconds
  local payload = DB:InfoPayload(DB.ISBIndex, DB.firstMsg, DB.syncNum)
  -- check the master isn't from another faction
  -- redundant check but we can (and used to) have WeAreMaster true because of slot1/index
  -- and SameRealmAsMaster false because the master realm came from a previous token
  -- no point in resending if we are team complete (and not asked to resync)
  if ((not DB.Team[1]) or DB.firstMsg == 1) and DB:CheckMasterFaction() and #DB.crossRealmMaster > 0 then
    -- if we did just send a message we should wait next iteration
    if DB.lastDirectMessage and (now <= DB.lastDirectMessage + DB.refresh) then
      DB:Debug("Will postpone pinging master because we received a msg recently")
      DB.maxIter = DB.maxIter + 1
    else
      DB:Debug("Cross realm sync and team incomplete/master unknown, pinging master % - %", DB.MasterName, DB.Team[1])
      DB:SendDirectMessage(DB.MasterName, payload)
      if DB.firstMsg == 1 and DB.maxIter <= 0 then
        DB:Debug("Cross realm sync, first time, increasing msg sync to 2 more")
        -- we have to sync twice to complete the team (if all goes well, but it's faster with party invite)
        DB.maxIter = 3 -- give it a couple extra attempts in case 1 slave is slow
      end
      -- on last attempt [TODO: split channel retries from this], also ping some older/previous masters for our faction
      if DB.maxIter == 0 then
        local maxOthers = 3
        local firstPayload = DB:InfoPayload(DB.ISBIndex, 1, DB.syncNum)
        for v in DB.masterHistory[DB.faction]:iterateNewest() do
          DB:Debug("Checking % for next xrealm attempt (mastername %) samerealm %", v, DB.MasterName,
                   DB:SameRealmAsUs(v))
          if not DB:SameRealmAsUs(v) and v ~= DB.MasterName then
            DB:Warning("Also trying %s from master history as attempt to find our cross realm master", v)
            DB:SendDirectMessage(v, firstPayload)
            maxOthers = maxOthers - 1
            if maxOthers <= 0 then
              break
            end
          end
        end
        -- done attempting older masters
      end
    end
  end
  if DB:WeAreMaster() then
    -- slot 1, expect team complete
    if not DB.teamComplete and not DB.inUI then
      local delay = DB.refresh * 3.5
      C_Timer.After(delay, function()
        if DB.teamComplete or DB.inUI then
          DB:Debug("% sec later we have a team complete % or already showing dialog", delay, DB.teamComplete)
          return
        end
        DB:ShowAutoExchangeTokenUI(
          "Showing the master exchange token UI after % sec as we still don't have team complete", delay)
      end)
    end
  else
    -- slot 2...N
    if not DB.Team[1] and not DB.inUI then
      local delay = DB.refresh * 2.5
      C_Timer.After(delay, function()
        if DB.Team[1] or DB.inUI then
          DB:Debug("% sec later we have a master % or already showing dialog", delay, DB.Team[1])
          return
        end
        DB:ShowAutoExchangeTokenUI(
          "Showing the exchange token UI after % sec as we still haven't reached a master (will autohide when found)",
          delay)
      end)
    end
    if DB.maxIter <= 0 and not DB.noMoreExtra and DB.crossRealmMaster and #DB.crossRealmMaster > 0 then
      DB.noMoreExtra = true
      local delay = DB.refresh * 2.5 + DB.ISBIndex
      C_Timer.After(delay, function()
        if DB.teamComplete then
          DB:Debug("% sec later we have a team complete %", delay, DB.teamComplete)
          return
        end
        if DB.lastDirectMessage and (now <= DB.lastDirectMessage + DB.refresh) then
          DB:Debug("Will postpone pinging master because we received a msg recently")
        end
        if DB.Team[1] then
          DB:PrintDefault("Team not yet complete after %s, sending 1 extra re-sync", delay)
          local firstPayload = DB:InfoPayload(DB.ISBIndex, 1, DB.syncNum)
          DB:SendDirectMessage(DB.Team[1].fullName, firstPayload)
        else
          DB:Warning("No team / no master response after % sec, please fix slot 1 and/or paste token", delay)
        end
      end)
    end
  end
  local ret = C_ChatInfo.SendAddonMessage(DB.chatPrefix, payload, "CHANNEL", DB.channelId)
  DB:Debug(2, "Channel Message send retcode is % on chanId %", ret, DB.channelId)
  if ret then
    DB.firstMsg = 0
  else
    DB:Debug("failed to send, will retry % / %", DB.totalRetries, DB.maxRetries)
    DB.totalRetries = DB.totalRetries + 1
    if DB.totalRetries >= DB.maxRetries then
      DB:Error("Giving up sending/syncing after % retries. Use /dbox j to try again later", DB.totalRetries)
      DB.firstMsg = 0
      return
    end
    if DB.totalRetries % 5 == 0 then
      DB:Warning("We tried % times to message the channel, will try rejoining instead", DB.totalRetries)
      DB:SetupChange()
      DB.watched.enabled = true -- must be after the previous line which sets it off
      -- DB:CheckChannelOk(DB:format("from Sync %", DB.totalRetries)) -- not enough to detect/fix it seems
    end
    if DB.maxIter <= 0 then
      DB.maxIter = 1
    end
  end
end

function DB:AddToMasterHistory(masterName)
  DB.masterHistory[DB.faction]:add(masterName)
  if not dynamicBoxerSaved.serializedMasterHistory then
    dynamicBoxerSaved.serializedMasterHistory = {}
  end
  dynamicBoxerSaved.serializedMasterHistory[DB.faction] = DB.masterHistory[DB.faction]:toTable()
  self:Debug(5, "New master % list newest at the end: %", masterName, dynamicBoxerSaved.serializedMasterHistory)
end

function DB:AddToMembersHistory(memberName)
  DB.memberHistory[DB.faction]:add(memberName)
  if not dynamicBoxerSaved.serializedMemberHistory then
    dynamicBoxerSaved.serializedMemberHistory = {}
  end
  dynamicBoxerSaved.serializedMemberHistory[DB.faction] = DB.memberHistory[DB.faction]:toTable()
  self:Debug(5, "New member % list newest at the end: %", memberName, dynamicBoxerSaved.serializedMemberHistory)
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
      DB:Debug(3, "v is %, v.fullName %", v, v.fullName)
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

-- additional message if failed
function DB:CheckChannelOk(msg)
  if not DB.joinedChannel or #DB.joinedChannel < 1 then
    DB:Warning("We haven't calculated the channel yet, will retry (" .. msg .. ")")
    return false
  end
  DB.channelId = GetChannelName(DB.joinedChannel)
  if not DB.channelId then
    DB:Warning("Couldn't get channel id for our channel %, will retry (" .. msg .. ")", DB.joinedChannel)
    return false
  end
  return true
end

DB.Team = {} -- TODO: save the team for caching/less waste upon reload (and/or check party/raid chat)

DB.duplicateMsg = DB:LRU(100)

DB.numInvites = 1
DB.needRaid = false

-- raid logic is kinda ugly and too tricky - refactor?

function DB:Invite(fullName, rescheduled)
  local num = GetNumGroupMembers(LE_PARTY_CATEGORY_HOME) -- this lags/doesn't include not yet accepted invites
  local inRaid = IsInRaid(LE_PARTY_CATEGORY_HOME)
  DB:Debug("Currently % in party/raid, in raid is %, oustanding/done invites %", num, inRaid, DB.numInvites)
  if DB.numInvites == 5 then -- add and not already in raid
    if not DB.autoRaid then
      if not inRaid then
        DB:Warning("Set Auto raid on to avoid upcoming Party full error")
      end
    elseif not inRaid then
      if not rescheduled then
        DB:PrintDefault("Auto converting to raid because we have 5 outstanding invites already")
        ConvertToRaid()
      end
      -- retest in case conversion to raid just worked
      if not IsInRaid(LE_PARTY_CATEGORY_HOME) then
        DB:Debug("Not yet in raid, rescheduling the invite...")
        DB.needRaid = true
        C_Timer.After(0.2, function()
          DB:Invite(fullName, true)
        end)
        return
      end
    end
  end
  DB.numInvites = DB.numInvites + 1
  InviteUnit(fullName)
end

function DB:PartyToggle()
  if IsInRaid(LE_PARTY_CATEGORY_HOME) then
    DB:PrintDefault("Switching to party (if possible)...")
    ConvertToParty()
  else
    DB:PrintDefault("Switching to raid...")
    ConvertToRaid()
  end
end

function DB:PartyInvite(continueFrom)
  DB.numInvites = math.max(1, GetNumGroupMembers(LE_PARTY_CATEGORY_HOME))
  local pauseBetweenPartyAndRaid = false
  if DB.numInvites == 1 then
    -- we don't even have a party yet, so we can't make a raid so we'll stop at 5 and reschedule
    pauseBetweenPartyAndRaid = true
  end
  if IsInRaid(LE_PARTY_CATEGORY_HOME) then
    pauseBetweenPartyAndRaid = false
  end
  continueFrom = continueFrom or 0
  for k, v in pairs(DB.Team) do
    DB:Debug(9, "k is %, v is %", k, v)
    assert(k == v.slot)
    if k < continueFrom then
      DB:Debug("skipping % as we are continuing from %", k, continueFrom)
    elseif k == DB.ISBIndex then
      DB:Debug("Slot %: is us, not inviting ourselves.", k)
    elseif UnitInParty(v.new) then
      DB:Debug("Slot %: % is already in our party/raid, won't re invite", k, v.fullName)
    else
      if DB.autoRaid and pauseBetweenPartyAndRaid and k >= 6 then
        DB:PrintDefault("Small pause between party to raid transition...")
        DB.needRaid = true
        C_Timer.After(0.5, function()
          DB:PartyInvite(k)
        end)
        return
      end
      DB:PrintDefault("Inviting #%: %", k, v.fullName)
      DB:Invite(v.fullName)
    end
  end
end

-- this actually either uninvite the team members (and maybe leaves guests and lead)
-- or leaves the party if not leader.
function DB:Disband()
  DB.needRaid = false
  if UnitIsGroupLeader("player") then
    DB:Debug("We are party leader, uninvite everyone from the team")
    for k, v in pairs(DB.Team) do
      if k == DB.ISBIndex then
        DB:Debug("Slot %: is us, not uninviting ourselves.", k)
      elseif UnitInParty(v.new) then -- need to check using the shortname
        DB:PrintDefault("Uninviting #%: %", k, v.fullName)
        UninviteUnit(v.new) -- also need to be shortname
        DB.numInvites = DB.numInvites - 1
      else
        DB:Debug("Slot %: % is already not in our party/raid, won't uninvite", k, v.fullName)
      end
    end
  else
    -- just leave
    DB:PrintDefault(L["Disband requested, we aren't party leader so we're just leaving"])
    LeaveParty()
  end
end

-- Too bad addon messages don't work cross realm even through whisper
-- (and yet they work with BN friends BUT they don't work with yourself!)
-- TODO: refactor, this is too long / complicated for 1 function
function DB:ProcessMessage(source, from, data)
  if not DB.ISBTeam then
    DB:ReconstructTeam() -- we can get messages events before the normal reconstruct team flow
  end
  local doForward = nil
  local channelMessage = (source == "CHANNEL")
  local directMessage = (source == "WHISPER" or source == "CHAT_FILTER")
  if from == DB.fullName then
    DB:Debug(2, "Skipping our own message on %: %", source, data)
    return
  end
  if not channelMessage then
    -- check authenticity (channel sends unsigned messages)
    local valid, msg, lag, msgId = DB:VerifySecureMessage(data, DB.Channel, DB.Secret)
    if valid then
      DB:Debug(2, "Received valid secure direct=% message from % lag is %s, msg id is % part of full message %",
               directMessage, from, lag, msgId, data)
      local isDup = false
      if DB.duplicateMsg:exists(msgId) then
        DB:Warning("!!!Received % duplicate msg from %, will ignore: %", source, from, data)
        isDup = true
      end
      DB.duplicateMsg:add(msgId)
      DB.lastDirectMessage = GetTime()
      if isDup then
        DB:DebugLogWrite(msgId .. " : From: " .. from .. "  DUP : " .. msg .. " (lag " .. tostring(lag) .. ")")
        return
      else
        DB:DebugLogWrite(msgId .. " : From: " .. from .. "      : " .. msg .. " (lag " .. tostring(lag) .. ")")
      end
      if DB:WeAreMaster() then
        doForward = msg
      end
    else
      DB:Warning("Received invalid (" .. msg .. ") message from %: %", from, data)
      return
    end
    data = msg
  end
  local idxStr, realname, forceStr = data:match("^S([^ ]+) ([^ ]+) ([^ ]+)") -- or strplit(" ", data)
  DB:Debug("on % from %, got idx=% realname=% first/force=%", source, from, idxStr, realname, forceStr)
  local idx = tonumber(idxStr)
  if not idx then
    DB:Error("invalid non numerical idx %", idxStr)
    return
  end
  if idx <= 0 then
    DB:Error("Received invalid slot # on % from % in payload %", source, from, data)
    return
  end
  local force = tonumber(forceStr)
  if not force then
    DB:Error("invalid non numerical first/force flag %", forceStr)
    return
  end
  if from ~= realname then
    -- Since 1.4 and secure message support allow relay/another toon to set other slots it knows
    DB:Debug(3, "Fwded message from % about % (source is %)", from, realname, source)
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
    -- TODO: we count direct messages now but maybe also count channel messages to detect possible loop/dup msg issues
    if DB:CheckChannelOk("Msg Fwd") then
      local payload = DB:SlotCommand(idx, realname, 0) -- drop/patch the force flag out
      local ret = C_ChatInfo.SendAddonMessage(DB.chatPrefix, payload, "CHANNEL", DB.channelId)
      DB:Debug(2, "Channel Message FWD retcode is % on chanId %", ret, DB.channelId)
      if not ret then
        DB:Debug(1, "FAILED to send % long FWD for % (% -> %)", #payload, DB.channelId, doForward, payload)
      end
    end
    -- We need to reply with our info (todo: ack the actual token/message id)
    -- TODO: schedule a sync when we have the full team
    local count = 0
    for k, _ in pairs(DB.Team) do
      local payload = DB:InfoPayload(k, 0, DB.sentMessageCount)
      -- skip our idx (unless force/first) and theirs
      if force == 1 or (k ~= 1 and k ~= idx) then -- TODO: only send "themselves" on party channel
        DB:SendDirectMessage(from, payload)
        count = count + 1
      end
    end
    DB:Debug("P2P Send % / % slots back to %", count, DB.expectedCount, from)
  end
  local shortName = DB:ShortName(realname)
  -- we should do that after we joined our channel to get a chance to get completion
  if channelMessage and DB.newTeam and (not DB.justInit) and DB:WeAreMaster() and (DB.currentCount < DB.expectedCount) then
    DB:Warning("New (isboxer) team detected, on master, showing current token")
    DB:ShowAutoExchangeTokenUI()
  end
  if idx == DB.ISBIndex then
    DB:Debug(3, "% message, about us, from % (real name claim is %)", source, from, realname)
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
  if not DB.isboxerTeam and DB.manual > 0 then
    DB:ManualExtendTeam(DB.manualTeamSize, idx)
  end
  DB.Team[idx] = {orig = DB.ISBTeam[idx], new = shortName, fullName = realname, slot = idx}
  if DB.autoInvite and DB.autoInviteSlot == DB.ISBIndex and idx ~= DB.ISBIndex then
    -- This check works for in raid too but must be short name
    if UnitInParty(shortName) then
      DB:Debug("Slot %: % is already in our party/raid, won't re invite", idx, realname)
    else
      DB:PrintDefault("Auto invite is on for our slot, inviting #%: % (turn off/configure in /dbox config if desired)",
                      idx, realname)
      DB:Invite(realname)
    end
  else
    DB:Debug("Slot % not inviting slot % - auto inv slot is %, auto invite is %", DB.ISBIndex, idx, DB.autoInviteSlot,
             DB.autoInvite)
  end
  if EMAApi then
    DB:Debug(">>>Calling ema AddMember %", realname)
    EMAApi.AddMember(realname)
  end
  local oldCount = DB.currentCount
  DB.currentCount = DB:SortTeam()
  local teamComplete = (DB.currentCount >= DB.expectedCount and DB.currentCount ~= oldCount)
  -- if team is complete, hide the show button
  if teamComplete then
    DB:Debug(1, "Team complete, hiding current token dialog")
    DB:HideTokenUI()
  end
  isboxer.NextButton = 1 -- reset the buttons
  -- call normal LoadBinds (with output/warning hooked). TODO: maybe wait/batch/don't do it 5 times in small amount of time
  if DB.isboxerTeam then
    self.ISBO.LoadBinds()
  end
  if previousMapping then
    DB:PrintInfo("Change of mapping for slot %, dynamically set ISBoxer character to % (%, was % before)", idx,
                 shortName, realname, previousMapping.fullName)
  else
    DB:PrintInfo("New mapping for slot %, dynamically set ISBoxer character to % (%)", idx, shortName, realname)
  end
  DB.watched[idx] = realname
  if idx == 1 then
    DB:AddToMasterHistory(realname)
    DB:Debug(1, "Master found, hiding current token dialog")
    DB:HideTokenUI()
  else
    DB:AddToMembersHistory(realname)
  end
  if teamComplete then
    DB:TeamIsComplete() -- will also do EMASync so we can return here
    return
  end
  -- lastly once we have the full team (and if it changes later), set the EMA team to match the slot order, if EMA is present:
  if DB.currentCount == DB.expectedCount then
    DB:EMASync()
  end
end

function DB:TeamIsComplete()
  DB:PrintInfo("This completes the team of %, get multiboxing and thank you for using DynamicBoxer!", DB.currentCount)
  DB.sentMessageCount = 0
  DB.needRaid = false
  DB.teamComplete = true
  DB:HideTokenUI()
  DB:EMAsync()
end

function DB:EMAsync()
  if not DB.EMA then
    DB:Debug("No EMA present, not syncing")
    return
  end
  -- why is there an extra level of table? - adapted from FullTeamList in Core/Team.lua of EMA
  for name, info in pairs(DB.EMA.db.newTeamList) do
    local i = DB.TeamIdxByName[name]
    if i then
      -- set correct order
      info[1].order = i
    else
      -- remove toons not in our list
      DB:Debug(">>> Removing % (%) from EMA team", name, info)
      DB.EMA.db.newTeamList[name] = nil
    end
  end
  DB.EMA.db.master = DB.Team[1].fullName -- set the master too
  DB:Debug("Set ema master to %", DB.EMA.db.master)
  -- kinda hard to find what is needed minimally to get the ema list to refresh in the order set above
  -- it might be DisplayGroupsForCharacterInGroupsList but that's not exposed
  -- neither SettingsTeamListScrollRefresh nor SettingsRefresh() work...
  DB.EMA:SendMessage(DB.EMA.MESSAGE_TEAM_ORDER_CHANGED)
  DB:Debug(1, "Ema team fully set.")
end

function DB:ChatAddonMsg(event, prefix, data, channel, sender, zoneChannelID, localID, name, instanceID)
  DB:Debug(7, "OnChatEvent called for % e=% channel=% p=% data=% from % z=%, lid=%, name=%, instance=%", self:GetName(),
           event, channel, prefix, data, sender, zoneChannelID, localID, name, instanceID)
  if prefix == DB.chatPrefix and
    ((channel == "CHANNEL" and instanceID == DB.joinedChannel) or channel == "WHISPER" or channel == "PARTY") then
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
    DB:SetupStatusUI()
    if DB.ticker then
      DB.ticker:Cancel() -- cancel previous one to resync timer
    end
    DB.Sync() -- first one at load
    DB.ticker = C_Timer.NewTicker(DB.refresh, DB.Sync) -- and one every refresh
    -- re register for later UPDATE_BINDINGS now that we got to initialize (Issue #19)
    if isboxer.frame then
      isboxer.frame:RegisterEvent("UPDATE_BINDINGS")
    end
    DB.numInvites = math.max(GetNumGroupMembers(LE_PARTY_CATEGORY_HOME), 1)
    DB:Debug("Set initial inv count to %", DB.numInvites)
    DB:CreateOptionsPanel() -- after sync so we get teamsize for invite slider
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
    self:DebugEvCall(4, ...)
  end,

  BN_INFO_CHANGED = function(self, ...)
    self:DebugEvCall(4, ...)
  end,

  EXECUTE_CHAT_LINE = function(self, ...)
    self:DebugEvCall(2, ...)
  end,

  CLUB_MESSAGE_ADDED = function(self, ...)
    self:DebugEvCall(3, ...)
  end,

  CHAT_MSG_WHISPER = function(self, ...)
    self:DebugEvCall(3, ...)
  end,

  CHAT_MSG_COMMUNITIES_CHANNEL = function(self, ...)
    self:DebugEvCall(3, ...)
  end,

  CLUB_MESSAGE_HISTORY_RECEIVED = function(self, ...)
    self:DebugEvCall(3, ...)
  end,

  CHAT_MSG_BN_WHISPER_INFORM = function(self, ...)
    self:DebugEvCall(3, ...)
  end,

  CHAT_MSG_BN_WHISPER = function(self, ...)
    self:DebugEvCall(3, ...)
  end,

  GROUP_ROSTER_UPDATE = function(self, ...)
    DB:Debug("Rooster udate, num party %, needRaid %", GetNumGroupMembers(LE_PARTY_CATEGORY_HOME), DB.needRaid)
    local inRaid = IsInRaid(LE_PARTY_CATEGORY_HOME)
    if inRaid then
      DB.needRaid = false
    elseif DB.needRaid and DB.autoRaid then -- in case it got turned off
      DB:Debug("(Re) converting to raid")
      ConvertToRaid()
    end
    self:DebugEvCall(2, ...)
  end,

  PARTY_INVITE_REQUEST = function(self, ev, from, ...)
    self:DebugEvCall(1, ev, from, ...)
    local n = DB:NormalizeName(from) -- invite from same realm will have the realm missing in from
    if n == DB.MasterName then
      DB:PrintDefault("Auto accepting invite from current master % (%)", from, n)
    elseif DB.masterHistory[DB.faction]:exists(n) then
      DB:PrintDefault("Auto accepting invite from past master % (%)", from, n)
    elseif DB.TeamIdxByName and DB.TeamIdxByName[n] then
      DB:PrintDefault("Auto accepting invite from current team member % (%, slot %)", from, n, DB.TeamIdxByName[n])
    elseif DB.memberHistory[DB.faction]:exists(n) then
      DB:PrintDefault("Auto accepting invite from past team member % (%)", from, n)
    else
      DB:PrintDefault("Not auto accepting invite from % (%). our master is %; team is %)", from, n, DB.MasterName or "",
                      DB.TeamIdxByNam or "")
      return
    end
    -- actual auto accept:
    AcceptGroup()
    StaticPopup_Hide("PARTY_INVITE")
  end,

  ADDON_LOADED = function(self, _event, name)
    self:Debug(9, "Addon % loaded", name)
    if name ~= addon then
      return -- not us, return
    end
    if DB.manifestVersion == "@project-version@" then
      DB.manifestVersion = "vX.YY.ZZ"
    end
    DB:PrintDefault("DynamicBoxer " .. DB.manifestVersion .. " by MooreaTv: type /dbox for command list/help.")
    if dynamicBoxerSaved then
      -- always clear the one time log
      dynamicBoxerSaved.debugLog = {}
      if not dynamicBoxerSaved.configVersion or dynamicBoxerSaved.configVersion ~= DB.configVersion then
        -- Support conversion from 1 to 2 etc...
        DB:Error(
          "Invalid/unexpected config version (%, we expect %), sorry conversion not available, starting from scratch!",
          dynamicBoxerSaved.configVersion, DB.configVersion)
      else
        dynamicBoxerSaved.addonVersion = DB.manifestVersion
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
          -- restore LRUs.
          if not dynamicBoxerSaved.serializedMasterHistory then
            dynamicBoxerSaved.serializedMasterHistory = {}
          end
          for _, faction in ipairs(DB.Factions) do
            DB.masterHistory[faction]:fromTable(dynamicBoxerSaved.serializedMasterHistory[faction])
          end
          if not dynamicBoxerSaved.serializedMemberHistory then
            dynamicBoxerSaved.serializedMemberHistory = {}
          end
          for _, faction in ipairs(DB.Factions) do
            DB.memberHistory[faction]:fromTable(dynamicBoxerSaved.serializedMemberHistory[faction])
          end
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
    dynamicBoxerSaved.addonVersion = DB.manifestVersion
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
    DB:PrintDefault("DynamicBoxer: No static team/not running under innerspace or user abort... skipping...")
    return
  end
  if not DB.MasterToken or #DB.MasterToken == 0 then
    DB:ForceInit()
    return -- Join will be called at the positive end of the dialog
  end
  DB:Join()
end

DB.joinDone = false -- because we reschedule the join from multiple place, lets do that only once

-- wait up to 1min 10s for channels to show upcharacter creation cinematic to end (dwarf one is ~ 1min)
DB.maxStdChannelCheck = 70 / DB.refresh + 1
DB.stdChannelChecks = 0

-- note: 2 sources of retry, the dynamic init and
function DB:Join()
  -- First check if we have the std channel and reschedule if not
  -- (so our channel doesn't end up as first one, and /1, /2 etc are normal)
  -- if DB.stdChannelChecks == 0 then
  --  DB.Slash("etrace")
  -- end
  -- GetChannelList() is used by chatconfigchanelsettings, but  C_ChatInfo.GetNumActiveChannels() is
  -- same cardinality at all times (that I tested) and much simpler, so using it:
  local numChans = C_ChatInfo.GetNumActiveChannels() -- {GetChannelList()}
  DB:Debug("Checking std channel: num is %", numChans)
  -- we want /1 General and /2 Trade (or /3 Local Defense) at least; if using a non en locale on en server you only get lfg
  if numChans < 1 then
    DB:Debug("Not having std channels, we'll retry later- check %/%, numChans=%", DB.stdChannelChecks,
             DB.maxStdChannelCheck, numChans)
    DB.stdChannelChecks = DB.stdChannelChecks + 1
    if DB.stdChannelChecks % 5 == 0 then
      DB:PrintInfo("DynamicBoxer still waiting for standard channels to appear... retry #%", DB.stdChannelChecks)
    end
    if DB.stdChannelChecks > DB.maxStdChannelCheck then
      DB:Error("Didn't find expected standard channels after > 1 minute (% channels found. % checks done)," ..
                 " giving up/joining anyway, please report this", numChans, DB.stdChannelChecks)
    else
      -- keep trying for now
      return
    end
  end
  -- DB.Slash("etrace stop")
  DB.stdChannelChecks = 0
  if DB.joinDone and DB.joinedChannel and GetChannelName(DB.joinedChannel) then
    DB:Debug("Join already done and channel id still valid. skipping this one") -- Sync will retry
    return
  end
  local action = "Rejoined"
  if not DB.joinDone then
    -- one time setup
    DB:ReconstructTeam()
    local ret = C_ChatInfo.RegisterAddonMessagePrefix(DB.chatPrefix)
    DB:Debug("Prefix register success % in dynamic setup", ret)
    action = "Joined"
  end
  DB.firstMsg = 1
  DB.noMoreExtra = nil
  if DB.maxIter <= 0 then
    DB.maxIter = 1
  end
  if not DB.Channel or #DB.Channel == 0 or not DB.Secret or #DB.Secret == 0 then
    DB:Error("Channel and or Password are empty - this should not be reached/happen")
    return
  end
  DB.joinedChannel = "DynamicBoxer4" .. DB.Channel -- only alphanums seems legal, couldn't find better seperator than 4
  local t, n = JoinTemporaryChannel(DB.joinedChannel, DB.Secret)
  if not DB:CheckChannelOk(DB:format("from Join t=% n=%", t, n)) then
    return
  end
  DB:Debug("Joined channel % / % type % name % id %", DB.joinedChannel, DB.Secret, t, n, DB.channelId)
  DB:PrintInfo(action .. " DynBoxer secure channel. This is slot % and dynamically setting ISBoxer character to %",
               DB.ISBIndex, DB.fullName)
  DB.joinDone = true
  return DB.channelId
end

-- testing strings
-- ÁßçÐéÞýØîÿÆü
-- 乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒乓乒
-- ÁÁÁÁÁÁÁÁÁÑÁÁÁÁÁÁÁÁÁÑÁÁÁÁÁÁÁÁÁÑÁÁÁÁÁÁÁÁÁÑÁÁÁÁÁÁÁÁÁÑÁÁÁÁÁÁÁÁÁÑÁÁÁÁÁÁÁÁÁÑÁÁÁÁÁÁÁÁÁÑÁÁÁÁÁÁÁÁÁÑÁÁÁÁÁÁÁÁÁÇÁÁÁÁÁÁÁÁÁÑÁÁÁÁÁÁÁÁÁÑÁÁÁÁÁÁÁ

function DB:Help(msg)
  DB:PrintDefault("DynamicBoxer: " .. msg .. "\n" .. "/dbox init -- redo the one time channel/secret setup UI\n" ..
                    "/dbox show -- shows the current token string.\n" ..
                    "/dbox set tokenstring -- sets the token string (but using the UI is better)\n" ..
                    "/dbox m -- send mapping again\n" .. "/dbox join -- (re)join channel.\n" ..
                    "/dbox party inv||disband||toggle -- invites the party or disband it or toggle raid/party\n" ..
                    "/dbox team complete -- forces the current team to be assumed to be completed despite missing slots\n" ..
                    "/dbox autoinv toggle||off||n -- toggles, turns off or turns on for slot n the autoinvite\n" ..
                    "/dbox config -- open addon config, dbox c works too\n" ..
                    "/dbox enable on/off-- enable/disable the addon (be careful to turn it back on)\n" ..
                    "/dbox debug on/off/level -- for debugging on at level or off.\n" ..
                    "/dbox reset teams||token||masters||members||status||all -- resets one part of saved variables or all" ..
                    "\n/dbox version -- shows addon version")
end

function DB:SetWatchedSaved(name, value)
  self.watched[name] = value
  if not dynamicBoxerSaved.watched then
    dynamicBoxerSaved.watched = {} -- don't sync everything so new table instead of ref
  end
  dynamicBoxerSaved.watched[name] = value
  DB:Debug(4, "(Saved) Watched Setting % set to % - dynamicBoxerSaved=%", name, value, dynamicBoxerSaved)
end

function DB:SetSaved(name, value)
  self[name] = value
  dynamicBoxerSaved[name] = value
  DB:Debug(5, "(Saved) Setting % set to % - dynamicBoxerSaved=%", name, value, dynamicBoxerSaved)
end

function DB:SetupChange()
  -- re do initialization
  if DB.joinedChannel then
    DB:Debug("Re-init requested, leaving %: %", DB.joinedChannel, LeaveChannelByName(DB.joinedChannel))
    DB.watched.enabled = false
    DB.joinedChannel = nil
    DB.channelId = nil
    DB.joinDone = false
  end
end

function DB:ForceInit()
  DB:SetupChange()
  DB:ReconstructTeam()
  DB:SetupUI()
  DB.justInit = true
end

function DB.Slash(arg) -- can't be a : because used directly as slash command
  DB:Debug("Got slash cmd: %", arg)
  if #arg == 0 then
    DB:Help("commands")
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
    DB.joinDone = false -- force rejoin code
    DB.totalRetries = 0
    DB:ReconstructTeam()
    DB:Join()
  elseif cmd == "v" then
    -- version
    DB:PrintDefault("DynamicBoxer " .. DB.manifestVersion .. " by MooreaTv")
  elseif DB:StartsWith(arg, "init") then
    -- re do initialization
    DB:ForceInit()
  elseif cmd == "i" then
    DB:PrintDefault("Showing the identify info for 6 (more) seconds")
    DB:ShowBigInfo(6)
  elseif cmd == "p" then
    if DB:StartsWith(rest, "d") or DB:StartsWith(rest, "u") then
      -- party disband/uninvite
      DB:Disband()
    elseif DB:StartsWith(rest, "t") then
      -- Toggle raid/party
      DB:PartyToggle()
    else
      -- party invite
      DB:PartyInvite()
    end
  elseif cmd == "t" then
    -- team complete
    if DB:StartsWith(rest, "c") then
      if not DB.teamComplete then
        DB:Warning("Forcing team to be complete while slots are missing")
      end
      DB:TeamIsComplete()
      return
    end
    DB:Help("Unknown team command")
  elseif DB:StartsWith(arg, "reset") then
    -- require reset to be spelled out (other r* are the random gen)
    if rest == "teams" then
      dynamicBoxerSaved.teamHistory = {}
      DB:Warning("Team history reset per request (next login will popup the token window until team is complete)")
    elseif rest == "token" then
      dynamicBoxerSaved.MasterToken = nil
      DB:Warning("Token cleared per request, will prompt for it at next login")
    elseif rest == "status" then
      DB:StatusResetPos()
      DB:Warning("Saved window status position cleared per request and window reset to top left")
    elseif rest == "masters" then
      if dynamicBoxerSaved.serializedMasterHistory then
        dynamicBoxerSaved.serializedMasterHistory[DB.faction] = {}
        DB:Warning("Master history for % cleared per request, will likely need manual /dbox show next login", DB.faction)
      else
        DB:Warning("No master history to clear")
      end
    elseif rest == "members" then
      if dynamicBoxerSaved.serializedMemberHistory then
        dynamicBoxerSaved.serializedMemberHistory[DB.faction] = {}
        DB:Warning(
          "Members history for % cleared per request, auto accept invite from non master may not work next login",
          DB.faction)
      else
        DB:Warning("No member history to clear")
      end
    elseif rest == "all" then
      dynamicBoxerSaved = nil -- any subsequent DB:SetSaved will fail...
      DB:Warning("State all reset per request, please /reload !")
      -- C_UI.Reload() -- in theory we could reload for them but that seems bad form
    else
      DB:Error("Use /dbox reset x -- where x is one of status, teams, token, masters, members, all")
    end
  elseif cmd == "m" then
    -- message again
    DB.maxIter = 1
    DB.totalRetries = 0
    DB.Sync()
  elseif cmd == "x" then
    DB:ExchangeTokenUI()
  elseif cmd == "a" then
    if DB:StartsWith(rest, "t") then
      DB.autoInvite = not DB.autoInvite
    elseif DB:StartsWith(rest, "o") then
      DB.autoInvite = false
    else
      local x = tonumber(rest)
      if x then
        DB.autoInvite = true
        DB.autoInviteSlot = x
      else
        DB:Error("Use /dbox autoinvite x -- where x is one of toggle, off, or the slot number that should invite.")
        return
      end
    end
    DB:SetSaved("autoInvite", DB.autoInvite)
    DB:SetSaved("autoInviteSlot", DB.autoInviteSlot)
    DB:PrintDefault("Auto invite is now " .. (DB.autoInvite and "ON" or "OFF") .. " for slot %", DB.autoInviteSlot)
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
        DB:SetupChange()
        DB.watched.enabled = true
        DB:Join()
        return
      end
    end
    -- if above didn't match, failed/didn't return, then fall back to showing UI
    DB:ShowTokenUI()
    -- for debug, needs exact match (of start of "debug ..."):
  elseif cmd == "c" then
    -- Show config panel
    -- InterfaceOptionsList_DisplayPanel(DB.optionsPanel)
    InterfaceOptionsFrame:Show() -- onshow will clear the category if not already displayed
    InterfaceOptionsFrame_OpenToCategory(DB.optionsPanel) -- gets our name selected
  elseif cmd == "e" then
    if DB:StartsWith(arg, "enable") then
      -- enable
      if rest == "off" then
        DB:Warning("Now PAUSED.")
        DB:SetWatchedSaved("enabled", false)
      else
        DB:PrintDefault("DynamicBoxer is enabled")
        DB:SetWatchedSaved("enabled", true)
      end
      return
    end
    UIParentLoadAddOn("Blizzard_DebugTools")
    -- hook our code, only once/if there are no other hooks
    if EventTraceFrame:GetScript("OnShow") == EventTraceFrame_OnShow then
      EventTraceFrame:HookScript("OnShow", function()
        EventTraceFrame.ignoredEvents = DB:CloneTable(DB.etraceIgnored)
        DB:PrintDefault("Restored ignored etrace events: %", DB.etraceIgnored)
      end)
    else
      DB:Debug(3, "EventTraceFrame:OnShow already hooked, hopefully to ours")
    end
    -- save or anything starting with s that isn't the start/stop commands of actual eventtrace
    if DB:StartsWith(rest, "s") and rest ~= "start" and rest ~= "stop" then
      DB:SetSaved("etraceIgnored", DB:CloneTable(EventTraceFrame.ignoredEvents))
      DB:PrintDefault("Saved ignored etrace events: %", DB.etraceIgnored)
    elseif DB:StartsWith(rest, "c") then
      EventTraceFrame.ignoredEvents = {}
      DB:PrintDefault("Cleared the current event filters")
    else -- leave the other sub commands unchanged, like start/stop and n
      DB:Debug("Calling  EventTraceFrame_HandleSlashCmd(%)", rest)
      EventTraceFrame_HandleSlashCmd(rest)
    end
  elseif DB:StartsWith(arg, "debug") then
    -- debug
    if rest == "on" then
      DB:SetSaved("debug", 1)
    elseif rest == "off" then
      DB:SetSaved("debug", nil)
    else
      DB:SetSaved("debug", tonumber(rest))
    end
    DB:PrintDefault("DynBoxer debug now %", DB.debug)
  elseif cmd == "d" then
    -- dump
    DB:PrintInfo("DynBoxer dump of % = %", rest, _G[rest])
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
