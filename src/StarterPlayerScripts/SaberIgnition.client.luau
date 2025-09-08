-- StarterPlayerScripts/SaberIgnition.client.lua
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local CAS = game:GetService("ContextActionService")

local LocalPlayer = Players.LocalPlayer
local IgniteEv: RemoteEvent = RS:WaitForChild("SaberIgnite")

local ACTION = "SaberIgnite_Q"
local localCooldown = false

local function hasHandSaber(): boolean
	local char = LocalPlayer.Character
	if not char then
		return false
	end
	local m = char:FindFirstChild("HandSaber", true)
	return (m and m:IsA("Model")) and true or false
end

local function onAction(actionName, inputState, _inputObj)
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	if localCooldown then
		return Enum.ContextActionResult.Sink
	end
	if not hasHandSaber() then
		return Enum.ContextActionResult.Sink
	end

	localCooldown = true
	IgniteEv:FireServer()
	task.delay(0.15, function()
		localCooldown = false
	end)

	return Enum.ContextActionResult.Sink
end

CAS:BindAction(ACTION, onAction, false, Enum.KeyCode.Q)

-- Optional mobile button
CAS:SetTitle(ACTION, "Ignite")
CAS:SetPosition(ACTION, UDim2.new(0.84, 0, 0.76, 0))
