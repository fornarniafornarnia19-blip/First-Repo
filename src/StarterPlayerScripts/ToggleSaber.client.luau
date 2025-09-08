local UIS = game:GetService("UserInputService")
local RS = game:GetService("ReplicatedStorage")

local Ev = RS:WaitForChild("SaberToggle") -- client → server
local ConfirmEv = RS:WaitForChild("SaberConfirm") -- server → client

local busy = false

UIS.InputBegan:Connect(function(input, gp)
	if gp then
		return
	end

	if input.KeyCode == Enum.KeyCode.One then
		if busy then
			return
		end
		busy = true
		Ev:FireServer()
	end
end)

-- Reset debounce only when server confirms toggle finished
ConfirmEv.OnClientEvent:Connect(function()
	busy = false
end)
