-- Section of code we need to modify from original ISBoxer.lua (isb42)
-- for behavior we can't change just with the hooks.
-- This assumes ISBoxer is already loaded per our toc deps
--
-- Created by DBoxInit
local DB = DynBoxer

-- We need to fix isboxer.SetMacro so it can update buttons instead
-- of leaking some/creating new ones each call:
function isboxer.SetMacro(usename, key, macro, conditionalshift, conditionalalt, conditionalctrl, override)
  if (key and key ~= "" and key ~= "none") then
    local action = GetBindingAction(key)
    if (action and action ~= "") then
      if (not override) then
        isboxer.Warning(key .. " is bound to " .. action .. ". ISBoxer is configured to NOT override this binding.")
        return
      else
        isboxer.Warning(key .. " is bound to " .. action .. ". ISBoxer is overriding this binding.")
      end
    end

    if (conditionalshift or conditionalalt or conditionalctrl) then
      isboxer.CheckBoundModifiers(key, conditionalshift, conditionalalt, conditionalctrl)
    end
  end

  local name
  if (usename and usename ~= "") then
    name = usename
  else
    name = "ISBoxerMacro" .. isboxer.NextButton
  end
  isboxer.NextButton = isboxer.NextButton + 1
  -- Start of change comparted to original
  local button
  if _G[name] then
    DB:Debug(8, "Button for % already exist, reusing, setting macro to %", name, macro)
    button = _G[name]
  else
    DB:Debug(2, "Creating button %", name)
    button = CreateFrame("Button", name, nil, "SecureActionButtonTemplate")
  end
  -- End of change compared to original
  button:SetAttribute("type", "macro")
  button:SetAttribute("macrotext", macro)
  button:Hide()
  if (key and key ~= "" and key ~= "none") then
    SetOverrideBindingClick(isboxer.frame, false, key, name, "LeftButton")
  end
end

-- This event triggers too early and the realm isn't available yet
-- causing nil error trying to get the fully qualified name so we remove
-- it from what isboxer listens too (it anyways even in standard version is
-- ready to act on the better PLAYER_ENTERING_WORLD)
isboxer.frame:UnregisterEvent("UPDATE_BINDINGS")
