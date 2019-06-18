--[[
  DynamicBoxer -- (c) 2009-2019 moorea@ymail.com (MooreaTv)
  Covered by the GNU General Public License version 3 (GPLv3)
  NO WARRANTY
  (contact the author if you need a different license)
]] --
-- our name, our empty default (and unused) anonymous ns
local addon, ns = ...

-- Created by DBoxInit
local DB = DynBoxer

function DB.OnSlaveUIShow(widget, _data)
  DB:Debug("Slave UI Show")
  local e = widget.editBox
  local newText = e:GetText()
  DB.fontString:SetFontObject(e:GetFontObject())
  -- just to get a starting length
  if strlenutf8(newText) < DB.uiTextLen then
    -- width calc placeholder
    newText = "Justtesting-Kil'jaeden 3ljevJet TL21f8YB W"
  end
  DB.fontString:SetText(newText .. "W") -- add 1 extra character to avoid scrolling (!)
  local width = DB.fontString:GetStringWidth()
  DB:Debug("Width is %", width)
  e:SetWidth(width)
  e.Instructions:SetText("  Paste here from Slot 1")
  e:HighlightText()
  -- e:SetCursorPosition(#newText)
end

function DB.OnSetupUIAccept(widget, data, data2)
  DB:Debug("SetupUI Accept")
  DB:Debug(9, "SetupUI Accept w=% d1=% d2=%", widget, data, data2)
  local token = widget.editBox:GetText()
  DB:SetSaved("MasterToken", token)
  local masterName, channel, password = token:match("^([^ ]+) ([^ ]+) ([^ ]+)") -- or strplit(" ", token)
  DB:SetSaved("Channel", channel)
  DB:SetSaved("Secret", password)
  DB:Debug("Current master is %", masterName) -- TODO: send it a message to dismiss its dialog and deal with cross realm
  widget:Hide()
  DB.enabled = true
  DB.inUI = false
  DB.joinDone = false -- force rejoin code
  DB:Join()
end

function DB.OnUICancel(widget, _data)
  DB.enabled = false -- avoids a loop where we keep trying to ask user
  DB.inUI = false
  widget:Hide()
  DB:Error("User cancelled. Will not use DynamicBoxer until /reload or /dbox i")
end

DB.randomIdLen = 8
DB.fontPath = "Interface\\AddOns\\DynamicBoxer\\fixed-font.otf"

function DB.SetupFont(height)
  if DB.fixedFont then
    return DB.fixedFont
  end
  DB.fixedFont = CreateFont("DynBoxerFixedFont")
  DB:Debug("Set font custom height %, path %: %", height, DB.fontPath, DB.fixedFont:SetFont(DB.fontPath, height))
  -- DB:Debug("Set font system: %", DB.fixedFont:SetFont(CombatTextFont:GetFont(), 10))
  return DB.fixedFont
end

-- local x = 0

DB.fontString = DB:CreateFontString()

function DB.OnRandomUIShow(widget, _data)
  DB:Debug("Randomize UI Show/Regen")
  local e = widget.editBox
  DB.randomEditBox = e
  local newText = DB.RandomId(DB.randomIdLen)
  --[[ width test, alternate narrow and wide
  if x % 2 == 0 then
    newText = "12345678"
    -- newText = "iiiiiiii"
  else
    newText = "WWWWWWWW"
  end
  x = x + 1
  ]]
  e:SetText(newText)
  DB:Debug("Checking size on %", e)
  local height = e.Instructions:GetHeight()
  DB:Debug("Height from edit box is %", height)
  e:HighlightText()
  e:SetJustifyH("CENTER")
  local font = DB.SetupFont(height / 2)
  e:SetFontObject(font)
  DB.fontString:SetFontObject(font)
  DB.fontString:SetText(newText)
  local width = DB.fontString:GetStringWidth()
  DB:Debug("Width with new font is %", width)
  e:SetWidth(width + 4) -- + some or highlights hides most of it/it doesn't fit
  e:SetMaxLetters(DB.randomIdLen)
  e:SetScript("OnTabPressed", function()
    DB:Debug("Tab pressed on random, switching!")
    if DB.currentMainEditBox then
      DB.currentMainEditBox:SetFocus()
    end
  end)
  e:SetScript("OnMouseUp", function(self)
    DB:Debug("Clicked on random, rehighlighting")
    self:HighlightText()
    self:SetCursorPosition(DB.randomIdLen)
  end)
  return true -- stay shown
end

function DB.OnMasterUIShow(widget, _data)
  DB:Debug("Master UI Show/Regen")
  local e = widget.editBox
  DB.randomEditBox = e
  local text = DB.fullName .. " " .. DB.RandomId(DB.randomIdLen) .. " " .. DB.RandomId(DB.randomIdLen) .. " "
  local hashC = DB.ShortHash(text)
  local newText = text .. hashC
  DB.MasterToken = newText
  e:SetText(newText)
  e:HighlightText()
  DB.fontString:SetFontObject(e:GetFontObject())
  DB.fontString:SetText(newText)
  local width = DB.fontString:GetStringWidth()
  DB:Debug("Width is %", width)
  e:SetWidth(width + 4) -- + some or highlights hides most of it/it doesn't fit
  local strLen = strlenutf8(newText) -- in glyphs
  e:SetMaxLetters(strLen)
  e:SetScript("OnMouseUp", function(self)
    DB:Debug("Clicked on random, rehighlighting")
    self:HighlightText()
    self:SetCursorPosition(#newText) -- this one is in bytes, not in chars (!)
  end)
  return true -- stay shown
end

StaticPopupDialogs["DYNBOXER_RANDOM"] = {
  text = "DynamicBoxer: optional random id to copy and paste",
  button1 = "Randomize",
  button2 = "Close",
  timeout = 0,
  whileDead = true,
  hideOnEscape = 1, -- doesn't help when there is an edit box, real stuff is:
  EditBoxOnEscapePressed = function(self)
    self:GetParent():Hide()
  end,
  OnShow = DB.OnRandomUIShow,
  OnAccept = DB.OnRandomUIShow,
  EditBoxOnEnterPressed = function(self, data)
    DB.OnRandomUIShow(self:GetParent(), data)
  end,
  EditBoxOnTextChanged = function(self, _data)
    -- ignore input and regen instead
    -- but avoid infinite loop
    if #self:GetText() ~= DB.randomIdLen then
      DB.OnRandomUIShow(self:GetParent())
    end
  end,
  hasEditBox = true
}
StaticPopupDialogs["DYNBOXER_MASTER"] = {
  text = "DynamicBoxer one time setup: copy this and paste in the other windows",
  button1 = OKAY,
  button2 = "Randomize",
  button3 = CANCEL,
  timeout = 0,
  whileDead = true,
  hideOnEscape = 1, -- doesn't help when there is an edit box, real stuff is:
  EditBoxOnEscapePressed = function(self)
    DB.OnUICancel(self:GetParent())
  end,
  OnAccept = DB.OnSetupUIAccept,
  OnAlt = DB.OnUICancel, -- this is the right side button, should be cancel to be consistent with 2 buttons
  OnCancel = DB.OnMasterUIShow, -- this is the middle button really, so randomize
  EditBoxOnEnterPressed = function(self, data)
    DB.OnSetupUIAccept(self:GetParent(), data)
  end,
  EditBoxOnTextChanged = function(self, _data)
    -- ignore input and regen instead
    -- but avoid infinite loop
    if strlenutf8(self:GetText()) ~= DB.uiTextLen then
      DB:Debug(4, "size mismatch % % %", #self:GetText(), strlenutf8(self:GetText()), DB.uiTextLen)
      DB.OnMasterUIShow(self:GetParent())
    end
  end,
  hasEditBox = true
}
StaticPopupDialogs["DYNBOXER_SLAVE"] = {
  text = "DynamicBoxer one time setup: Paste from Slot 1",
  button1 = OKAY,
  button2 = CANCEL,
  timeout = 0,
  whileDead = true,
  hideOnEscape = 1, -- doesn't help when there is an edit box, real stuff is:
  EditBoxOnEscapePressed = function(self)
    DB.OnUICancel(self:GetParent())
  end,
  OnShow = DB.OnSlaveUIShow,
  OnAccept = DB.OnSetupUIAccept,
  OnCancel = DB.OnUICancel,
  -- OnHide = DB.OnSlaveUIHide,
  EditBoxOnEnterPressed = function(self, data)
    local widget = self:GetParent()
    if widget.button1:IsEnabled() then
      DB.OnSetupUIAccept(widget, data)
    end
  end,
  EditBoxOnTextChanged = function(self, data)
    -- enable accept only after they paste a valid checksumed entry
    DB:Debug(4, "Slave EditBoxOnTextChanged called")
    if self:GetText() == data then
      return -- no changes since last time, done
    end
    self:GetParent().data = self:GetText()
    DB.OnSlaveUIShow(self:GetParent())
    if DB:IsValidToken(self:GetText()) then
      self:GetParent().button1:Enable()
    else
      self:GetParent().button1:Disable()
    end
  end,
  hasEditBox = true
}

function DB:IsValidToken(str)
  DB:Debug("Validating % (% vs min %)", str, #str, DB.tokenMinLen)
  if #str < DB.tokenMinLen then
    return false
  end
  local lastC = string.sub(str, #str) -- last character is ascii/alphanum so this works
  local begin = string.sub(str, 1, #str - 1)
  local sh, lh = DB.ShortHash(begin)
  DB:Debug("Hash of % is % / %, expecting %", begin, sh, lh, lastC)
  return lastC == sh
end

DB.inUI = false

function DB.SetupUI()
  DB:Debug(8, "SetupUI % % %", DB.inUI, DB.Channel, StaticPopupDialogs["DYNBOXER_CHANNEL"])
  if DB.inUI then
    DB:Debug(7, "Already in UI, skipping")
    return
  end
  DB.inUI = true
  -- DB.fullName= "aÁÁÁ" -- test with utf8 characters (2x bytes per accentuated char)
  -- "master-fullname token1 token2 h" (in glyphs, so need to use strlenutf8 on input/comparaison)
  DB.uiTextLen = DB.randomIdLen * 2 + strlenutf8(DB.fullName) + 4
  DB.tokenMinLen = DB.randomIdLen * 2 + 2 + 4
  if DB.ISBIndex == 1 then
    StaticPopup_Show("DYNBOXER_MASTER")
  else
    StaticPopup_Show("DYNBOXER_SLAVE")
  end
end

DB:Debug("dbox ui file loaded")
