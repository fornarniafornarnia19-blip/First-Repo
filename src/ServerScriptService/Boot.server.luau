--!strict
local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")

-- ===== Boot flags in RS =====
local Boot = RS:FindFirstChild("Boot") or Instance.new("Folder")
Boot.Name, Boot.Parent = "Boot", RS

local function mkBool(name: string, val: boolean): BoolValue
	local b = Boot:FindFirstChild(name) :: BoolValue?
	if not b then
		b = Instance.new("BoolValue")
		b.Name, b.Parent = name, Boot
	end
	b.Value = val
	return b
end

local NetReady = mkBool("NetReady", false)
local ServerReady = mkBool("ServerReady", false)

-- ===== NetDefs & NetUtil (ReplicatedStorage/Shared) =====
local okNetDefs, NetDefs = pcall(function()
	return require(RS:WaitForChild("Shared"):WaitForChild("NetDefs"))
end)
if not okNetDefs then
	error("[Boot.server] NetDefs require failed: " .. tostring(NetDefs))
end

local okNetUtil, NetUtil = pcall(function()
	return require(RS:WaitForChild("Shared"):WaitForChild("NetUtil"))
end)
if not okNetUtil then
	error("[Boot.server] NetUtil require failed: " .. tostring(NetUtil))
end

-- Create remotes exactly once per session
if not Boot:GetAttribute("NetCreated") then
	local createFn = (NetUtil :: any).ServerCreateAll
	if type(createFn) ~= "function" then
		error("[Boot.server] NetUtil missing ServerCreateAll()")
	end
	createFn(NetDefs) -- Pass NetDefs to the create function
	Boot:SetAttribute("NetCreated", true)
end
NetReady.Value = true

-- ===== Recursive service loading under ServerScriptService/Services =====
local ServicesFolder = SSS:WaitForChild("Services")

local function requireService(inst: Instance): any
	if inst:IsA("ModuleScript") then
		local ok, mod = pcall(require, inst)
		if not ok then
			warn(("[Boot.server] Require failed for %s: %s"):format(inst:GetFullName(), tostring(mod)))
			return nil
		end
		return mod
	end
	if inst:IsA("Folder") then
		local init = inst:FindFirstChild("init")
		if init and init:IsA("ModuleScript") then
			local ok, mod = pcall(require, init)
			if not ok then
				warn(("[Boot.server] Require failed for %s: %s"):format(init:GetFullName(), tostring(mod)))
				return nil
			end
			return mod
		end
	end
	return nil
end

local Services: { [string]: any } = {}

local function loadAll(folder: Folder)
	for _, ch in ipairs(folder:GetChildren()) do
		local mod = requireService(ch)
		if mod then
			if Services[ch.Name] ~= nil then
				warn(
					("[Boot.server] Duplicate service name '%s' from %s; overwriting previous."):format(
						ch.Name,
						ch:GetFullName()
					)
				)
			end
			Services[ch.Name] = mod
		end
		if ch:IsA("Folder") then
			loadAll(ch)
		end
	end
end

loadAll(ServicesFolder)

-- ===== Phase 1: Init =====
for name, svc in pairs(Services) do
	if type(svc.Init) == "function" then
		local ok, err = pcall(function()
			svc:Init(Services)
		end)
		if not ok then
			warn(("[Boot.server] Init error for %s: %s"):format(name, tostring(err)))
		end
	end
end

ServerReady.Value = true

-- ===== Phase 2: Start =====
for name, svc in pairs(Services) do
	if type(svc.Start) == "function" then
		task.spawn(function()
			local ok, err = pcall(function()
				svc:Start()
			end)
			if not ok then
				warn(("[Boot.server] Start error for %s: %s"):format(name, tostring(err)))
			end
		end)
	end
end
