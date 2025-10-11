--!strict
-- ReplicatedStorage/Client/Controllers/WalkingController.luau
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")

type Ctx = { ActionName: string?, Net: any? }

local M = {} :: {
	_started: boolean,
	_actionName: string,
	_net: any?,
	_down: boolean,
	_beganConn: RBXScriptConnection?,
	_endedConn: RBXScriptConnection?,

	Init: (ctx: Ctx?) -> (),
	Start: () -> (),
	Stop: () -> (),
}
M._started = false
M._actionName = "HoldShiftSlowWalk"
M._net = nil
M._down = false
M._beganConn = nil
M._endedConn = nil

local function getClientEvent(name: string): RemoteEvent?
	local net = M._net or (_G :: any).Net
	if net ~= nil then
		local ok, ev = pcall(function()
			if typeof(net.Client) == "function" then
				return net:Client(name)
			end
			if typeof(net.Get) == "function" then
				return net:Get(name)
			end
			return nil
		end)
		if ok and ev and typeof(ev) == "Instance" and ev:IsA("RemoteEvent") then
			return ev
		end
	end
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local inst = remotes and remotes:FindFirstChild(name)
	return (inst and inst:IsA("RemoteEvent")) and inst or nil
end

-- CAS handler
local function onShift(_name: string, state: Enum.UserInputState, input: InputObject)
	local kc = input.KeyCode
	if kc ~= Enum.KeyCode.LeftShift and kc ~= Enum.KeyCode.RightShift then
		return Enum.ContextActionResult.Pass
	end

	local ev = getClientEvent("Walk_SetSlow")
	if state == Enum.UserInputState.Begin then
		if not M._down then
			M._down = true
			if ev then
				ev:FireServer(true)
			end
		end
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		if M._down then
			M._down = false
			if ev then
				ev:FireServer(false)
			end
		end
	end
	return Enum.ContextActionResult.Sink
end

-- UIS fallbacks (don’t early-return on gp—some experiences consume input)
local function onInputBegan(input: InputObject, _gp: boolean)
	if input.KeyCode ~= Enum.KeyCode.LeftShift and input.KeyCode ~= Enum.KeyCode.RightShift then
		return
	end
	if not M._down then
		M._down = true
		local ev = getClientEvent("Walk_SetSlow")
		if ev then
			ev:FireServer(true)
		end
	end
end

local function onInputEnded(input: InputObject, _gp: boolean)
	if input.KeyCode ~= Enum.KeyCode.LeftShift and input.KeyCode ~= Enum.KeyCode.RightShift then
		return
	end
	if M._down then
		M._down = false
		local ev = getClientEvent("Walk_SetSlow")
		if ev then
			ev:FireServer(false)
		end
	end
end

function M.Init(ctx: Ctx?)
	if not RunService:IsClient() then
		return
	end
	M._actionName = (ctx and ctx.ActionName) or "HoldShiftSlowWalk"
	M._net = ctx and ctx.Net or (_G :: any).Net
end

function M.Start()
	if not RunService:IsClient() then
		return
	end
	if M._started then
		return
	end
	M._started = true

	-- Bind at high priority if available; else fallback
	local HIGH = 2000
	local bindAtPriority = (ContextActionService :: any).BindActionAtPriority
	if bindAtPriority ~= nil and (typeof(bindAtPriority) == "function" or type(bindAtPriority) == "function") then
		local fn = bindAtPriority :: any
		fn(ContextActionService, M._actionName, onShift, false, HIGH, Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift)
	else
		ContextActionService:BindAction(M._actionName, onShift, false, Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift)
	end

	-- UIS fallbacks
	M._beganConn = UserInputService.InputBegan:Connect(onInputBegan)
	M._endedConn = UserInputService.InputEnded:Connect(onInputEnded)

	-- Apply if already held
	if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift) then
		if not M._down then
			M._down = true
			local ev = getClientEvent("Walk_SetSlow")
			if ev then
				ev:FireServer(true)
			end
		end
	end
end

function M.Stop()
	if not M._started then
		return
	end
	M._started = false

	pcall(function()
		ContextActionService:UnbindAction(M._actionName)
	end)

	-- Disconnect UIS fallbacks
	if M._beganConn and M._beganConn.Connected then
		M._beganConn:Disconnect()
	end
	if M._endedConn and M._endedConn.Connected then
		M._endedConn:Disconnect()
	end
	M._beganConn, M._endedConn = nil, nil

	if M._down then
		M._down = false
		local ev = getClientEvent("Walk_SetSlow")
		if ev then
			ev:FireServer(false)
		end
	end
end

return M
