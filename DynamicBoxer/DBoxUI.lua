-- our name, our empty default (and unused) anonymous ns
local addon, ns = ...

-- Created by DBoxInit
local DB = DynBoxer

function DB.OnChannelUIShow(widget, data)
  DB:Debug("ChannelUI Show widget=% ---- data=%", widget, data)
  widget.editBox:SetText(DB.Channel)
  widget.editBox:HighlightText()
end

function DB.OnChannelUIAccept(widget, data, data2)
  DB:Debug("ChannelUI Accept w=% d1=% d2=%", widget, data, data2)
  DB:SetSaved("Channel", widget.editBox:GetText())
  StaticPopup_Hide("DYNBOXER_CHANNEL")
  DB.PasswordUI()
end

function DB.OnPasswordUIShow(widget, _data)
  DB:Debug("PasswordUI OnShow w=%", widget)
  widget.button1:Disable()
  widget.editBox:SetPassword(true)
end

function DB.OnPasswordUIHide(widget, _data)
  DB:Debug("PasswordUI OnHide w=%", widget)
  widget.button1:Enable()
  widget.editBox:SetText("")
  widget.editBox:SetPassword(false)
end

function DB.OnPasswordUIAccept(widget, data, data2)
  DB:Debug("PasswordUI Accept w=% d1=% d2=%", widget, data, data2)
  DB:SetSaved("Secret", widget.editBox:GetText())
  StaticPopup_Hide("DYNBOXER_PASSWORD")
  DB.enabled = true
  DB.inUI = false
  DB.joinDone = false -- force rejoin code
  DB:Join()
end

function DB.OnUICancel(widget, data)
  DB.enabled = false -- avoids a loop where we keep trying to ask user
  DB.inUI = false
  DB:Error("User cancelled. Will not use DynamicBoxer until /reload or /dbox i")
end

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
  StaticPopup_Show("DYNBOXER_CHANNEL")
end

function DB.PasswordUI()
  DB:Debug("PasswordUI % %", DB.Channel, StaticPopupDialogs["DYNBOXER_PASSWORD"])
  StaticPopup_Show("DYNBOXER_PASSWORD")
end

DB:Debug("dbox ui file loaded")
