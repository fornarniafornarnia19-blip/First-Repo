-- StarterPlayerScripts/InputController.client.luau
local CAS = game:GetService("ContextActionService")
local UIS = game:GetService("UserInputService")
local RS = game:GetService("ReplicatedStorage")

-- FIXED PATH
local Net = require(RS:WaitForChild("Shared"):WaitForChild("NetUtil"))

local InputController = {}
local started = false

local ACTION_EQUIP = "EquipSaber"
local ACTION_IGNITE = "ToggleIgnite"

local function typingBlocked(): boolean
	return UIS:GetFocusedTextBox() ~= nil
end

function InputController:Init()
	-- No need to cache events with new API
end

function InputController:Start()
	if started then
		return
	end
	started = true

	-- 1 = equip/holster ONLY
	CAS:BindAction(ACTION_EQUIP, function(_, state)
		if state ~= Enum.UserInputState.Begin or typingBlocked() then
			return Enum.ContextActionResult.Pass
		end
		-- NEW API: Direct FireServer call
		Net.FireServer("Saber_ToggleEquip")
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.One, Enum.KeyCode.DPadUp, Enum.KeyCode.ButtonY)

	-- Q = ignite/retract
	CAS:BindAction(ACTION_IGNITE, function(_, state)
		if state ~= Enum.UserInputState.Begin or typingBlocked() then
			return Enum.ContextActionResult.Pass
		end
		-- NEW API: Direct FireServer call
		Net.FireServer("Saber_ToggleIgnite")
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.Q, Enum.KeyCode.DPadRight, Enum.KeyCode.ButtonX)
end

return InputController
