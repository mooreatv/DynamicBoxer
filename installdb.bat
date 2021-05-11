for %%x in (_retail_ _classic_ _ptr_ _beta_ _classic_ptr_) do (
echo Installing for %%x
xcopy /i /y DynamicBoxer\*.* "C:\Program Files (x86)\World of Warcraft\%%x\Interface\Addons\DynamicBoxer"
)
