--!strict
local RS = game:GetService("ReplicatedStorage")

-- Wait for server flags
local Boot = RS:WaitForChild("Boot", 10)
if Boot then
	local netReady = Boot:WaitForChild("NetReady", 10) :: BoolValue?
	local serverReady = Boot:WaitForChild("ServerReady", 10) :: BoolValue?
	if netReady and not netReady.Value then
		netReady.Changed:Wait()
	end
	if serverReady and not serverReady.Value then
		serverReady.Changed:Wait()
	end
end

-- CRITICAL: Wait for remotes to actually replicate to client
local netFolder = RS:WaitForChild("_NetRemotes", 10)
if netFolder then
	-- Wait until at least one remote exists (ensures replication has started)
	while #netFolder:GetChildren() == 0 do
		netFolder.ChildAdded:Wait()
	end
	-- Give a tiny buffer for all remotes to replicate
	task.wait(0.1)
end

-- Load Net to validate path (not strictly required)
require(RS:WaitForChild("Shared"):WaitForChild("NetUtil"))

-- ===== RECURSIVE controller loading under RS/Client/Controllers =====
local ControllersFolder = RS:WaitForChild("Client"):WaitForChild("Controllers")

local function safeRequire(mod: ModuleScript)
	local ok, res = pcall(require, mod)
	if not ok then
		warn(("[Boot.client] Require failed for %s: %s"):format(mod:GetFullName(), tostring(res)))
		return nil
	end
	return res
end

local function findInitModuleInFolder(folder: Folder): ModuleScript?
	-- Support an init ModuleScript inside a folder (init / Init / init.client / init.server)
	local exact = folder:FindFirstChild("init")
	if exact and exact:IsA("ModuleScript") then
		return exact
	end
	for _, ch in ipairs(folder:GetChildren()) do
		if ch:IsA("ModuleScript") then
			local n = string.lower(ch.Name)
			if n == "init" or n:match("^init%.") then
				return ch
			end
		end
	end
	return nil
end

local function requireController(inst: Instance)
	if inst:IsA("ModuleScript") then
		return safeRequire(inst)
	elseif inst:IsA("Folder") then
		local initMod = findInitModuleInFolder(inst)
		if initMod then
			return safeRequire(initMod)
		end
	end
	return nil
end

local controllers: { [string]: any } = {}

local function loadAll(folder: Folder)
	for _, ch in ipairs(folder:GetChildren()) do
		local mod = requireController(ch)
		if mod ~= nil then
			controllers[ch.Name] = mod
		end
		if ch:IsA("Folder") then
			loadAll(ch)
		end
	end
end

loadAll(ControllersFolder)

-- Sort by name for deterministic Init/Start order
local ordered = {}
for name, mod in pairs(controllers) do
	table.insert(ordered, { name = name, mod = mod })
end
table.sort(ordered, function(a, b)
	return a.name < b.name
end)

-- Phase 1: Init (service-style only)
for _, item in ipairs(ordered) do
	local c = item.mod
	if typeof(c) == "table" and type(c.Init) == "function" then
		local ok, err = pcall(function()
			c:Init()
		end)
		if not ok then
			warn(("[Boot.client] Init error for %s: %s"):format(item.name, tostring(err)))
		end
	end
end

-- Phase 2: Start
-- Supports:
--  A) service-style: table with :Start()
--  B) factory-style: table with .start(cfg?) -> instance
--  C) plain function: function() -> ()
local startedInstances: { [string]: any } = {}

for _, item in ipairs(ordered) do
	local c = item.mod

	task.spawn(function()
		-- A) Service-style
		if typeof(c) == "table" and type(c.Start) == "function" then
			local ok, err = pcall(function()
				c:Start()
			end)
			if not ok then
				warn(("[Boot.client] Start error for %s: %s"):format(item.name, tostring(err)))
			end
			return
		end

		-- B) Factory-style (like EightDirController with .start)
		if typeof(c) == "table" and type(c.start) == "function" then
			local ok, res = pcall(function()
				-- Call without args; pass config here if you want global defaults.
				return c.start()
			end)
			if not ok then
				warn(("[Boot.client] start() error for %s: %s"):format(item.name, tostring(res)))
			else
				startedInstances[item.name] = res
			end
			return
		end

		-- C) Plain function module
		if type(c) == "function" then
			local ok, err = pcall(c)
			if not ok then
				warn(("[Boot.client] Function module error for %s: %s"):format(item.name, tostring(err)))
			end
			return
		end
	end)
end

-- (Optional) expose started instances somewhere if needed:
-- return startedInstances
