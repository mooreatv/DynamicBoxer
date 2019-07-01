--[[
   DynamicBoxer: Dynamic Team Multiboxing by MooreaTV moorea@ymail.com (c) 2019 All rights reserved
   Licensed under LGPLv3 - No Warranty
   (contact the author if you need a different license)
   ]] --
--
-- our name, our empty default (and unused) anonymous ns
local _addon, _ns = ...

-- Created by DBoxInit
local DB = DynBoxer

DB.lastChatFilterSeq = -1

function DB:ChatFilter(event, msg, author, ...)
  local seq = select(9, ...)
  DB:Debug(3, "Chat Filter cb for % s=% e=% msg=% author=% rest=%", seq, self and self:GetName() or "<no name>", event,
           msg, author, {...})
  local data -- set by callback to what's after the prefix
  if DB:StartsWith(msg, DB.whisperPrefix, function(rest)
    data = rest
  end) then
    -- DB:ProcessMessage(source, from, data)
    if event ~= "CHAT_MSG_WHISPER_INFORM" then -- don't process our own messages
      if seq ~= DB.lastChatFilterSeq then
        DB:ProcessMessage("CHAT_FILTER", author, data)
        DB.lastChatFilterSeq = seq
      else
        DB:Debug(3, "Skipping dup %", seq)
      end
    end
    return true
  end
  return false
end

ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER", DB.ChatFilter)
ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER_INFORM", DB.ChatFilter)

DB:Debug("dbox chat file loaded")
