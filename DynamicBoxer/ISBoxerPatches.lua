isboxer = { }

isboxer.Character = { LoadBinds=nil, Name="" }
isboxer.CharacterSet = { LoadBinds=nil, Name="", Members={} }
isboxer.Following = { Unit="", ReFollow=0 }
isboxer.Master = { Name="", Self=1}
isboxer.NextButton = 1;
isboxer.ManageJambaTeam = false

function isboxer.DetectJamba5()
	if (isboxer.JambaDetectionRan) then
		return
	end
	isboxer.JambaDetectionRan = true;

 if (LibStub and LibStub:GetLibrary("AceAddon-3.0",1)) then	
 	isboxer.JambaTeam = LibStub("AceAddon-3.0"):GetAddon("JambaTeam",1);
 	isboxer.JambaFollow = LibStub("AceAddon-3.0"):GetAddon("JambaFollow",1);
 end

end


function isboxer.ClearMembers()
    
	local max = table.getn(isboxer.CharacterSet.Members)
	for i=1,max,1 do table.remove(isboxer.CharacterSet.Members) end

	if (not isboxer.ManageJambaTeam) then
		return
	end

	if (JambaComms) then
		JambaComms:DisableAllMembersCommand(nil,nil);
		return
	end
	isboxer.DetectJamba5();
	if (JambaApi and isboxer.JambaTeam) then
		for characterName, characterPosition in JambaApi.TeamList() do
			isboxer.JambaTeam:RemoveMemberCommand(nil,characterName);
		end
	end
end

function isboxer.AddMember(name)
    table.insert(isboxer.CharacterSet.Members,name)

	if (not isboxer.ManageJambaTeam) then
		return
	end

	if (JambaComms) then
		JambaComms:AddMemberCommand(nil,name);
		JambaComms:EnableMemberCommand(nil,name);
		return
	end
	isboxer.DetectJamba5();
	if (isboxer.JambaTeam) then
		isboxer.JambaTeam:AddMemberCommand(nil,name);
	end
end

function isboxer.SetMaster(name)
	if (JambaComms) then
		JambaComms:SetMaster(nil,name);		
	end
	isboxer.DetectJamba5();
	if (isboxer.JambaTeam) then
		isboxer.JambaTeam:AddMemberCommand(nil,name);
	end
end

function isboxer.Output(text)
	DEFAULT_CHAT_FRAME:AddMessage("ISBoxer: "..text,1.0,1.0,1.0); 	
end

function isboxer.Warning(text)
	DEFAULT_CHAT_FRAME:AddMessage("ISBoxer warning: "..text,1.0,1.0,1.0);
	UIErrorsFrame:AddMessage("ISBoxer: "..text,1.0,0.0,0.0,53,15);
end

function isboxer.CheckBoundCombo(key,combo)
	local action = GetBindingAction(combo);
	if (action and action~="") then
		isboxer.Warning("Modifier conditions used for targeting on '"..key.."' may not work because "..combo.." is bound to "..action); 	
	end
end

function isboxer.CheckBoundModifiers(key,checkshift,checkalt,checkctrl)
	if (checkalt) then
		isboxer.CheckBoundCombo(key,"ALT-"..key);
		if (checkctrl) then
			isboxer.CheckBoundCombo(key,"ALT-CTRL-"..key);
			if (checkshift) then
				isboxer.CheckBoundCombo(key,"ALT-CTRL-SHIFT-"..key);
			end
		end
		if (checkshift) then
			isboxer.CheckBoundCombo(key,"ALT-SHIFT-"..key);
		end
	end
	if (checkctrl) then
		if (checkshift) then
			isboxer.CheckBoundCombo(key,"CTRL-SHIFT"..key);
		end
		isboxer.CheckBoundCombo(key,"CTRL-"..key);
	end
	if (checkshift) then
		isboxer.CheckBoundCombo(key,"SHIFT-"..key);
	end
end

function isboxer.SetMacro(usename,key,macro,conditionalshift,conditionalalt,conditionalctrl,override)
	if (key and key~="" and key~="none") then
		local action = GetBindingAction(key);
		if (action and action~="") then
			if (not override) then	
				isboxer.Warning(key.." is bound to "..action..". ISBoxer is configured to NOT override this binding.");
				return
			else
				isboxer.Warning(key.." is bound to "..action..". ISBoxer is overriding this binding.");
			end
		end

		if (conditionalshift or conditionalalt or conditionalctrl) then
			isboxer.CheckBoundModifiers(key,conditionalshift,conditionalalt,conditionalctrl);
		end
	end

	local name
	if (usename and usename~="") then
		name = usename
	else
		name = "ISBoxerMacro"..isboxer.NextButton;
	end
	isboxer.NextButton = isboxer.NextButton + 1;
	local button = CreateFrame("Button",name,nil,"SecureActionButtonTemplate");
	button:SetAttribute("type","macro");
	button:SetAttribute("macrotext",macro);
	button:Hide();
	if (key and key~="" and key~="none") then
		SetOverrideBindingClick(isboxer.frame,false,key,name,"LeftButton");
	end
end

function isboxer.LoadBinds()
	if (isboxer.CharacterSet.LoadBinds or isboxer.Character.LoadBinds) then
		if (isboxer.CharacterSet.LoadBinds) then
			isboxer.CharacterSet.LoadBinds();
			isboxer.Output("WoW Macros for Character Set '"..isboxer.CharacterSet.Name.."' Loaded.");
		end
		if (isboxer.Character.LoadBinds) then
			isboxer.Character.LoadBinds();
			isboxer.Output("WoW Macros for Character '"..isboxer.Character.Name.."' in Set '"..isboxer.CharacterSet.Name.."' Loaded.");
			if (isboxer.Character.ActualName~="*" and isboxer.Character.ActualName:upper()~=GetUnitName("player"):upper()) then

				StaticPopupDialogs["ISBOXER_WRONGCHARACTER"] = {
				  text = "Character in wrong window? ISBoxer expected "..isboxer.Character.ActualName.." but got "..GetUnitName("player")..". Some functionality may not work correctly!",
				  button1 = OKAY,
				  timeout = 0,
				  whileDead = true,
				  hideOnEscape = true,
				}
				StaticPopup_Show("ISBOXER_WRONGCHARACTER");
				isboxer.Warning("Expected "..isboxer.Character.ActualName.." but got "..GetUnitName("player"));
			end
		end
	else
		isboxer.Output("No WoW Macros loaded.");
	end
end

function isboxer_eventHandler(self, event, ...)
    if (event=="UPDATE_BINDINGS" or event=="PLAYER_ENTERING_WORLD") then
	    self:UnregisterEvent("UPDATE_BINDINGS");
	    self:UnregisterEvent("PLAYER_ENTERING_WORLD");
	    isboxer.Output("Loading Key Bindings...");
            isboxer.LoadBinds();       
    end
    if (event=="AUTOFOLLOW_BEGIN") then
    end
    if (event=="AUTOFOLLOW_END") then
    end
    if (event=="PARTY_INVITE_REQUEST") then
    end
    if (event=="PARTY_LEADER_CHANGED") then
    end
    if (event=="PARTY_MEMBERS_CHANGED") then
    end
    if (event=="CHAT_MSG_WHISPER") then
    end
end

--function isboxer_onUpdate(self, elapsed)
--  local now = GetTime();
--   
--end

isboxer.frame = CreateFrame("FRAME", "ISBoxerEventFrame");
isboxer.frame:RegisterEvent("UPDATE_BINDINGS");
isboxer.frame:RegisterEvent("PLAYER_ENTERING_WORLD");
isboxer.frame:SetScript("OnEvent", isboxer_eventHandler);
--isboxer.frame:SetScript("OnUpdate", isboxer_onUpdate);

function isboxer.Follow(target)
	if (JambaFollow) then
		-- hack for Jamba's self-detection checking against the player name...
		local name = target;
		--if (UnitIsUnit(target,"player")) then
			name = UnitName(target);
		--end
		
		if (not name or name=="") then
			name = target
		end
		
		if (JambaFollow.followingStrobing) then
			JambaFollow:FollowStrobeOn(name);
		else
			JambaFollow:FollowTarget(name);
		end
	end
	isboxer.DetectJamba5();
	if (isboxer.JambaFollow) then
		-- hack for Jamba's self-detection checking against the player name...
		local name = target;
		--if (UnitIsUnit(target,"player")) then
			name = UnitName(target);
		--end
		
		if (not name or name=="") then
			name = target
		end
		
		if (JambaApi.Follow:IsFollowingStrobing()) then
			isboxer.JambaFollow:FollowStrobeOn(name);
		else
			isboxer.JambaFollow:FollowTarget(name);
		end		
	end

	FollowUnit(target);
end

SlashCmdList["FOLLOW"]=function(msg)
	msg = SecureCmdOptionParse(msg);
	if (not msg or msg=="") then
		msg="target";
	end
	
	if (UnitIsPlayer(msg)) then
		isboxer.Follow(msg);
		return
	end
	for i=1,5 do
		if (UnitIsUnit(msg,"partypet"..i)) then
			isboxer.Follow("party"..i);
			return
		end
	end
	for i=1,40 do
		if (UnitIsUnit(msg,"raidpet"..i)) then
			isboxer.Follow("raid"..i);
			return
		end
	end
	
	isboxer.Follow(msg);	
end

isboxer.Output("ISBoxer Addon v1.1 Loaded.");



--	local ISBoxerMacro1 = CreateFrame("Button","ISBoxerMacro1",nil,"SecureActionButtonTemplate");
--	if (ISBoxerMacro1 == nil) then	
--		DEFAULT_CHAT_FRAME:AddMessage("failed.",1.0,1.0,1.0); 
--	end
--	ISBoxerMacro1:SetAttribute("type","macro");
--	ISBoxerMacro1:SetAttribute("macrotext","/wave");
--	ISBoxerMacro1:Hide();
--	SetBindingClick("ALT-CTRL-Q","ISBoxerMacro1");
--	local bindingaction=GetBindingAction("ALT-CTRL-Q");
--	if (bindingaction) then 
--		DEFAULT_CHAT_FRAME:AddMessage("bindingaction:"..bindingaction,1.0,1.0,1.0); 
--	else 
--		DEFAULT_CHAT_FRAME:AddMessage("no binding action...",1.0,1.0,1.0); 
--	end
