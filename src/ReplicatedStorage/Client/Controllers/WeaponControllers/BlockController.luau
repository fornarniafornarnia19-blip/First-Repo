--!strict
local RS = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")
local CAS = game:GetService("ContextActionService")
local Players = game:GetService("Players")

-- FIXED PATH
local Net = require(RS:WaitForChild("Shared"):WaitForChild("NetUtil"))

local ACTION = "Saber_BlockHold_RMB"
local PRIORITY = Enum.ContextActionPriority.Low.Value

local started = false
local player = Players.LocalPlayer

local function typingBlocked(): boolean
	return UIS:GetFocusedTextBox() ~= nil
end

local function bind()
	if started then
		return
	end
	started = true

	CAS:BindActionAtPriority(ACTION, function(_actionName, state: Enum.UserInputState, input: InputObject)
		-- Only care about RMB; never consume unrelated inputs
		if typingBlocked() or input.UserInputType ~= Enum.UserInputType.MouseButton2 then
			return Enum.ContextActionResult.Pass
		end

		if state == Enum.UserInputState.Begin then
			-- NEW API: Direct FireServer call
			Net.FireServer("Saber_Block", true)
		elseif state == Enum.UserInputState.End then
			-- NEW API: Direct FireServer call
			Net.FireServer("Saber_Block", false)
		end

		return Enum.ContextActionResult.Pass
	end, false, PRIORITY, Enum.UserInputType.MouseButton2)
end

local BlockController = {}

function BlockController:Init()
	-- Init does nothing now - moved listener to Start
end

function BlockController:Start()
	bind()

	-- MOVED HERE: Optional - observe broadcast if you have VFX/pose systems that rely on it
	Net.OnClientEvent("Saber_BroadcastState", function(uid: number, holding: boolean)
		-- no-op here; leave for other controllers if needed
	end)
end

function BlockController:Stop()
	pcall(function()
		CAS:UnbindAction(ACTION)
	end)
	started = false
end

-- Keep this file focused on input only.
return BlockController
