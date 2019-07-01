--[[
  DynamicBoxer -- (c) 2009-2019 moorea@ymail.com (MooreaTv)
  Covered by the GNU General Public License version 3 (GPLv3)
  NO WARRANTY
  (contact the author if you need a different license)
]] --
-- our name, our empty default (and unused) anonymous ns
-- local _addon, _ns = ...
-- Created by DBoxInit
local DB = DynBoxer

DB.fontString = DB:CreateFontString() -- used for width calculations

-- this file already has widget as "self" so we still use . in the definitions here
-- for all the On*(widget...)

function DB.OnSlaveUIShow(widget, data)
  DB:Debug("Slave UI Show")
  local e = widget.editBox
  local newText = e:GetText()
  DB.fontString:SetFontObject(e:GetFontObject())
  -- just to get a starting length
  local len = strlenutf8(newText)
  local minLen = DB:CalcUITextLen("Aa")
  DB:Debug("Len field is % vs expected min % (%)", len, minLen, DB.uiTextLen)
  if len < minLen then
    -- do we have a master token (ie is this /dbox show and not /dbox init)
    if data and data.token and #data.token > 0 then
      newText = data.token
      e:SetText(newText)
    else
      -- width calc placeholder
      newText = "Placeholder-Kil'Jaeden DV4eNcgp DV4eNcgp W"
    end
  end
  DB.fontString:SetText(newText .. " W") -- add 1 extra character to avoid scrolling (!)
  local width = DB.fontString:GetStringWidth()
  DB:Debug("Width is % for %", width, newText)
  e:SetWidth(width)
  e:SetMaxLetters(0)
  e.Instructions:SetText("  Paste here from Slot 1")
  e:HighlightText()
  -- e:SetCursorPosition(#newText)
end

function DB.OnSetupUIAccept(widget, data, data2)
  DB:Debug("SetupUI Accept")
  DB:Debug(9, "SetupUI Accept w=% d1=% d2=%", widget, data, data2)
  local token = widget.editBox:GetText()
  -- returns isValid, master, tok1, tok2
  local valid, masterName, tok1, tok2 = DB:ParseToken(token)
  if not valid then
    DB:Warning("Invalid token % !", token)
    return true
  end
  widget.editBox:SetMaxLetters(0)
  widget:Hide()
  DB.inUI = false
  if DB.MasterToken == token and DB.enabled then
    DB:Debug("Exact same token set, done with setup")
    return
  end
  DB:SetSaved("MasterToken", token)
  DB.Channel = tok1
  DB.Secret = tok2
  DB.MasterName = masterName
  DB:Debug("Current master is %", masterName) -- we'll send it a message so it's box stops showing
  DB:AddMaster(masterName)
  DB:SetupChange() -- joining just after leaving seems to break so we need to wait next sync
  DB.enabled = true -- must be after the previous line which sets it off
  if DB.maxIter <= 0 then
    DB.maxIter = 1
  end
  DB.firstMsg = 1 -- force resync of master
end

function DB.OnUICancel(widget, _data)
  DB.enabled = false -- avoids a loop where we keep trying to ask user
  DB.inUI = false
  widget:Hide()
  widget.editBox:SetMaxLetters(0)
  DB:Error("User cancelled. Will not use DynamicBoxer until /reload or /dbox i")
end

function DB.OnShowUICancel(widget, _data)
  DB.inUI = false
  widget:Hide()
  DB:Warning("Escaped/cancelled from UI show (use <return> key to close normally when done copy pasting)")
end

function DB.OnMasterUIShow(widget, data)
  DB:Debug("Master UI Show/Regen data is %", data)
  local e = widget.editBox
  DB.randomEditBox = e
  local masterName, tok1, tok2
  widget.button3:Enable()
  if data and data.masterName and data.token1 and data.token2 then
    -- there is existing data to just show/reuse
    masterName = data.masterName
    tok1 = data.token1
    tok2 = data.token2
    widget.button2:Disable()
    if DB:WeAreMaster() then
      widget.button3:Disable() -- remove Cancel on master as there is nothing to cancel
    end
  else
    -- we are generating a new token, we are the master
    masterName = DB.fullName
    tok1 = DB:RandomId(DB.randomIdLen)
    tok2 = DB:RandomId(DB.randomIdLen)
    widget.button2:Enable()
  end
  local newText = DB:CreateToken(masterName, tok1, tok2)
  e:SetText(newText)
  e:HighlightText()
  DB.fontString:SetFontObject(e:GetFontObject())
  DB.fontString:SetText(newText)
  local width = DB.fontString:GetStringWidth()
  DB:Debug("Width is %", width)
  e:SetWidth(width + 4) -- + some or highlights hides most of it/it doesn't fit
  local strLen = strlenutf8(newText) -- in glyphs
  e:SetMaxLetters(strLen) -- allow paste of longer?
  e:SetScript("OnMouseUp", function(w)
    DB:Debug("Clicked on random, re-highlighting")
    w:HighlightText()
    w:SetCursorPosition(#newText) -- this one is in bytes, not in chars (!)
  end)
  return true -- stay shown
end

StaticPopupDialogs["DYNBOXER_MASTER"] = {
  text = "DynamicBoxer one time setup:\nCopy this and Paste in the other windows",
  button1 = OKAY,
  button2 = "Randomize",
  button3 = CANCEL,
  timeout = 0,
  whileDead = true,
  hideOnEscape = 1, -- doesn't help when there is an edit box, real stuff is:
  EditBoxOnEscapePressed = function(self, data)
    local widget = self:GetParent()
    data.OnUICancel(widget, data) -- rehooked by show only ui
  end,
  OnAccept = DB.OnSetupUIAccept,
  OnAlt = function(self, data) -- this is the right side button, should be cancel to be consistent with 2 buttons
    data.OnUICancel(self, data) -- rehooked by show only ui
  end,
  OnCancel = DB.OnMasterUIShow, -- this is the middle button really, so randomize
  EditBoxOnEnterPressed = function(self, data)
    DB.OnSetupUIAccept(self:GetParent(), data)
  end,
  OnShow = DB.OnMasterUIShow,
  EditBoxOnTextChanged = function(self, data)
    -- ignore input and regen instead
    -- but avoid infinite loop
    if strlenutf8(self:GetText()) ~= DB.uiTextLen then
      DB:Debug(4, "size mismatch % % %", #self:GetText(), strlenutf8(self:GetText()), DB.uiTextLen)
      DB.OnMasterUIShow(self:GetParent(), data)
    end
  end,
  hasEditBox = true
}
StaticPopupDialogs["DYNBOXER_SLAVE"] = {
  text = "DynamicBoxer one time setup:\nPaste from Slot 1\n(type /dbox show on master if needed)",
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
    local widget = self:GetParent()
    local text = self:GetText()
    if data and data.previous and text == data then
      return -- no changes since last time, done
    end
    if not widget.data then
      widget.data = {}
    end
    if not data then
      data = widget.data
    end
    data.previous = text
    DB.OnSlaveUIShow(widget, data)
    if DB:IsValidToken(text) then
      widget.button1:Enable()
    else
      widget.button1:Disable()
    end
  end,
  hasEditBox = true
}

function DB:IsValidToken(str)
  if type(str) ~= 'string' then
    DB:Warning("Passed non string to validate token: %", str)
    return false
  end
  DB:Debug("Validating % (% vs min %)", str, #str, DB.tokenMinLen)
  if #str < DB.tokenMinLen then
    return false
  end
  return self:UnHash(str)
end

-- returns isValid, master, tok1, tok2
function DB:ParseToken(token)
  -- consider allowing extra whitespace at end?
  local valid, orig = DB:IsValidToken(token)
  if not valid then
    return false
  end
  local masterName, channel, password = orig:match("^([^ ]+) ([^ ]+) ([^ ]+) $")
  if not masterName then
    DB:Debug("Malformed token %", token)
    return false
  end
  return true, masterName, channel, password
end

function DB:CreateToken(masterName, tok1, tok2)
  return self:AddHashKey(masterName .. " " .. tok1 .. " " .. tok2 .. " ")
end

DB.inUI = false

function DB:CalcUITextLen(masterName)
  if not masterName or masterName == "" then
    DB:Debug(2, "CalcUITextLen: No master name, using placeholder for now")
    -- placeholder
    masterName = "Foobar-SomeRealm"
  end
  return DB.randomIdLen * 2 + strlenutf8(masterName) + 4
end

function DB:SetupUI()
  DB:Debug(8, "SetupUI %", DB.inUI)
  if DB.inUI then
    DB:Debug(7, "Already in UI, skipping")
    return
  end
  DB.inUI = true
  -- DB.fullName= "aÁÁÁ" -- test with utf8 characters (2x bytes per accentuated char)
  -- "master-fullname token1 token2 h" (in glyphs, so need to use strlenutf8 on input/comparaison)
  DB.uiTextLen = DB:CalcUITextLen(DB.fullName)
  if DB:WeAreMaster() then
    StaticPopup_Show("DYNBOXER_MASTER", "txt1", "txt2", {OnUICancel = DB.OnUICancel})
  else
    StaticPopup_Show("DYNBOXER_SLAVE")
  end
end

function DB:ShowTokenUI()
  if DB.inUI then
    DB:Debug(1, "ShowTokenUI(): Already in UI, skipping")
    return
  end
  DB:Debug("ShowTokenUI %", DB.MasterToken)
  if not DB.MasterToken or #DB.MasterToken == 0 then
    DB:Warning("No token to show")
    return
  end
  DB.inUI = true
  local master = DB.MasterName
  if DB:WeAreMaster() then
    -- regen with us as actual master
    master = DB.fullName -- already done now in base file/all case so we don't msg old master
    DB.uiTextLen = DB:CalcUITextLen(master)
    StaticPopup_Show("DYNBOXER_MASTER", "txt1", "txt2",
                     {masterName = master, token1 = DB.Channel, token2 = DB.Secret, OnUICancel = DB.OnShowUICancel})
  else
    DB.uiTextLen = DB:CalcUITextLen(master)
    StaticPopup_Show("DYNBOXER_SLAVE", "txt1", "txt2", {token = DB.MasterToken})
  end
end

function DB:HideTokenUI()
  if not DB.inUI then
    DB:Debug(1, "HideTokenUI(): Already in not UI, skipping")
    return
  end
  if DB:WeAreMaster() then
    StaticPopup_Hide("DYNBOXER_MASTER")
  else
    StaticPopup_Hide("DYNBOXER_MASTER")
  end
  DB.inUI = false
end

--- Options panel ---

DB.optionsPanel = CreateFrame("Frame")
DB.optionsPanel.name = "DynamicBoxer"

function DB.optionsPanel:HandleOk()
  --DB:Warning("Generating lua error on purpose in DB.optionsPanel:HandleOk()")
  --error("testing errors")
end

function DB.optionsPanel.okay()
  DB:Debug("DB.optionsPanel.okay()")
  if DB.debug then
    -- expose errors
    xpcall(function()
      DB.optionsPanel:HandleOk()
    end, geterrorhandler())
  else
    -- normal behavior for interface option panel: errors swallowed by caller
    DB.optionsPanel:HandleOk()
  end
end

-- Add the panel to the Interface Options
InterfaceOptions_AddCategory(DB.optionsPanel)

---

DB:Debug("dbox ui file loaded")
