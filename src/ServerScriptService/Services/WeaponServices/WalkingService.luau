--!strict
-- ServerScriptService/Services/WalkingService.luau
-- One and only WalkingService: SERVER-AUTHORITATIVE slow-walk.
-- Listens for C2S "Walk_SetSlow" and sets Humanoid.WalkSpeed.
-- Also mirrors the state into StateService ("SlowWalk") and reapplies on respawn.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

export type Ctx = {
	NormalSpeed: number?, -- default 16
	SlowSpeed: number?, -- default 12 (your current file)
	EchoToClient: boolean?, -- default false (fires "Walk_EchoSlow")
}

-- ===== Config =====
local NORMAL = 16
local SLOW = 8
local ECHO = false

-- ===== Remotes =====
local SetSlowRE: RemoteEvent? = nil
local EchoRE: RemoteEvent? = nil

-- ===== Optional StateService (resolved agnostically) =====
local ServicesFolder = ServerScriptService:WaitForChild("Services")
local State: any = nil
do
	-- Find "StateService" anywhere under Services (nested allowed)
	local inst = ServicesFolder:FindFirstChild("StateService", true)
	if inst and inst:IsA("ModuleScript") then
		local ok, mod = pcall(require, inst)
		if ok and type(mod) == "table" then
			State = mod
		end
	end
end

-- ===== State =====
local started = false
local charConns: { [Player]: RBXScriptConnection } = {}

-- ===== Helpers =====
local function getHumanoid(char: Model): Humanoid?
	return char:FindFirstChildOfClass("Humanoid")
end

local function applyToChar(char: Model, slowed: boolean)
	local hum = getHumanoid(char)
	if hum then
		hum.WalkSpeed = slowed and SLOW or NORMAL
	end
end

local function ensureRemotes()
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name = "Remotes"
		remotes.Parent = ReplicatedStorage
	end

	local setInst = remotes:FindFirstChild("Walk_SetSlow")
	if not setInst then
		local ev = Instance.new("RemoteEvent")
		ev.Name = "Walk_SetSlow"
		ev.Parent = remotes
		SetSlowRE = ev
	else
		SetSlowRE = setInst :: RemoteEvent
	end

	if ECHO then
		local echoInst = remotes:FindFirstChild("Walk_EchoSlow")
		if not echoInst then
			local ev2 = Instance.new("RemoteEvent")
			ev2.Name = "Walk_EchoSlow"
			ev2.Parent = remotes
			EchoRE = ev2
		else
			EchoRE = echoInst :: RemoteEvent
		end
	end

	assert(SetSlowRE, "[WalkingService] Missing RemoteEvent 'Walk_SetSlow'")
end

local function hookPlayer(p: Player)
	-- default to persisted state on spawn (falls back to false)
	if charConns[p] then
		charConns[p]:Disconnect()
	end
	charConns[p] = p.CharacterAdded:Connect(function(char)
		local slowed = false
		if State and State.isSlowWalk then
			local ok, val = pcall(function()
				return State.isSlowWalk(char)
			end)
			if ok and typeof(val) == "boolean" then
				slowed = val
			end
		end
		applyToChar(char, slowed)
	end)
	if p.Character then
		local slowed = false
		if State and State.isSlowWalk then
			local ok, val = pcall(function()
				return State.isSlowWalk(p.Character :: Model)
			end)
			if ok and typeof(val) == "boolean" then
				slowed = val
			end
		end
		applyToChar(p.Character, slowed)
	end
end

-- ===== Public API expected by your boot =====
local M = {} :: {
	Init: (self: any, services: { [string]: any }?, ctx: Ctx?) -> (),
	Start: (self: any) -> (),
	Stop: (self: any) -> (),
	Destroy: (self: any) -> (),
}

function M:Init(_services: { [string]: any }?, ctx: Ctx?)
	-- Server only; silently no-op on client
	if not RunService:IsServer() then
		return
	end

	if ctx then
		if typeof(ctx.NormalSpeed) == "number" then
			NORMAL = ctx.NormalSpeed :: number
		end
		if typeof(ctx.SlowSpeed) == "number" then
			SLOW = ctx.SlowSpeed :: number
		end
		if typeof(ctx.EchoToClient) == "boolean" then
			ECHO = ctx.EchoToClient :: boolean
		end
	end
end

function M:Start()
	if not RunService:IsServer() then
		return
	end
	if started then
		return
	end
	started = true

	ensureRemotes()

	-- Hook players for spawn reset
	Players.PlayerAdded:Connect(hookPlayer)
	for _, p in ipairs(Players:GetPlayers()) do
		hookPlayer(p)
	end

	-- Main handler
	(SetSlowRE :: RemoteEvent).OnServerEvent:Connect(function(player: Player, holding: boolean)
		if typeof(holding) ~= "boolean" then
			return
		end
		local char = player.Character
		if char then
			-- Apply speed
			applyToChar(char, holding)
			-- Mirror into StateService if present
			if State and State.setSlowWalk then
				pcall(function()
					State.setSlowWalk(char, holding)
				end)
			end
		end
		if ECHO and EchoRE then
			(EchoRE :: RemoteEvent):FireClient(player, holding)
		end
	end)
end

function M:Stop()
	if not started then
		return
	end
	started = false
	for p, conn in pairs(charConns) do
		if conn and conn.Connected then
			conn:Disconnect()
		end
		charConns[p] = nil
	end
end

function M:Destroy()
	self:Stop()
	SetSlowRE, EchoRE = nil, nil
end

return M
