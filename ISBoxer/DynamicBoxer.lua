--[[ 
   Proof of concept of Dynamic Team by MooreaTV moorea@ymail.com

   Join secret/protect channel
   Broadcast periodically slot # and name for a while (or until all acked)
   Stop as soon as you see slot1 (unless you are slot 1)
   Read from slot1 the team list
   Slot1 (master) reading the other slots

   [todo have isboxer just save the team cardinality so we know when to stop
   for now let's hack the toon name to be "i/n"]
]] 

DynamicBoxer = {}

-- TODO: for something actually secure, this must be generated and kept secret
-- also consider using bnet communication as a common case is all characters are from same bnet

DynamicBoxer.Channel = string.gsub(select(2, BNGetInfo()), "#", "") -- also support multiple bnet/make this confirgurable
DynamicBoxer.Secret = "PrototypeSecret12345" -- this should be secure, unique,...

-- TODO: isboxer saves the name of the character set and indirectly the size in each slot but not directly the size
DynamicBoxer.TeamSize = 2

DynamicBoxer.debug = 1

function DynamicBoxer.Print(...)
  DEFAULT_CHAT_FRAME:AddMessage(...)
end

function DynamicBoxer.Debug(msg)
  if DynamicBoxer.debug == 1 then
    DynamicBoxer.Print("DynamicBoxer DBG: " .. msg, 0, 1, 0)
  end
end

-- [[]]

DynamicBoxer.teamComplete = false
DynamicBoxer.maxIter = 20
DynamicBoxer.refresh = 3
DynamicBoxer.nextUpdate = 0
DynamicBoxer.chatPrefix = "dbox"
DynamicBoxer.channelId = nil

function DynamicBoxer.Sync()
  if DynamicBoxer.maxIter <= 0 or DynamicBoxer.teamComplete then
    -- TODO: unregister the event/cb/timer
    -- DynamicBoxer.Debug("CB shouldn't be called when maxIter is " .. DynamicBoxer.maxIter .. " or teamComplete is " ..
    --                     tostring(DynamicBoxer.teamComplete))
    return
  end
  if not DynamicBoxer.channelId then
    DynamicBoxer.DynamicInit()
  end
  DynamicBoxer.maxIter = DynamicBoxer.maxIter - 1
  DynamicBoxer.Debug("Sync CB called for slot " .. DynamicBoxer.slot .. ", actual " .. DynamicBoxer.actual .. ", maxIter is now " ..
                       DynamicBoxer.maxIter)
  local payload = DynamicBoxer.slot .. " is " .. DynamicBoxer.actual .. " msg " .. tostring(DynamicBoxer.maxIter)
  local ret = C_ChatInfo.SendAddonMessage(DynamicBoxer.chatPrefix, payload, "CHANNEL", DynamicBoxer.channelId)
  DynamicBoxer.Debug("Message success " .. tostring(ret) .. " on chanId " .. tostring(DynamicBoxer.channelId))
end

function DynamicBoxer.OnUpdate(self, elapsed)
  local now = GetTime()
  if now >= DynamicBoxer.nextUpdate then
    -- skip the very first time
    if DynamicBoxer.nextUpdate ~= 0 then
      DynamicBoxer.Sync()
    else
      DynamicBoxer.Debug("Skipping first timer event")
    end
    DynamicBoxer.nextUpdate = now + DynamicBoxer.refresh
  end
end

function DynamicBoxer.OnChatEvent(this, event, prefix, data, channel, sender, zoneChannelID, localID, name, instanceID)
  DynamicBoxer.Debug("OnEvent called for " .. this:GetName() .. " e=" .. event .. " channel=" .. channel .. " p=" .. prefix ..
                       " data=" .. data .. " from " .. sender .. " z=" .. tostring(zoneChannelID) .. ", lid=" .. tostring(localID) ..
                       " name=" .. name .. ", instance = " .. tostring(instanceID))
end

function DynamicBoxer.DynamicSetup(slot, actual)
  DynamicBoxer.slot = slot
  DynamicBoxer.actual = actual
  if DynamicBoxer.frame == nil then
    DynamicBoxer.frame = CreateFrame("frame", "DynamicBoxer", UIParent)
  end
  DynamicBoxer.frame:SetScript("OnUpdate", DynamicBoxer.OnUpdate)
  DynamicBoxer.frame:SetScript("OnEvent", DynamicBoxer.OnChatEvent)
  DynamicBoxer.frame:RegisterEvent("CHAT_MSG_ADDON")
  local ret = C_ChatInfo.RegisterAddonMessagePrefix(DynamicBoxer.chatPrefix)
  DynamicBoxer.Debug("Prefix register success " .. tostring(ret))
  return true -- TODO: only return true if we are good to go (but then the sync may take a while and fail later)
end

function DynamicBoxer.DynamicInit(slot, actual)
  DynamicBoxer.Debug("Delayed init called")
  DynamicBoxer.Join()
end

function DynamicBoxer.Join()
  local type, name = JoinTemporaryChannel(DynamicBoxer.Channel, DynamicBoxer.Secret)
  DynamicBoxer.channelId = GetChannelName(DynamicBoxer.Channel)
  DynamicBoxer.Debug("Joined channel " .. DynamicBoxer.Channel .. ", type " .. type .. " name " .. (name or "<unset>") .. " id " ..
                       tostring(DynamicBoxer.channelId))
  return DynamicBoxer.channelId
end

function DynamicBoxer.Help(msg)
  DynamicBoxer.Print("DynamicBoxer: " .. msg .. "\n" .. "/dbox join -- join channel.\n" .. "/dbox more... coming...later...")
end

function DynamicBoxer.Slash(arg)
  if #arg == 0 then
    DynamicBoxer.Help("commands")
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
    DynamicBoxer.Join()
  elseif cmd == "q" then
    -- query 
    -- for debug, needs exact match:
  elseif arg == "debug on" then
    -- debug
    DynamicBoxer.debug = 1
    DynamicBoxer.Print("DynamicBoxer Debug ON")
  elseif arg == "debug off" then
    -- debug
    DynamicBoxer.debug = nil
    DynamicBoxer.Print("DynamicBoxer Debug OFF")
  else
    DynamicBoxer.Help("unknown command \"" .. arg .. "\", usage:")
  end
end

SlashCmdList["DynamicBoxer_Slash_Command"] = DynamicBoxer.Slash

SLASH_DynamicBoxer_Slash_Command1 = "/dbox"
SLASH_DynamicBoxer_Slash_Command2 = "/dynamicboxer"
