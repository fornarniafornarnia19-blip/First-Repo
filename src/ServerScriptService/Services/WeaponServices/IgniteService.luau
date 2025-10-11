--!strict
-- ServerScriptService/Services/IgniteService.luau
local Players = game:GetService("Players")
local SSS = game:GetService("ServerScriptService")
local RS = game:GetService("ReplicatedStorage")

local SET = "Saber"

-- Tune these:
local RETRACT_TIME = 0.8 -- length of your retract tween
local COOLDOWN_AFTER_RETRACT = 1.0 -- extra cooldown after retract completes

-- Net (NetUtil) - FIXED PATH
local Net = require(RS:WaitForChild("Shared"):WaitForChild("NetUtil"))

-- ========= Path-agnostic service resolver (under SSS/Services) =========
local ServicesRoot = SSS:WaitForChild("Services")

local function findModule(root: Instance, name: string): ModuleScript
	-- direct child first
	local direct = root:FindFirstChild(name)
	if direct then
		if direct:IsA("ModuleScript") then
			return direct
		end
		if direct:IsA("Folder") then
			local init = direct:FindFirstChild("init")
			if init and init:IsA("ModuleScript") then
				return init
			end
		end
	end
	-- recursive search (supports nested folders and Folder/init)
	local found = root:FindFirstChild(name, true)
	if found then
		if found:IsA("ModuleScript") then
			return found
		end
		if found:IsA("Folder") then
			local init = found:FindFirstChild("init")
			if init and init:IsA("ModuleScript") then
				return init
			end
		end
	end
	error(("[IgniteService] Service module '%s' not found under %s"):format(name, root:GetFullName()))
end

local function requireService(name: string): any
	return require(findModule(ServicesRoot, name))
end

-- Services (agnostic to folder structure)
local Rig: any = requireService("RigService")
local State: any = requireService("StateService")
local VFX: any = requireService("VFXService")
local Anim: any = requireService("AnimationService")
local Audio: any = requireService("AudioService")
-- ======================================================================

local debouncing: { [Model]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local attachedModel: { [Model]: Model? } = setmetatable({}, { __mode = "k" }) :: any

-- A single hard lock: blocks ignite while retracting AND for an extra cooldown after.
local lockUntil: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any

-- Return exactly Folder? (not generic Instance?)
local function getCosmetics(character: Model): Folder?
	local c1 = character:FindFirstChild("Cosmetics")
	if c1 and c1:IsA("Folder") then
		return c1
	end
	local c2 = character:FindFirstChild("cosmetics")
	if c2 and c2:IsA("Folder") then
		return c2
	end
	return nil
end

local function getHandSaber(character: Model): Model?
	local cos = getCosmetics(character)
	local m = cos and (cos:FindFirstChild("HandSaber") or cos:FindFirstChild("Hand Saber"))
	if m and m:IsA("Model") then
		return m
	end
	local anyInst = character:FindFirstChild("HandSaber", true) or character:FindFirstChild("Hand Saber", true)
	return (anyInst and anyInst:IsA("Model")) and anyInst or nil
end

local function attachAudioIfPossible(character: Model)
	local hand = getHandSaber(character)
	if not hand or attachedModel[character] == hand then
		return
	end
	attachedModel[character] = hand
	local bladeOn = State.getFolder(character):WaitForChild("BladeOn") :: BoolValue
	Audio.attachFromModel(SET, hand, bladeOn)
end

local function handleToggleIgnite(player: Player)
	local char = player.Character
	if not (char and char.Parent) then
		return
	end
	if debouncing[char] then
		return
	end
	if not Rig.isEquipped(SET, char) then
		return
	end

	-- Void inputs during retract and for 1s after retract ends. No queuing.
	local now = os.clock()
	if lockUntil[char] and now < lockUntil[char] then
		return
	end

	if not attachedModel[char] then
		attachAudioIfPossible(char)
		task.wait(0.05)
	end

	debouncing[char] = true
	task.delay(0.4, function()
		debouncing[char] = nil
	end)

	local wantOn = not State.getBladeOn(char)

	-- Client aim toggle - NEW API
	Net.FireClient(player, "Saber_AimMode", wantOn)

	-- (optional) reason for VFX tweens
	if State.setLastReason then
		local reason = (if wantOn then "ignite" else "retract") :: "ignite" | "retract"
		State.setLastReason(char, reason)
	end

	-- cosmetic character anim
	local AnimAny: any = Anim
	if AnimAny.playIgniteAndToggle then
		AnimAny.playIgniteAndToggle(SET, char, wantOn)
	elseif AnimAny.playIgnite then
		AnimAny.playIgnite(SET, char, wantOn)
	end

	-- authoritative state
	State.setBladeOn(char, wantOn)
	State.setIgnited(char, wantOn)

	-- blade visuals
	if wantOn then
		if VFX.createBlade then
			VFX.createBlade(SET, char)
		else
			VFX.apply(SET, char)
		end
	else
		if VFX.retractBlade then
			VFX.retractBlade(SET, char)
		else
			VFX.destroyBlade(SET, char)
		end
		-- Start lock covering retract duration + extra cooldown; inputs during this window are ignored.
		lockUntil[char] = os.clock() + RETRACT_TIME + COOLDOWN_AFTER_RETRACT
	end

	-- audio hum assert
	local hand = attachedModel[char]
	if hand and Audio.forceApply then
		Audio.forceApply(SET, hand, wantOn)
	end

	-- broadcast to everyone else (userId, equipped?, ignited?) - NEW API
	Net.FireAllClients("Saber_BroadcastState", player.UserId, true, wantOn)
end

-- NEW API: Register handler
local IgniteService = {}

function IgniteService:Init()
	Net.OnServerEvent("Saber_ToggleIgnite", handleToggleIgnite)
end

function IgniteService:Start() end

return IgniteService
