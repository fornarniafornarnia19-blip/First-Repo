-- StarterPlayerScripts/ToggleSaber.client.lua
local UIS = game:GetService("UserInputService")
local RS = game:GetService("ReplicatedStorage")
local Ev = RS:WaitForChild("SaberToggle")

UIS.InputBegan:Connect(function(input, gp)
	if gp then
		return
	end
	if input.KeyCode == Enum.KeyCode.One then
		Ev:FireServer()
	end
end)
