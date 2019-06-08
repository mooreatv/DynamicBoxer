for %%x in (_retail_ _classic_beta_) do (
echo Installing for %%x
xcopy /i /y DynamicBoxer\*.* "C:\Program Files (x86)\World of Warcraft\%%x\Interface\Addons\DynamicBoxer"
)
