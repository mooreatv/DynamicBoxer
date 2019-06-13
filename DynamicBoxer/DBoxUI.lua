-- our name, our empty default (and unused) anonymous ns
local addon, ns = ...

-- Created by DBoxInit
local DB = DynBoxer

DB.currentMainEditBox = nil
DB.randomEditBox = nil

function DB.OnChannelUIShow(widget, data)
  DB:Debug("ChannelUI Show")
  DB:Debug(9, "ChannelUI Show widget=% ---- data=%", widget, data)
  DB.currentMainEditBox = widget.editBox
  widget.editBox:SetText(DB.Channel)
  widget.editBox:HighlightText()
  widget.editBox:SetScript("OnTabPressed", function()
    DB:Debug("Tab pressed in channel, going to other dialog!")
    if DB.randomEditBox then
      DB.randomEditBox:SetFocus()
    end
  end)
end

function DB.OnChannelUIAccept(widget, data, data2)
  DB:Debug("ChannelUI Accept")
  DB:Debug(9, "ChannelUI Accept w=% d1=% d2=%", widget, data, data2)
  DB:SetSaved("Channel", widget.editBox:GetText())
  StaticPopup_Hide("DYNBOXER_CHANNEL")
  DB.PasswordUI()
end

function DB.OnPasswordUIShow(widget, data)
  DB:Debug("PasswordUI Show")
  DB:Debug(9, "PasswordUI OnShow w=%, d=%", widget, data)
  DB.currentMainEditBox = widget.editBox
  widget.button1:Disable()
  widget.editBox:SetPassword(true)
  widget.editBox:SetScript("OnTabPressed", function()
    DB:Debug("Tab pressed in password, going to other dialog!")
    if DB.randomEditBox then
      DB.randomEditBox:SetFocus()
    end
  end)
end

function DB.OnPasswordUIHide(widget, data)
  DB:Debug("PasswordUI OnHide")
  DB:Debug(9, "PasswordUI OnHide w=%, d=%", widget, data)
  widget.button1:Enable()
  widget.editBox:SetText("")
  widget.editBox:SetPassword(false)
  DB.currentMainEditBox = nil
end

function DB.OnPasswordUIAccept(widget, data, data2)
  DB:Debug("PasswordUI Accept")
  DB:Debug(9, "PasswordUI Accept w=% d1=% d2=%", widget, data, data2)
  DB:SetSaved("Secret", widget.editBox:GetText())
  StaticPopup_Hide("DYNBOXER_RANDOM")
  StaticPopup_Hide("DYNBOXER_PASSWORD")
  DB.enabled = true
  DB.inUI = false
  DB.joinDone = false -- force rejoin code
  DB:Join()
end

function DB.OnUICancel(_widget, _data)
  DB.enabled = false -- avoids a loop where we keep trying to ask user
  DB.inUI = false
  StaticPopup_Hide("DYNBOXER_RANDOM")
  DB.currentMainEditBox = nil
  DB:Error("User cancelled. Will not use DynamicBoxer until /reload or /dbox i")
end

DB.randomIdLen = 8

-- local x = 0

function DB.OnRandomUIShow(widget, _data)
  DB:Debug("Randomize UI Show/Regen")
  local e = widget.editBox
  DB.randomEditBox = e
  e:SetText(DB.RandomId(DB.randomIdLen))
  -- width test, alternate narrow and wide
  -- if x % 2 == 0 then
  --   e:SetText("12345678")
  -- else
  --   e:SetText("WWWWWWWW")
  -- end
  -- x = x + 1
  e:HighlightText()
  e:SetJustifyH("CENTER")
  -- e:SetFontObject(CombatTextFont)
  -- TODO: need to get real size, from FontString:GetStringWidth() - how to get the fontstr?
  local width = 12 * DB.randomIdLen
  -- width = e:GetStringWidth()
  e:SetWidth(width)
  e:SetMaxLetters(DB.randomIdLen)
  e:SetScript("OnTabPressed", function()
    DB:Debug("Tab pressed on random, switching!")
    DB.currentMainEditBox:SetFocus()
  end)
  e:SetScript("OnMouseUp",  function(self)
    DB:Debug("Clicked on random, rehighlighting")
    self:HighlightText()
    self:SetCursorPosition(DB.randomIdLen)
  end)
  return true -- stay shown
end

StaticPopupDialogs["DYNBOXER_RANDOM"] = {
  text = "DynamicBoxer: optional random id to copy and paste",
  button1 = "Randomize",
  button2 = "Close",
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
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
StaticPopupDialogs["DYNBOXER_CHANNEL"] = {
  text = "DynamicBoxer: One time setup step 1/2, set the channel to be the same on all windows",
  button1 = OKAY,
  button2 = CANCEL,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  OnShow = DB.OnChannelUIShow,
  OnAccept = DB.OnChannelUIAccept,
  OnCancel = DB.OnUICancel,
  EditBoxOnEnterPressed = function(self, data)
    DB.OnChannelUIAccept(self:GetParent(), data)
  end,
  hasEditBox = true
}
StaticPopupDialogs["DYNBOXER_PASSWORD"] = {
  text = "DynamicBoxer: One time setup step 2/2, broadcast enter (paste) the same secure unique password in all windows",
  button1 = OKAY,
  button2 = CANCEL,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  OnShow = DB.OnPasswordUIShow,
  OnAccept = DB.OnPasswordUIAccept,
  OnCancel = DB.OnUICancel,
  OnHide = DB.OnPasswordUIHide,
  EditBoxOnEnterPressed = function(self, data)
    local widget = self:GetParent()
    if widget.button1:IsEnabled() then
      DB.OnPasswordUIAccept(widget, data)
    end
  end,
  EditBoxOnTextChanged = function(self, _data)
    -- enable accept only after they type at least 5 characters
    DB:Debug(4, "Password EditBoxOnTextChanged called")
    if #self:GetText() >= DB.minSecretLength then
      self:GetParent().button1:Enable()
    else
      self:GetParent().button1:Disable()
    end
  end,
  hasEditBox = true
}

DB.inUI = false

function DB.ChannelUI()
  DB:Debug(8, "ChannelUI % % %", DB.inUI, DB.Channel, StaticPopupDialogs["DYNBOXER_CHANNEL"])
  if DB.inUI then
    DB:Debug(7, "Already in UI, skipping")
    return
  end
  DB.inUI = true
  StaticPopup_Show("DYNBOXER_RANDOM")
  StaticPopup_Show("DYNBOXER_CHANNEL")
end

function DB.PasswordUI()
  DB:Debug("PasswordUI % %", DB.Channel, StaticPopupDialogs["DYNBOXER_PASSWORD"])
  StaticPopup_Show("DYNBOXER_RANDOM") -- refresh already present one
  StaticPopup_Show("DYNBOXER_PASSWORD")
end

DB:Debug("dbox ui file loaded")
