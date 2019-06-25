--[[
   DynamicBoxer: Dynamic Team Multiboxing by MooreaTV moorea@ymail.com (c) 2019 All rights reserved
   Licensed under LGPLv3 - No Warranty
   (contact the author if you need a different license)
   ]] --
--
-- our name, our empty default (and unused) anonymous ns
local addon, ns = ...

-- Created by DBoxInit
local DB = DynBoxer

function DB:ChatFilter(event, msg, author, ...)
  DB:Debug(2, "Chat Filter cb for s=% e=% msg=% author=% rest=%", self and self:GetName() or "<no name>", event, msg,
           author, {...})
  local data -- set by callback to what's after the prefix
  if DB:StartsWith(msg, DB.whisperPrefix, function(rest)
    data = rest
  end) then
    -- DB:ProcessMessage(source, from, data)
    if event ~= "CHAT_MSG_WHISPER_INFORM" then -- don't process our own messages
      DB:ProcessMessage("CHAT_FILTER", author, data)
    end
    return true
  end
  return false
end

ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER", DB.ChatFilter)
ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER_INFORM", DB.ChatFilter)

DB:Debug("dbox chat file loaded")
