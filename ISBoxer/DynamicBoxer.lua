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

local addon, ns = ... -- our name, our empty default anonymous ns

CreateFrame("frame", "DynamicBoxer", UIParent) -- this creates the global table/ns of namesake

local DB = DynamicBoxer

-- TODO: for something actually secure, this must be generated and kept secret
-- also consider using bnet communication as a common case is all characters are from same bnet

DB.Channel = string.gsub(select(2, BNGetInfo()), "#", "") -- also support multiple bnet/make this confirgurable
DB.Secret = "PrototypeSecret12345" -- this should be secure, unique,... and/or ask the user to /dbox secret <something> and save it

-- TODO: isboxer saves the name of the character set and indirectly the size in each slot but not directly the size
DB.TeamSize = 2

DB.debug = 1

function DB.Print(...)
  DEFAULT_CHAT_FRAME:AddMessage(...)
end

function DB.Debug(msg)
  if DB.debug == 1 then
    DB.Print("DB DBG: " .. msg, 0, 1, 0)
  end
end

-- [[]]

DB.teamComplete = false
DB.maxIter = 20
DB.refresh = 3
DB.nextUpdate = 0
DB.chatPrefix = "dbox0" -- protocol version in prefix
DB.channelId = nil

function DB.Sync()
  if DB.maxIter <= 0 or DB.teamComplete then
    -- TODO: unregister the event/cb/timer
    -- DB.Debug("CB shouldn't be called when maxIter is " .. DB.maxIter .. " or teamComplete is " ..
    --                     tostring(DB.teamComplete))
    return
  end
  if not DB.channelId then
    DB.DynamicInit()
  end
  DB.maxIter = DB.maxIter - 1
  DB.Debug("Sync CB called for slot " .. DB.slot .. ", actual " .. DB.actual .. ", maxIter is now " .. DB.maxIter)
  local payload = DB.slot .. " is " .. DB.actual .. " msg " .. tostring(DB.maxIter)
  local ret = C_ChatInfo.SendAddonMessage(DB.chatPrefix, payload, "CHANNEL", DB.channelId)
  DB.Debug("Message success " .. tostring(ret) .. " on chanId " .. tostring(DB.channelId))
end

function DB.OnUpdate(self, elapsed)
  local now = GetTime()
  if now >= DB.nextUpdate then
    -- skip the very first time
    if DB.nextUpdate ~= 0 then
      DB.Sync()
    else
      DB.Debug("Skipping first timer event")
    end
    DB.nextUpdate = now + DB.refresh
  end
end

DB.EventD = {

  CHAT_MSG_ADDON = function(this, event, prefix, data, channel, sender, zoneChannelID, localID, name, instanceID)
    DB.Debug(
                  "OnChatEvent called for " .. this:GetName() .. " e=" .. event .. " channel=" .. channel .. " p=" .. prefix ..
                    " data=" .. data .. " from " .. sender .. " z=" .. tostring(zoneChannelID) .. ", lid=" .. tostring(localID) ..
                    " name=" .. name .. ", instance = " .. tostring(instanceID))
  end,

  PLAYER_ENTERING_WORLD = function(this, event)
    DB.Debug("OnPlayerEntering world")
    C_Timer.After(1, DB.Sync)
  end,

  CHANNEL_COUNT_UPDATE = function(this, event, displayIndex, count) -- TODO: never seem to fire
    DB.Debug("OnChannelCountUpdate didx=" .. tostring(displayIndex) .. ", count=".. tostring(count))
  end,
}

function DB.OnEvent(this, event, ...)
  DB.Debug("OnEvent called for " .. this:GetName() .. " e=" .. event)
  local handler = DB.EventD[event]
  if handler then
    return handler(this, event, ...)
  end
  DB.Print("Unexpected event without handler " .. event, 1, 0, 0)
end

function DB.DynamicSetup(slot, actual)
  DB.slot = slot
  DB.actual = actual
  local ret = C_ChatInfo.RegisterAddonMessagePrefix(DB.chatPrefix)
  DB.Debug("Prefix register success " .. tostring(ret))
  return true -- TODO: only return true if we are good to go (but then the sync may take a while and fail later)
end

function DB.DynamicInit(slot, actual)
  DB.Debug("Delayed init called")
  DB.Join()
end

function DB.Join()
  local type, name = JoinTemporaryChannel(DB.Channel, DB.Secret, 99)
  DB.channelId = GetChannelName(DB.Channel)
  DB.Debug("Joined channel " .. DB.Channel .. ", type " .. type .. " name " .. (name or "<unset>") .. " id " ..
             tostring(DB.channelId))
  return DB.channelId
end

function DB.Help(msg)
  DB.Print("DynamicBoxer: " .. msg .. "\n" .. "/dbox join -- join channel.\n" .. "/dbox more... coming...later...")
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
    DB.Print("DynamicBoxer Debug ON")
  elseif arg == "debug off" then
    -- debug
    DB.debug = nil
    DB.Print("DynamicBoxer Debug OFF")
  else
    DB.Help("unknown command \"" .. arg .. "\", usage:")
  end
end

SlashCmdList["DynamicBoxer_Slash_Command"] = DB.Slash

SLASH_DynamicBoxer_Slash_Command1 = "/dbox"
SLASH_DynamicBoxer_Slash_Command2 = "/dynamicboxer"

DB:SetScript("OnEvent", DB.OnEvent)
for k,_ in pairs(DB.EventD) do
  DB:RegisterEvent(k)
end

DB.Debug("End of file reached")
-- DB.ticker = C_Timer.NewTicker(DB.refresh, DB.Ticker)
