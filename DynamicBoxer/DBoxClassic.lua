--[[
   DynamicBoxer: Dynamic Team Multiboxing by MooreaTV moorea@ymail.com (c) 2019 All rights reserved
   Licensed under LGPLv3 - No Warranty
   (contact the author if you need a different license)

   With classic change in 1.13.3 we can't use a secret protected channel anymore, so we'll use direct
   whispers

   We also use party/raid/guild addon communication as these haven't been yanked (yet)

   TODO: remember the current/last party and differentiate simple /reload from logout/login (player entering world vs login)

   ]] --
--
-- our name, our empty default (and unused) anonymous ns
local _addon, _ns = ...

-- Created by DBoxInit
local DB = DynBoxer

if DB.isLegacy then
  return
end

if not DB.isClassic then
  -- put back basic global functions gone in 9.0
  function ConvertToRaid()
    C_PartyInfo.ConvertToRaid()
  end
  function ConvertToParty()
    C_PartyInfo.ConvertToParty()
  end
  function InviteUnit(fullName)
    C_PartyInfo.InviteUnit(fullName)
  end
  function LeaveParty()
    C_PartyInfo.LeaveParty()
  end
  -- don't process the rest of this file
  return
end

local L = DB.L

DB:SetupGuildInfo() -- register additional event

DB.securePastThreshold = 180 -- 3mins for larger groups and/or reload

function DB:IsGrouped()
  local num = GetNumGroupMembers(LE_PARTY_CATEGORY_HOME)
  return num > 0
end

function DB:InGuild()
  return IsInGuild() -- should also cache as it lags at login and returns false when it shouldn't
end

function DB:NewestSameRealmMaster()
  for v in DB.masterHistory[DB.faction]:iterateNewest() do
    if DB:SameRealmAsUs(v) then
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
    DB:Debug(3, "already figured out classic master %", DB.crossRealmMaster)
    return true
  end
  DB.crossRealmMaster = "" -- so we don't print stuff again
  local master
  master = DB:NewestSameRealmMaster()
  if master and #master > 0 then
      DB.MasterName = master
      DB.crossRealmMaster = master
      DB:PrintDefault("Trying most recent same realm and faction master %, for direct message sync.", DB.MasterName)
      return true
  end
  if DB.masterHistory[DB.faction]:exists(DB.MasterName) then
    DB:PrintDefault("Using previously seen (cross realm on bfa) master token as is.")
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

function DB:SendDirectMessage(to, payload)
  DB.sentMessageCount = DB.sentMessageCount + 1
  if to == DB.fullName then
    local msg = "Trying to send message to ourselves !"
    DB:Error(msg)
    return
  end
  if DB.sentMessageCount > 200 then
    DB:Error("Sent too many messages - not sending msg #% for %: %", DB.sentMessageCount, to, payload)
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
  local inSameGuild = DB:IsInOurGuild(to)
  DB:Debug(2, "About to send message #% id % to % - same guild: %", DB.sentMessageCount, messageId, to, inSameGuild)
  local inSameGuildMarker
  if inSameGuild then
    inSameGuildMarker = " *G* "
  else
    inSameGuildMarker = "     "
  end
  DB:DebugLogWrite(messageId .. " :   " .. inPartyMarker .. inSameGuildMarker .. "    To: " .. to ..
    " : #" .. DB.sentMessageCount .. " " .. payload)
  -- local toSend = DB.whisperPrefix .. secureMessage
  -- must stay under 255 bytes, we are around 96 bytes atm (depends on character name (accentuated characters count double)
  -- and realm length, the hash alone is 16 bytes)
  DB:Debug(3, "About to send message #% id % to % len % msg=%", DB.sentMessageCount, messageId, to, #secureMessage, secureMessage)
  if inSameGuild then
    local ret = C_ChatInfo.SendAddonMessage(DB.chatPrefix, secureMessage, "GUILD")
    DB:Debug("we are in guild with %, used guild msg, ret=%", to, ret)
    if ret then
      return messageId -- mission accomplished
    end
    DB:Warning("Can't send guild addon message #%, reverting to party or whisper", DB.sentMessageCount)
  end
  if inParty then
    local ret = C_ChatInfo.SendAddonMessage(DB.chatPrefix, secureMessage, "RAID")
    DB:Debug("we are in party with %, used party/raid msg, ret=%", to, ret)
    if ret then
      return messageId -- mission accomplished
    end
    DB:Warning("Can't send party/raid addon message #%, reverting to whisper", DB.sentMessageCount)
  end
  local ret = C_ChatInfo.SendAddonMessage(DB.chatPrefix, secureMessage, "WHISPER", to)
  DB:Debug("Whisper to %, ret=%", to, ret)
  -- SendChatMessage(toSend, "WHISPER", nil, to) -- returns nothing even if successful (!)
  -- We would need to watch (asynchronously, for how long ?) for CHAT_MSG_WHISPER_INFORM for success or CHAT_MSG_SYSTEM for errors
  -- instead we'll expect to get a reply from the master and if we don't then we'll try another/not have mapping
  -- use the signature as message id, put it in our LRU for queue of msg waiting ack
  return messageId
end

function DB:InfoPayload(slot, firstFlag)
  return DB:SlotCommand(slot, DB.Team[slot].fullName, firstFlag) -- classic == no xrealm so we can use the short name
end

function DB:MyInfo()
  local firstFlag = 1
  if DB.teamComplete then
    firstFlag = 0
  end
  return DB:InfoPayload(DB.ISBIndex, firstFlag)
end

function DB:SendMyInfo()
  local myInfo = DB:MyInfo()
  local secureMessage, messageId = DB:CreateSecureMessage(myInfo, DB.Channel, DB.Secret)
  -- send in say, party and guild
  local ret = true
  if DB:InGuild() then
    if not C_ChatInfo.SendAddonMessage(DB.chatPrefix, secureMessage, "GUILD") then
      ret = false
    end
    DB:Debug("we are in a guild sending our info there: %", ret)
  end
  if DB:IsGrouped() then
    if not C_ChatInfo.SendAddonMessage(DB.chatPrefix, secureMessage, "RAID") then
      ret = false
    end
    DB:Debug("we are in a group sending our info there: %", ret)
  end
  if not C_ChatInfo.SendAddonMessage(DB.chatPrefix, secureMessage, "SAY") then
    ret = false
  end
  DB:Debug("Sending our info in SAY: % (mid %)", ret, messageId)
  return ret
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
  local firstPayload = DB:InfoPayload(DB.ISBIndex, 1, DB.syncNum)
  -- send info to guild, party and say
  local ret = DB:SendMyInfo()
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
      DB:Debug("Classic sync and team incomplete/master unknown, pinging master % - %", DB.MasterName, DB.Team[1])
      DB:SendDirectMessage(DB.MasterName, firstPayload)
      if DB.firstMsg == 1 and DB.maxIter <= 0 then
        DB:Debug("Classic sync, first time, increasing msg sync to 2 more")
        -- we have to sync twice to complete the team (if all goes well, but it's faster with party invite)
        DB.maxIter = 3 -- give it a couple extra attempts in case 1 slave is slow
      end
      -- on last attempt [TODO: split channel retries from this], also ping some older/previous masters for our faction
      if DB.maxIter == 0 then
        local maxOthers = 3
        for v in DB.masterHistory[DB.faction]:iterateNewest() do
          DB:Debug("Checking % for next xrealm attempt (mastername %) samerealm %", v, DB.MasterName,
                   DB:SameRealmAsUs(v))
          local tryIt = not DB:SameRealmAsUs(v)
          tryIt = not tryIt -- classic is reverse, need to use same realm
          if tryIt and v ~= DB.MasterName then
            DB:Warning("Also trying %s from master history as attempt to find our master", v)
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
        if DB.Team[1] then
          DB:PrintDefault("Team not yet complete after %s, sending 1 extra re-sync", delay)
          DB:SendDirectMessage(DB.Team[1].fullName, firstPayload)
        else
          DB:Warning("No team / no master response after % sec, please fix slot 1 and/or paste token", delay)
        end
      end)
    end
  end
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
    DB:Debug("No real channel on classic (" .. msg .. ")")
    return false
  end
  DB.channelId = GetChannelName(DB.joinedChannel)
  if not DB.channelId then
    DB:Warning("Couldn't get channel id for our channel %, will retry (" .. msg .. ")", DB.joinedChannel)
    return false
  end
  return true
end

-- [bfa] Too bad addon messages don't work cross realm even through whisper
-- (and yet they work with BN friends BUT they don't work with yourself!)
-- TODO: refactor, this is too long / complicated for 1 function
function DB:ProcessMessage(source, from, data)
  if not DB.ISBTeam then
    -- we can get messages events before the normal reconstruct team flow
    -- but sometimes too early to get player faction for instance
    if not DB:ReconstructTeam() then
      DB:Debug(1, "Skipping early message % % %", source, from, data)
      return
    end
  end
  local doForward = nil
  local channelMessage = (source == "CHANNEL")
  local directMessage = (source == "WHISPER" or source == "CHAT_FILTER")
  if from == DB.fullName then
    DB:Debug(2, "Skipping our own message on %: %", source, data)
    return
  end
  -- check authenticity (channel sends unsigned messages)
  local valid, msg, lag, msgId = DB:VerifySecureMessage(data, DB.Channel, DB.Secret)
  if valid then
    DB:Debug(2, "Received valid secure direct=% message from % lag is %s, msg id is % part of full message %",
               directMessage, from, lag, msgId, data)
    local isDup = false
    if DB.duplicateMsg:exists(msgId) then
      DB:Debug("!!!Received % duplicate msg from %, will ignore: %", source, from, data)
      isDup = true
    end
    DB.duplicateMsg:add(msgId)
    if directMessage then
      DB.lastDirectMessage = GetTime()
    end
    if isDup then
      DB:DebugLogWrite(msgId .. " : From: " .. from .. "  DUP : " .. msg .. " (lag " .. tostring(lag) .. ")")
      return
    else
      DB:DebugLogWrite(msgId .. " : From: " .. from .. "      : " .. msg .. " (lag " .. tostring(lag) .. ")")
    end
    if DB:WeAreMaster() and directMessage then
      doForward = msg
    end
  else
    -- in theory warning if the source isn't guild/say/...
    DB:Debug("Received invalid (" .. msg .. ") message % from %: %", source, from, data)
    return
  end
  data = msg
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
  if not DB.watched.enabled then
    DB:Warning("Addon is disabled, so ignoring otherwise good % mapping for slot %: % from %", source, idx, realname,
               from)
    return
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
    DB:Warning("New team detected, on master, showing current token")
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
  local autoInviteSlotMatch
  local minInviteSlot = 1
  local maxInviteSlot = 99
  if DB:UnlimitedInvites() then
    autoInviteSlotMatch = (DB.autoInviteSlot == DB.ISBIndex)
  else
    autoInviteSlotMatch = ((DB.ISBIndex % DB.maxParty) == DB.autoInviteSlot)
    minInviteSlot = DB.ISBIndex
    maxInviteSlot = DB.ISBIndex + DB.maxParty - 1
  end
  if DB.autoInvite and autoInviteSlotMatch and idx ~= DB.ISBIndex then
    -- This check works for in raid too but must be short name
    -- sometimes it lags...
    if UnitInParty(shortName) then
      DB:Debug("Slot %: % is already in our party/raid, won't re invite", idx, realname)
    else
      if idx >= minInviteSlot and idx <= maxInviteSlot then
        DB:PrintDefault(
          "Auto invite is on for our slot, scheduling invite #%: % (turn off/configure in /dbox config if desired)", idx,
          realname)
          C_Timer.After(0.25, function()
            DB:Invite(realname)
          end)
      else
        DB:PrintDefault("Not inviting out of max party range slot #%: %", idx, realname)
      end
    end
  else
    DB:Debug("Slot % not inviting slot % - auto inv slot is %, auto invite is %", DB.ISBIndex, idx, DB.autoInviteSlot,
             DB.autoInvite)
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
    DB:PrintInfo("Change of mapping for slot %, dynamically set Team character to % (%, was % before)", idx,
                 shortName, realname, previousMapping.fullName)
  else
    DB:PrintInfo("New mapping for slot %, dynamically set Team character to % (%)", idx, shortName, realname)
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
    DB:TeamIsComplete()
  end
  -- Avoid that EMA/... bugs break us so we do this last
  if EMAApi then
    DB:Debug(">>>Calling ema AddMember %", realname)
    EMAApi.AddMember(realname)
  end
  if DB.Jamba then
    DB:Debug(">>>Calling Jamba AddMember %", realname)
    DB.Jamba:AddMemberCommand(nil, realname)
  end
  -- lastly once we have the full team (and if it changes later), set the EMA team to match the slot order, if EMA is present:
  if DB.currentCount == DB.expectedCount or teamComplete then
    DB:OtherAddonsSync()
  end
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
  -- channel addon messaging is broken in 1.13.3 so we just do something else
  if not DB.joinDone then
    -- one time setup
    DB:ReconstructTeam()
  end
  DB.stdChannelChecks = 0
  DB.channelId = -1 -- classic hack for now to not loop into this
  DB:Debug("Running on classic, no channel addon comms, no channel joining but guild/party comm")
  -- still need to register prefix though because of party/raid chat
  local ret = C_ChatInfo.RegisterAddonMessagePrefix(DB.chatPrefix)
  DB:Debug("Prefix register success % in dynamic setup", ret)
  DB:PrintInfo(L["DynBoxer running on classic. This is slot % and dynamically setting Team character to %"],
               DB.ISBIndex, DB.fullName)
  DB.firstMsg = 1
  DB.noMoreExtra = nil
  if DB.maxIter <= 0 then
    DB.maxIter = 1
  end
  DB.joinDone = true
  return DB.channelId
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
  DB.watched.enabled = true
  DB:SetupChange()
  DB:ReconstructTeam()
  DB:SetupUI()
  DB.justInit = true
end
