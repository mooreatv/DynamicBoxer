isboxer.Character.Name = "SLOT2";
isboxer.Character.ActualName = "SLOT2";
isboxer.Character.QualifiedName = "SLOT2";

function isboxer.Character_LoadBinds()
	if (isboxer.CharacterSet.Name=="DYNAMIC_DUO") then
		isboxer.SetMacro("FTLAssist","BACKSPACE","/assist [nomod:alt,mod:lshift,nomod:ctrl]SLOT1;[nomod:alt,mod:rshift,nomod:ctrl]SLOT2\n",1,1,1,1);

		isboxer.SetMacro("FTLFocus","NONE","/focus [nomod:alt,mod:lshift,nomod:ctrl]SLOT1;[nomod:alt,mod:rshift,nomod:ctrl]SLOT2\n",1,1,1,1);

		isboxer.SetMacro("FTLFollow","F11","/jamba-follow snw\n/follow [nomod:alt,mod:lshift,nomod:ctrl]SLOT1;[nomod:alt,mod:rshift,nomod:ctrl]SLOT2\n",1,1,1,1);

		isboxer.SetMacro("FTLTarget","NUMPADDIVIDE","/targetexact [nomod:alt,mod:lshift,nomod:ctrl]SLOT1;[nomod:alt,mod:rshift,nomod:ctrl]SLOT2\n",1,1,1,1);

		isboxer.SetMacro("InviteTeam","ALT-CTRL-SHIFT-I","/invite SLOT1\n",nil,nil,nil,1);

		isboxer.SetMacro("CTMOn","ALT-SHIFT-N","/console autointeract 1\n",nil,nil,nil,1);

		isboxer.SetMacro("CTMOff","ALT-CTRL-N","/console autointeract 0\n",nil,nil,nil,1);

		isboxer.SetMacro("JambaMaster","CTRL-SHIFT-F12","/jamba-team iammaster all\n",nil,nil,nil,1);

		isboxer.SetMacro("JambaStrobeOn","ALT-SHIFT-F12","/jamba-follow strobeonme all\n",nil,nil,nil,1);

		isboxer.SetMacro("JambaStrobeOff","ALT-CTRL-SHIFT-F12","/jamba-follow strobeoff all\n",nil,nil,nil,1);

		isboxer.ManageJambaTeam=True
		isboxer.ClearMembers();
		isboxer.SetMaster("SLOT1");
		return
	end
end
isboxer.Character.LoadBinds = isboxer.Character_LoadBinds;

isboxer.Output("Character 'SLOT2' activated");
