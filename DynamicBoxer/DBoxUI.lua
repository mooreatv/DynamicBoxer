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
local L = DB.L

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
  if DB.MasterToken == token and DB.watched.enabled then
    DB:Debug("Exact same token set, done with setup")
    return
  end
  DB:SetSaved("MasterToken", token)
  DB.Channel = tok1
  DB.Secret = tok2
  DB.MasterName = masterName
  DB:Debug("Current master is %", masterName) -- we'll send it a message so it's box stops showing
  DB:AddToMasterHistory(masterName)
  DB:SetupChange() -- joining just after leaving seems to break so we need to wait next sync
  DB.watched.enabled = true -- must be after the previous line which sets it off
  if DB.maxIter <= 0 then
    DB.maxIter = 1
  end
  DB.noMoreExtra = nil
  DB.crossRealmMaster = nil
  DB.firstMsg = 1 -- force resync of master
end

function DB.OnUICancel(widget, _data)
  DB.watched.enabled = false -- avoids a loop where we keep trying to ask user
  DB.inUI = false
  widget:Hide()
  widget.editBox:SetMaxLetters(0)
  if DB.MasterToken and #DB.MasterToken > 0 then
    DB:Warning("Escaped/cancelled from exchange token UI (use <return> key to close normally when done copy pasting)")
  else
    DB:Error("User cancelled. Will not use DynamicBoxer until /reload or /dbox i")
  end
end

function DB.OnShowUICancel(widget, _data)
  DB.inUI = false
  DB.uiEscaped = true
  widget:Hide()
  DB:Warning("Escaped/cancelled from show token UI (use <return> key to close normally when done copy pasting)")
end

function DB.OnMasterUIShow(widget, data)
  DB:Debug("Master UI Show/Regen data is %", data)
  local e = widget.editBox
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
  DB.uiEscaped = false
  DB.inUI = true
  -- DB.fullName= "aÁÁÁ" -- test with utf8 characters (2x bytes per accentuated char)
  -- "master-fullname token1 token2 h" (in glyphs, so need to use strlenutf8 on input/comparison)
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
  DB.uiEscaped = false
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

DB.uiShowWarning = true -- one time

DB.disablePopUps = false

-- this is called by automatic detection (and should stop when the user escaped out)
function DB:ShowAutoExchangeTokenUI(msg, ...)
  if not DB.watched.enabled then
    DB:Debug("Not showing token exchange UI because we're now disabled (%)", msg)
    return
  end
  if DB.disablePopUps then
    if DB.uiShowWarning then
      DB:Warning("Not showing automatic Pop Up exchange UI because you opted not too" ..
        " (team may not complete, /dbox config to fix).", msg)
      if msg then
          DB:PrintDefault("NOT " .. msg, ...)
      end
      DB.uiShowWarning = false
    else
      DB:Debug("Not showing exchange token UI because of pop up disabled and also already shown once warning (%)", msg)
    end
    return
  end
  if DB.uiEscaped then
    if DB.uiShowWarning then
      DB:Warning("Not showing automatic token exchange UI because you escaped one before. Use /dbox x to see one.")
      DB.uiShowWarning = false
    else
      DB:Debug("Not showing exchange token UI because of previous escape and also already shown warning (%)", msg)
    end
    return
  end
  if msg then
    DB:PrintDefault(msg, ...)
  end
  DB:ExchangeTokenUI()
end

-- this is called based on explicit user action
function DB:ExchangeTokenUI()
  if DB.inUI then
    DB:Debug(1, "ExchangeTokenUI(): Already in UI, skipping")
    return
  end
  DB:Debug("ExchangeTokenUI %", DB.MasterToken)
  DB.uiEscaped = false
  if DB:WeAreMaster() then
    return DB:ShowTokenUI()
  end
  DB.inUI = true
  -- start empty on slaves so copy copies the right one
  DB.uiTextLen = DB:CalcUITextLen(DB.fullName)
  StaticPopup_Show("DYNBOXER_SLAVE")
end

function DB:HideTokenUI()
  if not DB.inUI then
    DB:Debug(1, "HideTokenUI(): Already in not UI, skipping")
    return
  end
  if DB:WeAreMaster() then
    StaticPopup_Hide("DYNBOXER_MASTER")
  else
    StaticPopup_Hide("DYNBOXER_SLAVE")
  end
  DB.inUI = false
end

--- Options panel ---

function DB:CreateOptionsPanel()
  if DB.optionsPanel then
    DB:Debug("Options Panel already setup")
    return
  end
  DB:Debug("Creating Options Panel")

  local p = DB:Frame(_G.DYNAMICBOXER)
  DB.optionsPanel = p

  --  DB.widgetDemo = true -- to show the demo (or `DB:SetSaved("widgetDemo", true)`)

  -- TODO: look into i18n
  -- Q: maybe should just always auto place (add&place) ?
  p:addText("DynamicBoxer options", "GameFontNormalLarge"):Place()
  p:addText("These options let you control the behavior of DynamicBoxer " .. DB.manifestVersion ..
              " @project-abbreviated-hash@\n" ..
              "Most actions can also be done by mousing over the status window or through keybindings."):Place()
  local autoInvite = p:addCheckBox("Auto invite",
                                   "Whether one of the slot should auto invite the others\n" ..
                                     "it also helps with cross realm teams sync\n" ..
                                     "|cFF99E5FF/dbox autoinvite|r to toggle or set slot"):Place(4, 30)

  -- TODO tooltip formatting and maybe auto add the /dbox command

  p:addButton("Invite Team", "Invites to the party the team members\ndetected so far and not already in party\n" ..
                "|cFF99E5FF/dbox p|r or Key Binding", "party invite"):PlaceRight()

  p:addButton("Disband", "If party leader, Uninvite the members of the team,\npossibly leaving guests." ..
                "Otherwise, leave the party\n|cFF99E5FF/dbox p disband|r or Key Binding", "party disband"):PlaceRight()

  local invitingSlot = p:addSlider("Party leader slot", "Sets which slot should be doing the party inviting\n" ..
                                     "or e.g |cFF99E5FF/dbox autoinv 5|r for invites from slot 5", 1,
                                   math.max(5, DB.expectedCount)):Place(16, 14) -- need more vspace

  local maxParty = p:addSlider("Group size", "Split in groups of this size\n" ..
                                 "or e.g |cFF99E5FF/dbox partymax 4|r for groups of 4 max; 5 for unlimited/raid", 2, 5,
                               1, nil, "unlimited"):PlaceRight(32)

  local autoRaid = p:addCheckBox("Auto convert to raid",
                                 "Whether to auto convert to raid before inviting the 6th party member\n" ..
                                   "|cFF99E5FF/dbox raid|r"):Place(4, 6)

  local delayAccept = p:addCheckBox("Delay invite accept",
                                    "Whether to delay the invite accept in order to keep the team in slot order")
                        :PlaceRight(20)

  autoInvite:SetScript("PostClick", function(w, button, down)
    DB:Debug(3, "ainv post click % %", button, down)
    if w:GetChecked() then
      invitingSlot:DoEnable()
      autoRaid:DoEnable()
    else
      invitingSlot:DoDisable()
      autoRaid:DoDisable()
    end
  end)

  p:addButton("Identify",
              "Shows the big identification text (faction, slot, name, realm)\n" .. "|cFF99E5FF/dbox identify|r",
              "identify"):Place(0, 18)
  local idAtStart = p:addCheckBox("Show slot info at start",
                                  "Shows the big identification text (faction, slot, name, realm) during startup")
                      :PlaceRight()

  local statusFrameScale = p:addSlider("Status Frame Scale", "Sets the zoom/scale of the status window\n" ..
                                         "You can also mousewheel on the window.", 0.75, 4, .05):Place(16, 28)

  statusFrameScale.callBack = function(_w, val)
    DB.statusFrame:ChangeScale(val)
    DB.statusFrame:Snap()
  end

  local fullViewButton = p:addCheckBox("Full view", "Selects full or compact view\nfor the status window"):PlaceRight(
                           16, -8)

  p:addButton("Reset Window",
              "Resets the DynamicBoxer status window position back to default\n|cFF99E5FF/dbox reset status|r",
              function()
    statusFrameScale:SetValue(1)
    DB:StatusResetPos()
    p.savedCurrentScale = nil
    DB:Warning("Saved window status position cleared per request and window reset to top right")
  end):PlaceRight(16, 2)

  p:addButton("Exchange Token", "Shows the token on master and empty ready to paste on slaves\n" ..
                "Allows for very fast broadcast KeyBind, Ctrl-C (copy) Ctrl-V (paste) Return, 4 keys and done!\n" ..
                "|cFF99E5FF/dbox xchg|r or better, set a Key Binding", "xchg"):Place(0, 24)

  p:addButton("Show Token", "Shows the UI to show or set the current token string\n" ..
                "(if you need to copy from slave to brand new master, otherwise use xchg)\n" ..
                "|cFF99E5FF/dbox show|r or Key Binding", "show"):PlaceRight(20)

  p:addButton("Force Team Complete", "Forces the current team to be assumed to be completed despite missing slots\n" ..
                "|cFF99E5FF/dbox team complete|r", "team complete"):PlaceRight(20)

  p:addText("Development, troubleshooting and advanced options:"):Place(40, 20)

  local enabled = p:addCheckBox("Addon Enabled", "Is the addon is currently active? " ..
                                  "Pausing helps if you would be logging in/out many cross realm characters without autoinvite\n" ..
                                  "|cFF99E5FF/dbox enable off|r\nor |cFF99E5FF/dbox enable on|r to toggle"):Place(4, 10)

  local disablePopUps = p:addCheckBox("Pop ups disabled", "Disable prompts to enter or copy paste the token. " ..
                "This will typically prevent your team from completing" ..
                "when adding new characters so should stay unchecked for most users.\n" ..
                "|cFF99E5FF/dbox u off|r to disable popups,\n|cFF99E5FF/dbox u on|r to restore."):PlaceRight(10)

  p:addButton("Bug Report", "Get Information to submit a bug.\n|cFF99E5FF/dbox bug|r", "bug"):PlaceRight(40, 1)

  p:addButton("Export Keybindings", "Exports your current key bindings.\n|cFF99E5FF/dbox keys|r", "keys"):PlaceRight(40)

  p:addButton("Re Init", "Re initializes like the first time setup.\n|cFF99E5FF/dbox init|r", "init"):Place(0, 12)
  p:addButton("Join", "Attempts to resync the team by\nsending a message requiring reply\n|cFF99E5FF/dbox j|r", "join")
    :PlaceRight()
  p:addButton("Ping", "Attempts to resync the team by\nsending a message\n|cFF99E5FF/dbox m|r", "message"):PlaceRight()

  local debugLevel = p:addSlider("Debug level", "Sets the debug level\n|cFF99E5FF/dbox debug X|r", 0, 9, 1, "Off")
                       :Place(16, 30)

  p:addButton("Event Trace", "Starts the blizzard Event Trace with DynamicBoxer saved filters\n|cFF99E5FF/dbox event|r",
              "event"):Place(0, 20)

  p:addButton("Save Filters", "Saves the set of currently filtered Events\n|cFF99E5FF/dbox event save|r", "event save")
    :PlaceRight()

  p:addButton("Clear Filters", "Clear saved filtered Events\n|cFF99E5FF/dbox event clear|r", "event clear"):PlaceRight()

  p:addText("Choose a |cFFFF1010reset|r option:"):Place(0, 30)

  -- TODO add confirmation before reset all
  local bReset = p:addButton("Reset!", "Choose what to reset in the drop down...", function(w)
    DB.Slash(w.resetCmd)
  end)

  local cb = function(value)
    DB:Debug("drop down call back called with %", value)
    bReset:Enable()
    bReset.resetCmd = value
  end

  p:addDrop("...select...", "dropdown tool tip", cb, {
    {
      text = "Reset All",
      tooltip = "Resets all the DynamicBoxer saved variables\n(reload needed after this)\n|cFF99E5FF/dbox reset all|r",
      value = "reset all"
    }, {
      text = "Reset Team",
      tooltip = "Reset the isboxer team detection\n(for next login)\n|cFF99E5FF/dbox reset teams|r",
      value = "reset teams"
    }, {
      text = "Reset Token",
      tooltip = "Forgets the secure token,\nwill cause the Show/Set dialog for next login\n|cFF99E5FF/dbox reset token|r",
      value = "reset token"
    }, {
      text = "Reset Master History",
      tooltip = "Resets the master history for this faction\n(will require setting next login)\n|cFF99E5FF/dbox reset masters|r",
      value = "reset masters"
    }, {
      text = "Reset Members History",
      tooltip = "Resets the team members history for this faction\n|cFF99E5FF/dbox reset members|r",
      value = "reset members"
    }, {
      text = "Reset Status Position",
      tooltip = "Resets the status window position\n|cFF99E5FF/dbox reset status|r",
      value = "reset status"
    }
  }):PlaceRight(-10, -7.5)

  bReset:PlaceRight(0, 2.5)
  bReset:Disable()

  function p:refresh()
    DB:Debug("Options Panel refresh!")
    if DB.debug then
      -- expose errors
      xpcall(function()
        self:HandleRefresh()
      end, geterrorhandler())
    else
      -- normal behavior for interface option panel: errors swallowed by caller
      self:HandleRefresh()
    end
  end

  function p:HandleRefresh()
    p:Init()
    debugLevel:SetValue(DB.debug or 0)
    p.savedCurrentScale = DB.statusScale or 1
    statusFrameScale:SetValue(DB.statusScale)
    invitingSlot:SetValue(DB.autoInviteSlot)
    if DB.autoInvite then
      autoInvite:SetChecked(true)
      invitingSlot:DoEnable()
      autoRaid:DoEnable()
    else
      autoInvite:SetChecked(false)
      invitingSlot:DoDisable()
      autoRaid:DoDisable()
    end
    if DB.watched.enabled then
      enabled:SetChecked(true)
    else
      enabled:SetChecked(false)
    end
    delayAccept:SetChecked(DB.delayAccept)
    autoRaid:SetChecked(DB.autoRaid)
    idAtStart:SetChecked(DB.showIdAtStart)
    fullViewButton:SetChecked(DB.watched.fullTeamInfo)
    maxParty:SetValue(DB.maxParty)
    disablePopUps:SetChecked(DB.disablePopUps)
  end

  function p:HandleOk()
    DB:Debug(1, "DB.optionsPanel.okay() internal")
    local sliderVal = debugLevel:GetValue()
    if sliderVal == 0 then
      sliderVal = nil
      if DB.debug then
        DB:PrintDefault("Options setting debug level changed from % to OFF.", DB.debug)
      end
    else
      if DB.debug ~= sliderVal then
        DB:PrintDefault("Options setting debug level changed from % to %.", DB.debug, sliderVal)
      end
    end
    DB:SetSaved("debug", sliderVal)
    local en = enabled:GetChecked()
    if en ~= DB.watched.enabled then
      if en then
        DB.Slash("enable")
        DB.Slash("join")
      else
        DB.Slash("enable off")
      end
    end
    local ainv = autoInvite:GetChecked()
    DB:SetSaved("autoInvite", ainv)
    local ainvSlot = invitingSlot:GetValue()
    DB:SetSaved("autoInviteSlot", ainvSlot)
    local raid = autoRaid:GetChecked()
    DB:SetWatchedSaved("fullTeamInfo", fullViewButton:GetChecked())
    DB:SetSaved("autoRaid", raid)
    local maxP = maxParty:GetValue()
    DB:SetSaved("maxParty", maxP)
    DB:SetSaved("showIdAtStart", idAtStart:GetChecked())
    DB:SetSaved("delayAccept", delayAccept:GetChecked())
    DB:SetSaved("disablePopUps", disablePopUps:GetChecked())
    DB:PrintDefault("DynamicBoxer configuration: auto invite is " .. (ainv and "ON" or "OFF") ..
                      " for slot %, auto raid is " .. (raid and "ON" or "OFF") .. " max party is " ..
                      (maxP == 5 and "unlimited" or tostring(maxP)), ainvSlot)
    DB:SavePosition(DB.statusFrame)
  end

  function p:cancel()
    DB:Warning("Options screen cancelled, not making any changes.")
    -- warning no errors logged if any
    if p.savedCurrentScale then
      DB.statusFrame:ChangeScale(p.savedCurrentScale) -- revert it to previous value
      DB.statusFrame:Snap()
    end
  end

  function p:okay()
    DB:Debug(3, "DB.optionsPanel.okay() wrapper")
    if DB.debug then
      -- expose errors
      xpcall(function()
        self:HandleOk()
      end, geterrorhandler())
    else
      -- normal behavior for interface option panel: errors swallowed by caller
      self:HandleOk()
    end
  end
  -- Add the panel to the Interface Options
  InterfaceOptions_AddCategory(DB.optionsPanel)
end

local slotToText = function(self, slot)
  DB:Debug("Called slotToText %", slot)
  if not slot then
    self:SetText("?")
    self:SetTextColor(1, 0.3, 0.2)
    return
  end
  self:SetText(string.format("%d", slot))
  if slot <= 0 then
    self:SetTextColor(0.96, 0.63, 0.26)
  else
    self:SetTextColor(.2, .9, .15)
  end
end

local slotInfo = function(slot, last)
  DB:Debug("Called slotInfo %", slot)
  local name = DB.watched[slot]
  local fmt = "%d"
  if last > 9 then
    fmt = "%02d"
  end
  if not name then
    return string.format("|cFFFF4C43" .. fmt .. "|r  |cFFF4A042???|r", slot), "" -- "|cFFA040FF?|r"
  end
  local short, realm = DB:SplitFullName(name)
  local color = "40C0FF"
  if realm == DB.myRealm then
    color = "A040FF"
  end
  return string.format("|cFF33E526" .. fmt .. "|r  |cFFF2D80C%s|r", slot, short),
         string.format("|cFF%s%s|r", color, realm)
end

--- *** Status and runtime frame *** ---

DB.statusUp = false

DB.watched.fullTeamInfo = true

function DB:AddTeamStatusUI(f)
  if not f then
    return
  end
  if DB.expectedCount <= 0 or DB.statusUp then
    DB:RestorePosition(f, DB.statusPos, DB.statusScale)
    return -- already done
  end
  DB.statusUp = true
  -- save state of first line done
  DB.statusXn = f.numObjects
  DB.statusXa = f.lastAdded
  DB.statusXl = f.lastLeft
  DB.statusXm = f.leftMargin
  DB:RestorePosition(f, DB.statusPos, DB.statusScale)
  local viewSelect = function(_k, v, _oldVal)
    -- remove current lower status
    for i = #f.children, DB.statusXn + 1, -1 do
      DB:Debug("Removing widget #%", i)
      -- probably should return to pool instead but we don't do this that often
      f.children[i] = DB:WipeFrame(f.children[i])
    end
    -- restore state
    f.lastAdded = DB.statusXa
    f.lastLeft = DB.statusXl
    f.numObjects = DB.statusXn
    f.leftMargin = DB.statusXm
    if v then
      DB:AddPartyLines(f, DB.watched.slot)
    else
      DB:AddStatusLine(f)
    end
    -- DB:RestorePosition(f, DB.statusPos, DB.statusScale)
    f:Snap()
    local padding = 1 / 32 -- need to be ever so slighting inside or it doesn't always show
    f:addBorder(padding, padding, 1, 0, 0, 0, 1, "ARTWORK")
  end
  DB.watched:AddWatch("fullTeamInfo", viewSelect)
  viewSelect(nil, DB.watched.fullTeamInfo)
end

function DB:AddStatusLine(f)
  DB:Debug("Adding team line! %", DB.expectedCount)
  -- should center instead of this
  local offset = 29 - 4 * DB.expectedCount
  if offset < -4 then
    offset = -4
  end
  f:addText(""):Place(offset, 2)
  local y = 0
  local mySlot = DB.watched.slot
  for i = 1, DB.expectedCount do
    local x = 4
    if i == mySlot then
      f:addText(">"):PlaceRight(x, 2):SetTextColor(0.7, 0.7, 0.7)
      x = 0
      y = -2
    end
    local status = f:addText("?", f.font):PlaceRight(x, y)
    if i == mySlot then
      f:addText("<"):PlaceRight(0, 2):SetTextColor(0.7, 0.7, 0.7)
    else
      y = 0
    end
    DB.watched:AddWatch(i, function(k, v, _oldVal)
      slotToText(status, v and k)
    end)
    slotToText(status, DB.watched[i] and i)
  end
  local partySize = f:addText("(" .. tostring(DB.expectedCount) .. ")"):PlaceRight(4, y + 1)
  partySize:SetTextColor(.95, .85, .05)
end

function DB:AddPartyLines(f, mySlot)
  local yOffset = 2
  local last = DB.expectedCount
  for i = 1, last do
    local left, right = slotInfo(i, last)
    local w = f:addText(left):Place(3, yOffset)
    local wR = f:addText(right)
    wR:SetJustifyH("RIGHT")
    wR:SetHeight(wR:GetStringHeight()) -- this is key to prevent multiline / wrapped text; avoids having to do 2 passes
    yOffset = 0
    DB.watched:AddWatch(i, function(k, _v, _oldVal)
      local l, r = slotInfo(k, last)
      w:SetText(l)
      wR:SetText(r)
      f:Snap()
    end)
    if i == mySlot then
      f:addText(">"):PlaceLeft(1, 0.5):SetTextColor(0.75, 0.75, 0.75)
    end
    wR:PlaceRight(2)
    wR.extraWidth = 3
    wR:SetPoint("RIGHT", -wR.extraWidth, 0)
    wR:SetMaxLines(1)
  end
end

-- attach to top of the screen by default but not right in the middle to not cover blizzard headings
function DB:StatusInitialPos()
  local w = UIParent:GetWidth()
  -- so we can see our neat 1 pixel black border, put the frame 2 pixels down from top (2 because we snap on even pixel anyway)
  DB.statusPos = {"TOP", w / 5, -2} -- /DB:PixelPerfectFrame():GetScale()}
  DB.statusScale = 1
end

function DB:StatusResetPos()
  dynamicBoxerSaved.statusPos = nil
  dynamicBoxerSaved.statusScale = nil
  DB:StatusInitialPos()
  DB:RestorePosition(DB.statusFrame, DB.statusPos, DB.statusScale)
end

function DB:SetupHugeFont(height)
  if DB.hugeFont then
    return DB.hugeFont
  end
  height = height or 120 -- doesn't get bigger than 120 anyway
  DB.hugeFont = CreateFont("DynBoxerHuge")
  local baseFont = Game120Font:GetFont()
  DB:Debug("base font is %", baseFont)
  local ret = DB.hugeFont:SetFont(baseFont, height) -- "THICKOUTLINE")
  DB:Debug("Set font for height % : %", height, ret)
  DB.hugeFont:SetTextColor(.95, .85, .05, .9)
  DB.hugeFont:SetShadowOffset(3, -3)
  DB.hugeFont:SetShadowColor(0, 0, 0, .9)
  return DB.hugeFont
end

DB:PreloadTextures(516953, 516949, 616345)

function DB:GetFactionTexture(p, faction)
  local t
  local baseId, glowId
  local size = 90
  if faction == "Horde" then
    baseId = 516953
  elseif faction == "Alliance" then
    baseId = 516949
    size = 100 -- horde one is a bit taller so we enlarge alliance it a bit
  else
    baseId = 616345
    glowId = 616345
  end
  if not glowId then
    glowId = baseId + 1
  end
  t = p:addAnimatedTexture(baseId, glowId)
  t:SetSize(size, size)
  t.linked:SetSize(size, size)
  t:SetVertexColor(.85, .85, .85) -- darken the base
  t:SetIgnoreParentAlpha(true)
  return t
end

function DB:ShowBigInfo(autohide)
  DB:Debug("ShowBigInfo")
  if autohide then
    if DB.autoHideBigInfo then
      DB:Debug("ShowBigInfo: cancelling previous autohide")
      DB.autoHideBigInfo:Cancel()
    end
    DB.autoHideBigInfo = C_Timer.NewTimer(autohide, function()
      DB:Debug("ShowBigInfo: Hiding")
      DB.bigInfo:Hide()
      DB.autoHideBigInfo = nil
    end)
  end
  if DB.bigInfo then
    DB:Debug("ShowBigInfo: Showing")
    DB.bigInfo:Show()
    return
  end
  DB:Debug("ShowBigInfo: Creating")
  DB.bigInfo = DB:Frame("DynBoxer_big_info")
  local f = DB.bigInfo
  -- f:SetParent(WorldFrame) -- so it's visible with alt-z too
  f:SetFrameStrata("FULLSCREEN")
  f:SetAlpha(.85)
  -- Calculate inner square with border for this frame
  -- TODO: add a "recenter" to molib after scale()
  DB:Debug("w % h % s % %", WorldFrame:GetWidth(), WorldFrame:GetHeight(), f:GetScale(), f:GetEffectiveScale())
  local percent = 95 / 100.
  local parent = f:GetParent()
  f:SetSize(parent:GetWidth() * percent, parent:GetHeight() * percent) -- margin in proportion with aspect ratio
  f:SetPoint("TOP", 0, -parent:GetHeight() * (1. - percent) / 2.)
  local fo = DB:SetupHugeFont() -- can't really scale past 120 anyway
  -- -6 for 1, the other don't need that much delta(!)
  local slotStr = tostring(DB.ISBIndex or "???")
  local offset = -3 -- most digits seem offset by a little to the right in their box
  if slotStr == "1" then
    offset = -8 -- 1 has a huge offset
  end
  local s = f:addText(slotStr, fo):Place(offset, 20, "TOP", "BOTTOM")
  s:SetJustifyH("CENTER")
  s:SetJustifyV("CENTER")
  local t = DB:GetFactionTexture(f, DB.faction)
  if t then
    local offx = 12
    local offy = 0
    if DB.faction == "Neutral" then
      -- panda icon is different/offset
      offx = -8
      offy = -4
    end
    t:PlaceLeft(offx, offy, "RIGHT", "LEFT") -- won't change lastLeft
  end
  local class = f:addTexture()
  if DB.isClassic then
    local _, className = UnitClass("player")
    class:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
    class:SetTexCoord(unpack(CLASS_ICON_TCOORDS[className]))
  else
    local spec = GetSpecialization() -- missing in classic
    local _, _, _, icon = GetSpecializationInfo(spec)
    class:SetTexture(icon)
  end
  class:SetSize(30, 30)
  class:PlaceRight(16, 0, "LEFT", "RIGHT")
  local n = f:addText(DB.shortName, fo):Place(0, -6, "TOP", "BOTTOM")
  n:SetJustifyH("CENTER")
  n:SetJustifyV("CENTER")
  n:SetTextColor(.6, .9, 1, .9)
  local r = f:addText(DB.myRealm, fo):Place(0, 16, "TOP", "BOTTOM")
  r:SetJustifyH("CENTER")
  r:SetJustifyV("CENTER")
  f:Scale(0) -- override padding
  DB:Debug("w % h % s % %", f:GetWidth(), f:GetHeight(), f:GetScale(), f:GetEffectiveScale())
end

function DB:SetupStatusUI()
  if DB.statusFrame then
    DB:Debug(1, "Status frame already created")
    return
  end
  DB:Debug(1, "Creating Status frame")
  if not DB.statusPos then
    DB:StatusInitialPos()
  end
  local f = DB:Frame("DynamicBoxer_Status", "DynamicBoxer_Status")
  DB.statusFrame = f
  f:SetFrameStrata("FULLSCREEN")
  f.Modifiers = {}
  f:SetScript("OnEvent", function(w, _ev, key, state)
    DB:Debug("modifier % % %", w:GetName(), key, state)
    if state == 0 then
      DB:Debug("Using default tooltip and resetting mod for ", key)
      f.Modifiers[key] = nil
      if w.defaultTooltipText then
        w.tooltipText = w.defaultTooltipText
      end
      DB:ShowToolTip(w)
      return
    end
    f.Modifiers[key] = true
    if w.tooltipTextMods and w.tooltipTextMods[key] then
      DB:Debug("Using tooltip for %", key)
      w.tooltipText = w.tooltipTextMods[key]
      DB:ShowToolTip(w)
      return
    end
  end)

  f.font = DB:NormalizeFont("GameFontHighlightLeft")
  local heading = "|cFFF2D80CDynamicBoxer|r " .. DB.manifestVersion .. " help:\n\n" ..
                    "Shows your current dynamic mapping\n(|cFF33E526green|r number is known, |cFFFF4C43?|r is unknown)\n\n"
  f.defaultTooltipText = heading .. "|cFF99E5FFLeft click|r to invite\n" .. "|cFF99E5FFMiddle|r click to disband\n" ..
                           "|cFF99E5FFRight|r click for options\n\n" .. "Drag the frame to move it anywhere.\n" ..
                           "Mousewheel to resize it\n\n" ..
                           "Press |cFF99E5FFTAB|r to see large on-screen slot information.\n" ..
                           "Hold |cFF99E5FFShift|r, |cFF99E5FFControl|r, |cFF99E5FFAlt|r keys for more tips."
  f.tooltipTextMods = {}
  f.tooltipTextMods.LSHIFT = heading .. "|cFF99E5FFShift Left click|r to toggle party/raid\n" ..
                               "|cFF99E5FFShift Right click|r to switch between compact and full view\n" ..
                               "|cFF99E5FFAlt Shift Right|r click to |cFFFF4C43disable|r (pause) the addon"
  f.tooltipTextMods.LCTRL = heading .. "|cFF99E5FFControl Left click|r to toggle autoinvite\n" ..
                              "|cFF99E5FFControl Middle click|r to force the team to be considered complete\n" ..
                              "|cFF99E5FFControl Right|r click to open the token exchange dialog."
  f.tooltipTextMods.LALT = heading .. "|cFF99E5FFAlt Left click|r to send a resync message\n" ..
                             "|cFF99E5FFAlt Right|r click to (re)|cFF33E526enable|r or\n" ..
                             "|cFF99E5FFAlt Shift Right|r click to |cFFFF4C43disable|r (pause) the addon"

  f.tooltipText = f.defaultTooltipText
  f:SetScript("OnEnter", function()
    -- f:SetPropagateKeyboardInput(false)
    f:EnableKeyboard(true)
    f:RegisterEvent("MODIFIER_STATE_CHANGED")
    DB:ShowToolTip(f)
  end)
  f:SetScript("OnLeave", function()
    -- f:SetPropagateKeyboardInput(true)
    f:UnregisterEvent("MODIFIER_STATE_CHANGED")
    f:EnableKeyboard(false)
    GameTooltip:Hide()
    DB:Debug("Hide tool tip...")
  end)
  f:SetPropagateKeyboardInput(true)
  f:SetScript("OnKeyDown", function(w, k)
    DB:Debug("Onkeydown % % %", w:GetName(), k)
    if k == "TAB" then
      DB:ShowBigInfo()
      w:SetPropagateKeyboardInput(false)
    else
      w:SetPropagateKeyboardInput(true)
    end
  end)
  f:SetScript("OnKeyUp", function(w, k)
    DB:Debug("Onkeyup % % %", w:GetName(), k)
    if k == "TAB" then
      DB.bigInfo:Hide()
    end
  end)
  f:EnableKeyboard(false) -- starts off
  DB:MakeMoveable(f, DB.SavePositionCB)
  f:EnableMouse(true)
  f:EnableMouseWheel(true)
  f.mouseWheelTimer = nil
  f:SetScript("OnMouseWheel", function(_w, direction)
    if direction > 0 then
      f:ChangeScale(f:GetScale() * 1.05)
    else
      f:ChangeScale(f:GetScale() * .95)
    end
    -- don't keep saving, only when adjustments quiet down
    if f.mouseWheelTimer then
      f.mouseWheelTimer:Cancel()
    end
    f.mouseWheelTimer = C_Timer.NewTimer(.5, function()
      DB:SavePosition(f) -- might save the wrong anchor one
    end)
  end)
  f:SetScript("OnMouseUp", function(_w, mod)
    DB:Debug("Clicked on party size %", mod)
    if mod == "LeftButton" then
      if IsControlKeyDown() then
        DB.Slash("autoinvite toggle")
      elseif IsShiftKeyDown() then
        DB.Slash("party toggle")
      elseif IsAltKeyDown() then
        DB.Slash("join")
      else
        DB.Slash("party invite")
      end
    elseif mod == "RightButton" then
      if IsControlKeyDown() then
        DB.Slash("xchg")
      elseif IsAltKeyDown() then
        if IsShiftKeyDown() then
          DB.Slash("enabled off")
        else
          DB.Slash("enable")
          DB.Slash("join")
        end
      elseif IsShiftKeyDown() then
        DB:SetWatchedSaved("fullTeamInfo", not DB.watched.fullTeamInfo)
      else
        DB.Slash("config")
      end
    else
      -- middle click
      if IsControlKeyDown() then
        DB.Slash("team complete")
        return
      end
      DB.Slash("party disband")
    end
  end)
  f:SetWidth(1)
  f:SetHeight(1) -- will recalc below
  f.bg = f:CreateTexture(nil, "BACKGROUND")
  f.bg:SetAllPoints()
  f.bgColor = {.1, .2, .7, 1}
  f.bgColorHex = DB:RgbToHex(unpack(f.bgColor))
  f.bg:SetColorTexture(unpack(f.bgColor))
  DB:Debug("Status frame background color % -> %", f.bgColor, f.bgColorHex)
  f:SetAlpha(.75)
  local title = f:addText(self.name, f.font):Place(4, 4) -- that also defines the bottom right padding
  f:addText(" on ", f.font):PlaceRight(0, 0):SetTextColor(0.9, 0.9, 0.9)
  f.slotNum = f:addText("?", f.font):PlaceRight(0, 0)
  f.slotNum.slotToText = slotToText
  f.slotNum:slotToText(self.watched.slot)
  DB.watched:AddWatch("slot", function(_k, v, _oldVal)
    f.slotNum:slotToText(v)
  end)
  local updtTitle = function(_k, v, _oldVal)
    if v then
      title:SetTextColor(0.9, 0.9, 0.9)
    else
      title:SetTextColor(1, 0, 0)
    end
  end
  DB.watched:AddWatch("enabled", updtTitle)
  updtTitle("enabled", DB.watched.enabled, nil) -- initial value
  DB:AddTeamStatusUI(DB.statusFrame)
end

function DB.SavePositionCB(f, pos, scale)
  DB:Debug("Call back to save pos % scale %", pos, scale)
  DB:SetSaved("statusPos", pos)
  DB:SetSaved("statusScale", scale)
  f:Snap()
end

--- Key Bindings dump

function DB:GetBoundKeys(mode)
  mode = mode or 1
  local lastCat
  local bindings = {}
  for i = 1, GetNumBindings(mode) do
    (function(cmd, cat, ...)
      local numKeys = select("#", ...)
      if numKeys == 0 then
        return
      end
      if cat ~= lastCat then
        bindings[#bindings + 1] = _G[cat] or cat
        lastCat = cat
      end
      -- if there are more than 2 which is possible, repeat the line with the other keys
      local keys = {...}
      for j = 1, numKeys, 2 do
        local key1 = keys[j]
        local key2 = keys[j + 1]
        bindings[#bindings + 1] = {cmd, key1 or "", key2 or ""}
      end
    end)(GetBinding(i, mode))
  end
  return bindings
end

function DB:ExportBindingsUI(mode)
  local bindings = DB:GetBoundKeys(mode)
  local frameName = "DynamicBoxerBindingsExport"
  local f = DB:StandardFrame(frameName, "DynamicBoxer Key Bindings Export (csv)")
  f:addText("Copy (Ctrl-C) your current key bindings,"):Place()
  f:addText("paste in gist.gitbub.com or save in a file, named |cFF99E5FF.csv|r:"):Place()
  local font = DB:NormalizeFont("ChatFontNormal")
  local _, h = font:GetFont()
  f.seb = f:addScrollEditFrame(320, h * 12, font) -- 12 lines
  f.seb:Place(5, 14) -- 4 is inset
  local eb = f.seb.editBox
  eb:SetScript("OnEscapePressed", function()
    f:Hide()
  end)
  local text = [["Binding", "First key", "Second key"]]
  for _, binding in ipairs(bindings) do
    if type(binding) == "string" then
      text = text .. "\n\"--- " .. binding .. " ---\",,"
    else
      text = text .. "\n" .. table.concat(binding, ", ")
    end
  end
  DB:SetReadOnly(eb, text)
  f:SetPoint("TOP", 0, -380)
  f:Snap()
end

--- Bindings settings (i18n/l10n)
_G.DYNAMICBOXER = "DynamicBoxer"
_G.BINDING_HEADER_DYNAMICBOXER = L["DynamicBoxer addon key bindings"]
_G.BINDING_NAME_DBOX_INVITE = "Invite team  |cFF99E5FF/dbox party invite|r"
_G.BINDING_NAME_DBOX_IDENTIFY = "Identify slot |cFF99E5FF/dbox identify|r"
_G.BINDING_NAME_DBOX_DISBAND = "Disband  |cFF99E5FF/dbox party disband|r"
_G.BINDING_NAME_DBOX_XCHG = "Exchange token  |cFF99E5FF/dbox xchg|r"
_G.BINDING_NAME_DBOX_AUTOINV = "Toggle AutoInvite |cFF99E5FF/dbox autoi|r"
_G.BINDING_NAME_DBOX_SHOW = "Show token  |cFF99E5FF/dbox show|r"
_G.BINDING_NAME_DBOX_PING = "Send ping  |cFF99E5FF/dbox m|r"
_G.BINDING_NAME_DBOX_JOIN = "Send join  |cFF99E5FF/dbox join|r"
_G.BINDING_NAME_DBOX_CONFIG = "Config  |cFF99E5FF/dbox config|r"

---

DB:Debug("dbox ui file loaded")
