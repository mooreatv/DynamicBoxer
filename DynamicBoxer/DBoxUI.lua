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
  DB:AddToMasterHistory(masterName)
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
    StaticPopup_Hide("DYNBOXER_SLAVE")
  end
  DB.inUI = false
end

--- Options panel ---

function DB.CreateOptionsPanel()
  if DB.optionsPanel then
    DB:Debug("Options Panel already setup")
    return
  end
  DB:Debug("Creating Options Panel")

  -- Options panel and experimentation/beginning of a UI library
  -- WARNING, Y axis is such as positive is down, unlike rest of the wow api which has + offset going up
  -- but all the negative numbers all over, just for Y axis, got to me

  local p = CreateFrame("Frame")
  DB.optionsPanel = p
  p.name = "DynamicBoxer"
  p.children = {}
  p.numObjects = 0

  -- place inside the parent at offset x,y from corner of parent
  local placeInside = function(sf, x, y)
    x = x or 16
    y = y or 16
    sf:SetPoint("TOPLEFT", x, -y)
    return sf
  end
  -- place below (previously placed item typically)
  local placeBelow = function(sf, below, x, y)
    x = x or 0
    y = y or 8
    sf:SetPoint("TOPLEFT", below, "BOTTOMLEFT", x, -y)
    return sf
  end
  -- place to the right of last widget
  local placeRight = function(sf, nextTo, x, y)
    x = x or 16
    y = y or 0
    sf:SetPoint("TOPLEFT", nextTo, "TOPRIGHT", x, -y)
    return sf
  end

  -- Place (below) relative to previous one. optOffsetX is relative to the left margin
  -- established by first widget placed (placeInside)
  -- such as changing the order of widgets doesn't change the left/right offset
  -- in other words, offsetX is absolute to the left margin instead of relative to the previously placed object
  p.Place = function(self, object, optOffsetX, optOffsetY)
    self.numObjects = self.numObjects + 1
    DB:Debug(7, "called Place % n % o %", self.name, self.numObjects, self.leftMargin)
    if self.numObjects == 1 then
      -- first object: place inside
      object:placeInside(optOffsetX, optOffsetY)
      self.leftMargin = 0
    else
      optOffsetX = optOffsetX or 0
      -- subsequent, place after the previous one but relative to initial left margin
      object:placeBelow(self.lastAdded, optOffsetX - self.leftMargin, optOffsetY)
      self.leftMargin = optOffsetX
    end
    self.lastAdded = object
    self.lastLeft = object
    return object
  end

  p.PlaceRight = function(self, object, optOffsetX, optOffsetY)
    self.numObjects = self.numObjects + 1
    if self.numObjects == 1 then
      error("PlaceRight() should not be the first call, Place() should")
    end
    -- place to the right of previous one on the left
    -- if the previous widget has text, add the text length (eg for check buttons)
    local x = (optOffsetX or 16) + (self.lastLeft.extraWidth or 0)
    object:placeRight(self.lastLeft, x, optOffsetY)
    self.lastLeft = object
    return object
  end

  -- to be used by the various factories/sub widget creation to add common methods to them
  function p:addMethods(widget) -- put into MoGuiLib once good enough
    widget.placeInside = placeInside
    widget.placeBelow = placeBelow
    widget.placeRight = placeRight
    widget.parent = self
    widget.Place = function(...)
      -- add missing parent as first arg
      widget.parent:Place(...)
      return widget -- because :Place is typically last, so don't return parent/self but the widget
    end
    widget.PlaceRight = function(...)
      widget.parent:PlaceRight(...)
      return widget
    end
    table.insert(self.children, widget) -- keep track of children objects (mostly for debug)
  end

  p.addText = function(self, text, font)
    font = font or "GameFontHighlightSmall" -- different default?
    local f = self:CreateFontString(nil, "ARTWORK", font)
    DB:Debug(8, "font string starts with % points", f:GetNumPoints())
    f:SetText(text)
    f:SetJustifyH("LEFT")
    f:SetJustifyV("TOP")
    self:addMethods(f)
    return f
  end

  p.addCheckBox = function(self, text, tooltip)
    -- local name= "DB.cb.".. tostring(self.id) -- not needed
    local c = CreateFrame("CheckButton", nil, self, "InterfaceOptionsCheckButtonTemplate")
    DB:Debug(8, "check box starts with % points", c:GetNumPoints())
    c.Text:SetText(text)
    if tooltip then
      c.tooltipText = tooltip
    end
    self:addMethods(c)
    c.extraWidth = c.Text:GetWidth()
    return c
  end

  -- create a slider with the range [minV...maxV] and optional step, low/high labels and optional
  -- strings to print in parenthesis after the text title
  p.addSlider = function(self, text, tooltip, minV, maxV, step, lowL, highL, valueLabels)
    minV = minV or 0
    maxV = maxV or 10
    step = step or 1
    lowL = lowL or tostring(minV)
    highL = highL or tostring(maxV)
    local s = CreateFrame("Slider", nil, self, "OptionsSliderTemplate")
    s.DoDisable = BlizzardOptionsPanel_Slider_Disable -- what does enable/disable do ? seems we need to call these
    s.DoEnable = BlizzardOptionsPanel_Slider_Enable
    s:SetValueStep(step)
    s:SetStepsPerPage(step)
    s:SetMinMaxValues(minV, maxV)
    s:SetObeyStepOnDrag(true)
    s.Text:SetFontObject(GameFontNormal)
    -- not centered, so changing (value) doesn't wobble the whole thing
    -- (justifyH left alone didn't work because the point is also centered)
    s.Text:SetPoint("LEFT", s, "TOPLEFT", 6, 0)
    s.Text:SetJustifyH("LEFT")
    s.Text:SetText(text)
    if tooltip then
      s.tooltipText = tooltip
    end
    s.Low:SetText(lowL)
    s.High:SetText(highL)
    s:SetScript("OnValueChanged", function(w, value)
      local sVal
      if valueLabels and valueLabels[value] then
        sVal = valueLabels[value]
      else
        sVal = tostring(value)
        if value == minV then
          sVal = lowL
        elseif value == maxV then
          sVal = highL
        end
      end
      w.Text:SetText(text .. ": " .. sVal)
    end)
    self:addMethods(s)
    return s
  end

  -- the call back is either a function or a command to send to DB.Slash
  p.addButton = function(self, text, tooltip, cb)
    -- local name= "DB.cb.".. tostring(self.id) -- not needed
    local c = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
    c.Text:SetText(text)
    c:SetWidth(c.Text:GetStringWidth() + 20) -- need some extra spaces for corners
    if tooltip then
      c.tooltipText = tooltip -- TODO: style/font is wrong
    end
    self:addMethods(c)
    local callback = cb
    if type(cb) == "string" then
      DB:Debug("Setting callback for % to call Slash(%)", text, cb)
      callback = function()
        DB.Slash(cb)
      end
    else
      DB:Debug("Keeping original function for %", text)
    end
    c:SetScript("OnClick", callback)
    return c
  end

  --  DB.widgetDemo = true -- to show the demo (or `DB:SetSaved("widgetDemo", true)`)

  -- TODO: look into i18n
  -- Q: maybe should just always auto place (add&place) ?
  p:addText("DynamicBoxer options", "GameFontNormalLarge"):Place()
  p:addText("These options let you control the behavior of DynamicBoxer " .. DB.manifestVersion):Place()
  if DB.widgetDemo then
    p:addText("Testing 1 2 3... demo widgets:"):Place(50, 20)
    local _cb1 = p:addCheckBox("A test checkbox", "A sample tooltip"):Place(0, 20) -- A: not here
    local cb2 = p:addCheckBox("Another checkbox", "Another tooltip"):Place()
    cb2:SetChecked(true)
    local s2 = p:addSlider("Test slider", "Test slide tooltip", 1, 4, 1, "Test low", "Test high",
                           {"Value 1", "Value 2", "Third one", "4th value"}):Place(16, 30)
    s2:SetValue(4)
    p:addText("Real UI:"):Place(50, 40)
  end

  local autoInvite = p:addCheckBox("Auto invite", "Whether one of the slot should auto invite the others\n" ..
                                     "it also helps with cross realm teams sync"):Place(4, 30)

  -- TODO tooltip formatting and maybe auto add the /dbox command

  p:addButton("Invite Team",
              "Invites to the party the team members\ndetected so far and not already in party\n|cFFFFFF00/dbox p|r",
              "party invite"):PlaceRight()

  p:addButton("Disband", "If party leader, Uninvite the members of the team,\npossibly leaving guests." ..
                "Otherwise, leave the party\n|cFFFFFF00/dbox p disband|r", "party disband"):PlaceRight()

  local invitingSlot = p:addSlider("Party leader Slot", "Sets which slot should be doing the party inviting", 1, 5)
                         :Place(16, 12) -- need more vspace

  autoInvite:SetScript("PostClick", function(w, button, down)
    DB:Debug(3, "ainv post click % %", button, down)
    if w:GetChecked() then
      invitingSlot:DoEnable()
    else
      invitingSlot:DoDisable()
    end
  end)

  p:addButton("Show/Set Token",
              "Shows the UI to show or set the current token string\n(shows on master for copying or to paste it on slaves)\n|cFFFFFF00/dbox show|r",
              "show"):Place(0, 20)

  p:addText("Development, troubleshooting and advanced options:"):Place(40, 20)

  p:addButton("Re Init", "Re initializes like the first time setup.\n|cFFFFFF00/dbox init|r", "init"):Place(0, 20)
  p:addButton("Join", "Attempts to resync the team by\nsending a message requiring reply\n|cFFFFFF00/dbox j|r", "join")
    :PlaceRight()
  p:addButton("Ping", "Attempts to resync the team by\nsending a message\n|cFFFFFF00/dbox m|r", "message"):PlaceRight()

  local debugLevel = p:addSlider("Debug level", "Sets the debug level\n|cFFFFFF00/dbox debug X|r", 0, 9, 1, "Off")
                       :Place(16, 30)

  p:addButton("Event Trace", "Starts the blizzard Event Trace with DynamicBoxer saved filters\n|cFFFFFF00/dbox event|r",
              "event"):Place(0, 20)

  p:addButton("Save Filters", "Saves the set of currently filtered Events\n|cFFFFFF00/dbox event save|r", "event save")
    :PlaceRight()

  p:addButton("Clear Filters", "Clear saved filtered Events\n|cFFFFFF00/dbox event clear|r", "event clear"):PlaceRight()

  local adv = p:addCheckBox("Show reset options", "Show dev/advanced only dangerous options"):Place(0, 20)

  -- TODO add confirmation before reset all and a dropdown widget
  p:addButton("Reset All",
              "Resets all the DynamicBoxer saved variables\n(reload needed after this)\n|cFFFFFF00/dbox reset all|r",
              "reset all"):Place()

  local rx = 30
  local ry = -1
  p:addButton("Reset Team", "Reset the isboxer team detection\n(for next login)\n|cFFFFFF00/dbox reset team|r",
              "reset team"):Place(rx, ry)

  p:addButton("Reset Token",
              "Forgets the secure token,\nwill cause the Show/Set dialog for next login\n|cFFFFFF00/dbox reset token|r",
              "reset team"):Place(rx, ry)

  p:addButton("Reset Master History",
              "Resets the master history for this faction\n(will require setting next login)\n|cFFFFFF00/dbox reset master|r",
              "reset masters"):Place(rx, ry)

  p:addButton("Reset Members History",
              "Resets the team members history for this faction\n|cFFFFFF00/dbox reset members|r", "reset members")
    :Place(rx, ry)

  local advPostClick = function(w, button, down)
    DB:Debug(3, "advanced reset show/hide post click % %", button, down)
    for i = p.numObjects - 4, p.numObjects do
      if w:GetChecked() then
        p.children[i]:Show()
      else
        p.children[i]:Hide()
      end
    end
  end
  adv:SetScript("PostClick", advPostClick)
  advPostClick(adv)

  function p:refresh()
    debugLevel:SetValue(DB.debug or 0)
    invitingSlot:SetValue(DB.autoInviteSlot)
    if DB.autoInvite then
      autoInvite:SetChecked(true)
      invitingSlot:DoEnable()
    else
      autoInvite:SetChecked(false)
      invitingSlot:DoDisable()
    end
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
    local ainv = autoInvite:GetChecked()
    DB:SetSaved("autoInvite", ainv)
    local ainvSlot = invitingSlot:GetValue()
    DB:SetSaved("autoInviteSlot", ainvSlot)
    DB:PrintDefault("Configuration: auto invite is " .. (ainv and "ON" or "OFF") .. " for slot %", ainvSlot)
    -- DB:Warning("Generating lua error on purpose in p:HandleOk()")
    -- error("testing errors")
  end

  function p:cancel()
    DB:Warning("Options screen cancelled, not making any changes.")
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

---

DB:Debug("dbox ui file loaded")
