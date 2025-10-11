--!strict
-- ReplicatedStorage/Client/Controllers/AimController.luau

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local CAS = game:GetService("ContextActionService")
local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")
local UserGameSettings = UserSettings():GetService("UserGameSettings")

-- FIXED PATH
local Net = require(RS:WaitForChild("Shared"):WaitForChild("NetUtil"))

local LOCAL = Players.LocalPlayer
local camera = workspace.CurrentCamera

-- Defaults (optionally overridden if you wire a Constants module later)
local LOCK_OFFSET: Vector3 = Vector3.new(1.6, 0, 0) -- right-shoulder feel
local ORIGINAL_CURSOR_POS: UDim2 = UDim2.fromScale(0.5, 0.5) -- screen center

-- If you have a LightsaberModules/Constants, you can override at runtime without angering the type checker
do
	local ls = RS:FindFirstChild("LightsaberModules", true)
	if ls then
		local c = ls:FindFirstChild("Constants")
		if c and c:IsA("ModuleScript") then
			local ok, mod = pcall(require, c)
			if ok and typeof(mod) == "table" then
				if typeof(mod.LOCK_OFFSET) == "Vector3" then
					LOCK_OFFSET = mod.LOCK_OFFSET
				end
				if typeof(mod.ORIGINAL_CURSOR_POS) == "UDim" or typeof(mod.ORIGINAL_CURSOR_POS) == "UDim2" then
					ORIGINAL_CURSOR_POS = mod.ORIGINAL_CURSOR_POS
				end
			end
		end
	end
end

-- ---------- Types & state ----------
type State = {
	mouseLock: boolean,
	initDone: boolean,
	startDone: boolean,
	gui: ScreenGui?,
	cursor: ImageLabel?,
	mouse: Mouse?,

	prevMouseBehavior: Enum.MouseBehavior?,
	prevRotationType: Enum.RotationType?,
	prevMouseIconEnabled: boolean?,
}

local state: State = {
	mouseLock = false,
	initDone = false,
	startDone = false,
	gui = nil,
	cursor = nil,
	mouse = nil,

	prevMouseBehavior = nil,
	prevRotationType = nil,
	prevMouseIconEnabled = nil,
}

-- ---------- UI helpers ----------
local function ensureGui()
	if state.gui and state.cursor and state.mouse then
		return
	end

	local pg = LOCAL:WaitForChild("PlayerGui")

	-- Try prefab first: script.Parent/UI/MouseLock
	local gui: ScreenGui? = nil
	local cursor: ImageLabel? = nil

	local uiFolder = script.Parent:FindFirstChild("UI")
	if uiFolder then
		local prefab = uiFolder:FindFirstChild("MouseLock")
		if prefab and prefab:IsA("ScreenGui") then
			local cloned = prefab:Clone()
			cloned.Parent = pg
			gui = cloned
			local main = cloned:FindFirstChild("Main")
			if main and main:IsA("Frame") then
				local cur = main:FindFirstChild("Cursor")
				if cur and cur:IsA("ImageLabel") then
					cursor = cur
				end
			end
		end
	end

	-- Minimal fallback if prefab is absent/incomplete
	if not (gui and cursor) then
		gui = Instance.new("ScreenGui")
		gui.Name = "MouseLock"
		gui.ResetOnSpawn = false
		gui.IgnoreGuiInset = true
		gui.Parent = pg

		local main = Instance.new("Frame")
		main.Name = "Main"
		main.BackgroundTransparency = 1
		main.Size = UDim2.fromScale(1, 1)
		main.Parent = gui

		local r = Instance.new("ImageLabel")
		r.Name = "Cursor"
		r.AnchorPoint = Vector2.new(0.5, 0.5)
		r.Position = ORIGINAL_CURSOR_POS
		r.Size = UDim2.fromOffset(24, 24)
		r.BackgroundTransparency = 1
		r.ImageTransparency = 1 -- invisible until you give it an image
		r.Parent = main

		cursor = r
	end

	state.gui = gui
	state.cursor = cursor
	state.mouse = LOCAL:GetMouse()
end

-- ---------- Lock / Unlock ----------
local function applyLock(want: boolean)
	if state.mouseLock == want then
		return
	end
	ensureGui()

	if want then
		-- Save current user prefs once per lock
		if state.prevMouseBehavior == nil then
			state.prevMouseBehavior = UIS.MouseBehavior
		end
		if state.prevRotationType == nil then
			state.prevRotationType = UserGameSettings.RotationType
		end
		if state.prevMouseIconEnabled == nil then
			state.prevMouseIconEnabled = UIS.MouseIconEnabled
		end

		state.mouseLock = true
		if state.cursor then
			state.cursor.Visible = true
		end
		UIS.MouseIconEnabled = false
		UIS.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserGameSettings.RotationType = Enum.RotationType.CameraRelative
	else
		state.mouseLock = false
		if state.cursor then
			state.cursor.Visible = false
		end

		-- Restore exact user prefs
		if state.prevMouseBehavior ~= nil then
			UIS.MouseBehavior = state.prevMouseBehavior
		end
		if state.prevRotationType ~= nil then
			UserGameSettings.RotationType = state.prevRotationType
		end
		if state.prevMouseIconEnabled ~= nil then
			UIS.MouseIconEnabled = state.prevMouseIconEnabled
		end

		-- Clear for next cycle
		state.prevMouseBehavior = nil
		state.prevRotationType = nil
		state.prevMouseIconEnabled = nil
	end
end

-- Only enforce while locked
local function enforceWhileLocked()
	if not state.mouseLock then
		return
	end

	-- Keep lock intact if something else flips it
	if UIS.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
		UIS.MouseBehavior = Enum.MouseBehavior.LockCenter
	end
	if UserGameSettings.RotationType ~= Enum.RotationType.CameraRelative then
		UserGameSettings.RotationType = Enum.RotationType.CameraRelative
	end

	-- Smooth shoulder offset
	if camera then
		local baseCF = camera.CFrame
		local baseFocus = camera.Focus
		local desiredOffset = baseCF.RightVector * LOCK_OFFSET.X
		local alpha = 0.35

		local targetCF = baseCF + desiredOffset
		local targetFocus = baseFocus + desiredOffset

		camera.CFrame = baseCF:Lerp(targetCF, alpha)
		camera.Focus = baseFocus:Lerp(targetFocus, alpha)
	end
end

-- ---------- Bindings ----------
local ACTION_TOGGLE = "Custom_Lock_Toggle_L"
local function bindToggle()
	CAS:UnbindAction(ACTION_TOGGLE)
	CAS:BindActionAtPriority(ACTION_TOGGLE, function(_, inputState)
		if inputState ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		applyLock(not state.mouseLock)
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.L)
end

-- Block Roblox ShiftLock keys so only this system is used
local ACTION_BLOCK_SHIFTLOCK = "Block_Roblox_ShiftLock_Inputs"
local function bindBlockShiftLock()
	CAS:UnbindAction(ACTION_BLOCK_SHIFTLOCK)
	CAS:BindActionAtPriority(
		ACTION_BLOCK_SHIFTLOCK,
		function()
			return Enum.ContextActionResult.Sink
		end,
		false,
		Enum.ContextActionPriority.High.Value,
		Enum.KeyCode.LeftShift,
		Enum.KeyCode.RightShift,
		Enum.KeyCode.ButtonR3
	)
end

RunService:BindToRenderStep("CustomLock_Enforcer", Enum.RenderPriority.Camera.Value + 2, enforceWhileLocked)

-- ---------- Optional API ----------
local AimController = {}

function AimController:Init()
	if state.initDone then
		return
	end
	state.initDone = true

	ensureGui()
	bindToggle()
	bindBlockShiftLock()

	LOCAL.CharacterAdded:Connect(function()
		-- don't auto-lock on spawn; just make sure GUI exists after respawn
		task.defer(ensureGui)
	end)
end

function AimController:Start()
	if state.startDone then
		return
	end
	state.startDone = true

	-- MOVED HERE: Auto-lock once when saber ignites (server broadcast)
	-- This runs during Start phase when remotes are guaranteed to exist
	Net.OnClientEvent("Saber_BroadcastState", function(userId: number, flag: boolean?, wantOn: boolean?)
		if userId ~= LOCAL.UserId then
			return
		end

		-- tolerate older payload shapes
		local isIgniteEvent = (typeof(flag) == "boolean") and (flag :: boolean) or true
		local on: boolean = if typeof(wantOn) == "boolean"
			then wantOn :: boolean
			elseif typeof(flag) == "boolean" then wantOn :: any
			else flag :: any

		if not isIgniteEvent then
			return
		end
		if on then
			applyLock(true)
		end -- only when ignited
	end)
end

function AimController:SetLocked(v: boolean)
	applyLock(v)
end

function AimController:GetFocusPoint(): Vector2
	if state.mouseLock and state.cursor then
		return state.cursor.AbsolutePosition + (state.cursor.AbsoluteSize / 2)
	else
		local m = state.mouse or LOCAL:GetMouse()
		return Vector2.new(m.X, m.Y)
	end
end

return AimController
