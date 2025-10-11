--!strict
-- ReplicatedStorage/Client/Controllers/SwingController.client.luau
local RS = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")
local CAS = game:GetService("ContextActionService")

-- ---------- Truly agnostic require helpers ----------
type PathSpec = { root: Instance, path: { string } }

local _foundCache: { [string]: ModuleScript } = {}

local function _recursiveFind(parent: Instance, name: string, maxDepth: number?): ModuleScript?
	local depth = maxDepth or 5
	if depth <= 0 then
		return nil
	end

	-- Check direct children first
	for _, child in ipairs(parent:GetChildren()) do
		if child.Name == name and child:IsA("ModuleScript") then
			return child
		end
	end

	-- Then recurse into folders
	for _, child in ipairs(parent:GetChildren()) do
		if child:IsA("Folder") then
			local found = _recursiveFind(child, name, depth - 1)
			if found then
				return found
			end
		end
	end

	return nil
end

local function _followPath(spec: PathSpec, timeout: number?): Instance?
	local node: Instance = spec.root
	for _, seg in ipairs(spec.path) do
		local child = node:FindFirstChild(seg)
		if not child then
			child = node:WaitForChild(seg, timeout or 2)
		end
		if not child then
			return nil
		end
		node = child
	end
	return node
end

local function requireAny(name: string, candidates: { PathSpec | ModuleScript | Instance? }?, timeout: number?): any
	-- cache hit
	local cached = _foundCache[name]
	if cached then
		return require(cached)
	end

	local searchList = candidates or {}

	-- try candidates in order
	for _, c in ipairs(searchList) do
		if c == nil then
			continue
		end

		local inst: Instance?
		if typeof(c) == "Instance" then
			inst = c
		else
			inst = _followPath(c :: PathSpec, timeout)
		end

		if inst and inst:IsA("ModuleScript") then
			_foundCache[name] = inst
			return require(inst)
		end
	end

	-- Fallback: recursive search from ReplicatedStorage
	local found = _recursiveFind(RS, name, 6)
	if found then
		_foundCache[name] = found
		return require(found)
	end

	error(string.format("Module '%s' not found in any candidate locations or via recursive search", name))
end

-- Require NetUtil with agnostic search
local Net = requireAny("NetUtil", {
	{ root = RS, path = { "Shared", "NetUtil" } },
	{ root = RS, path = { "Net", "NetUtil" } },
	{ root = RS, path = { "Packages", "NetUtil" } },
	script:FindFirstChild("NetUtil"),
}, 2)

-- Try to load NetDefs for validation (optional)
local NetDefs = nil
pcall(function()
	NetDefs = requireAny("NetDefs", {
		{ root = RS, path = { "Shared", "NetDefs" } },
		{ root = RS, path = { "Net", "NetDefs" } },
		{ root = RS, path = { "Packages", "NetDefs" } },
		script:FindFirstChild("NetDefs"),
	}, 2)
end)

-- ---------- Swing direction validation ----------
local VALID_DIRS = {
	Overhead = true,
	Left = true,
	Right = true,
	UpLeft = true,
	UpRight = true,
	DownLeft = true,
	DownRight = true,
}

local function isValidDir(dir: string): boolean
	return VALID_DIRS[dir] == true
end

-- ---------- rest of your original script ----------
local ACTION = "Saber_Swing"
local started = false

local down: { [Enum.KeyCode]: boolean } = {
	[Enum.KeyCode.W] = false,
	[Enum.KeyCode.A] = false,
	[Enum.KeyCode.S] = false,
	[Enum.KeyCode.D] = false,
}
local lastDownAt: { [Enum.KeyCode]: number } = {}
local GRACE = 0.25 -- taps just before click still count
local lastClickSent = 0.0
local CLICK_THROTTLE = 0.04

local DEFAULT_S_ALONE = "Overhead"

local function typingBlocked(): boolean
	return UIS:GetFocusedTextBox() ~= nil
end

local function isActive(kc: Enum.KeyCode): boolean
	if down[kc] then
		return true
	end
	local t = lastDownAt[kc]
	return t ~= nil and (time() - t) <= GRACE
end

local function pickDirFromWASD(): string
	local W = isActive(Enum.KeyCode.W)
	local A = isActive(Enum.KeyCode.A)
	local S = isActive(Enum.KeyCode.S)
	local D = isActive(Enum.KeyCode.D)

	if W and A then
		return "UpRight"
	end
	if W and D then
		return "UpLeft"
	end
	if S and A then
		return "DownRight"
	end
	if S and D then
		return "DownLeft"
	end

	if W then
		return "Overhead"
	end
	if A then
		return "Right"
	end
	if D then
		return "Left"
	end
	if S then
		return DEFAULT_S_ALONE
	end
	return "Overhead"
end

local function sendSwing()
	local now = time()
	if now - lastClickSent < CLICK_THROTTLE then
		return
	end
	lastClickSent = now

	local dir = pickDirFromWASD()
	if isValidDir(dir) then
		Net.FireServer("Saber_Swing", dir)
	end
end

local function bindInput()
	if started then
		return
	end
	started = true

	UIS.InputBegan:Connect(function(io, gp)
		if gp then
			return
		end
		local k = io.KeyCode
		if down[k] ~= nil then
			down[k] = true
			lastDownAt[k] = time()
		end
	end)

	UIS.InputEnded:Connect(function(io, gp)
		if gp then
			return
		end
		local k = io.KeyCode
		if down[k] ~= nil then
			down[k] = false
		end
	end)

	-- High-priority CAS bind for left click
	local handler = function(_, state)
		if state ~= Enum.UserInputState.Begin or typingBlocked() then
			return Enum.ContextActionResult.Pass
		end
		sendSwing()
		return Enum.ContextActionResult.Sink
	end
	if CAS.BindActionAtPriority then
		CAS:BindActionAtPriority(ACTION, handler, false, 2000, Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonR2)
	else
		CAS:BindAction(ACTION, handler, false, Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonR2)
	end

	-- Fallback: if some other script sinks CAS, we'll still catch the click here
	UIS.InputBegan:Connect(function(io, gp)
		if gp or typingBlocked() then
			return
		end
		if io.UserInputType == Enum.UserInputType.MouseButton1 then
			sendSwing()
		end
	end)
end

local Controller = {}
function Controller:Init() end
function Controller:Start()
	bindInput()
end
function Controller:Stop()
	pcall(function()
		CAS:UnbindAction(ACTION)
	end)
	started = false
end
return Controller
