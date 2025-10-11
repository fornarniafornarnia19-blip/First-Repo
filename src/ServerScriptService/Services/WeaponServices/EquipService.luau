--!strict
-- ServerScriptService/Services/EquipService.luau

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

type Mode = "SwapToHand" | "SwapToHip"
local swapIntent: { [Model]: Mode? } = setmetatable({}, { __mode = "k" }) :: any

-- Net (NetUtil) - FIXED PATH
local Net = require(RS:WaitForChild("Shared"):WaitForChild("NetUtil"))

-- ========= Path-agnostic service resolver (under SSS/Services) =========
local ServicesRoot = SSS:WaitForChild("Services")

local function findModule(root: Instance, name: string): ModuleScript
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
	error(("[EquipService] Service module '%s' not found under %s"):format(name, root:GetFullName()))
end

local function requireService(name: string): any
	return require(findModule(ServicesRoot, name))
end

-- Services (agnostic to folder structure)
local State: any = requireService("StateService")
local Rig: any = requireService("RigService")
local AnimationService: any = requireService("AnimationService")
local VFX: any = requireService("VFXService")
local Audio: any = requireService("AudioService")
-- ======================================================================

local ANIM_SET = "Saber"
local RIG_SET = "Saber"

-- ==== helpers ====
local toggling: { [Model]: boolean } = setmetatable({}, { __mode = "k" }) :: any

-- Find the hand saber model (for SFX handle access)
local function getHandSaber(character: Model): Model?
	local cos = character:FindFirstChild("Cosmetics")
	if cos and cos:IsA("Folder") then
		local m = cos:FindFirstChild("HandSaber") or cos:FindFirstChild("Hand Saber")
		if m and m:IsA("Model") then
			return m
		end
	end
	local anyInst = character:FindFirstChild("HandSaber", true) or character:FindFirstChild("Hand Saber", true)
	return (anyInst and anyInst:IsA("Model")) and anyInst or nil
end

local function getHandleFromHand(hand: Model?): BasePart?
	if not hand then
		return nil
	end
	local h = hand:FindFirstChild("Handle")
	if h and h:IsA("BasePart") then
		return h
	end
	local deep = hand:FindFirstChild("Handle", true)
	if deep and deep:IsA("BasePart") then
		return deep
	end
	return (hand.PrimaryPart and hand.PrimaryPart:IsA("BasePart")) and hand.PrimaryPart or nil
end

-- Play a disignite one-shot anchored at a world position (won't move to hip)
local function playDisigniteWorldOneShotAt(handle: BasePart?)
	if not handle then
		return
	end
	local template = handle:FindFirstChild("Disignite")
	if not (template and template:IsA("Sound") and template.SoundId ~= "") then
		return
	end

	local anchor = Instance.new("Part")
	anchor.Name = "EquipService_DisigniteAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.CFrame = handle.CFrame
	anchor.Parent = Workspace

	local att = Instance.new("Attachment")
	att.Name = "SFXAttach"
	att.Parent = anchor

	local s = template:Clone()
	s.Looped = false
	s.Parent = att
	s.TimePosition = 0
	s:Play()

	s.Ended:Once(function()
		if s.Parent then
			s.Parent = nil
		end
		if anchor.Parent then
			anchor:Destroy()
		end
	end)
	local ttl = (s.TimeLength > 0) and (s.TimeLength + 0.25) or 5
	Debris:AddItem(s, ttl)
	Debris:AddItem(anchor, ttl)
end

local function getBladeOn(c: Model): BoolValue
	local f: Instance = (State.getFolder and State.getFolder(c))
		or (c:FindFirstChild("SaberState") or Instance.new("Folder"))
	if (f :: any).Parent == nil then
		(f :: Folder).Name = "SaberState"
		(f :: Folder).Parent = c
	end
	local b = (f :: Folder):FindFirstChild("BladeOn")
	if b and b:IsA("BoolValue") then
		return b
	end
	local bb = Instance.new("BoolValue")
	bb.Name, bb.Value, bb.Parent = "BladeOn", false, f
	return bb
end

local function broadcast(user: Player | number, equipped: boolean, ignited: boolean)
	local uid = typeof(user) == "Instance" and (user :: Player).UserId or (user :: number)
	Net.FireAllClients("Saber_BroadcastState", uid, equipped, ignited)
end

-- ==== equip/unequip ====
local function equip(character: Model, player: Player)
	State.setIgnited(character, false)
	State.setBladeOn(character, false)

	swapIntent[character] = "SwapToHand"
	AnimationService.playEquip(ANIM_SET, character, "SwapToHand", player)

	VFX.destroyBlade(RIG_SET, character)
	broadcast(player, true, false)
end

local function unequip(character: Model, player: Player)
	swapIntent[character] = "SwapToHip"
	AnimationService.playEquip(ANIM_SET, character, "SwapToHip", player)
	broadcast(player, false, false)
end

local function onToggleEquip(player: Player)
	local char = player.Character
	if not char or toggling[char] or AnimationService.isEquipPlaying(char) then
		return
	end

	toggling[char] = true
	task.defer(function()
		toggling[char] = nil
	end)

	if Rig.isEquipped(RIG_SET, char) then
		-- === Holster now ===
		-- Capture handle at the *moment of input*.
		local currentHandModel = getHandSaber(char)
		local currentHandle = getHandleFromHand(currentHandModel)

		-- If blade is ON, flip OFF then play disignite one-shot at captured world pos.
		if State.getBladeOn and State.getBladeOn(char) then
			-- Tell AudioService to skip its own disignite for this transition
			char:SetAttribute("SkipNextDisignite", true)

			if State.setLastReason then
				State.setLastReason(char, "retract")
			end
			State.setBladeOn(char, false)
			State.setIgnited(char, false)

			-- stop hum via AudioService (safe if not attached)
			if Audio and currentHandModel and Audio.forceApply then
				pcall(function()
					Audio.forceApply(RIG_SET, currentHandModel, false)
				end)
			end

			-- play sound anchored at the hand's position (won't follow hip)
			playDisigniteWorldOneShotAt(currentHandle)

			-- visuals
			if VFX.retractBlade then
				VFX.retractBlade(RIG_SET, char)
			else
				VFX.destroyBlade(RIG_SET, char)
			end

			task.wait(0.05) -- let SFX/tween kick before swapping meshes
		end

		unequip(char, player)
	else
		equip(char, player)
	end
end

-- spawn holstered
local function spawnHolstered(char: Model)
	if Rig.destroyHand then
		Rig.destroyHand(RIG_SET, char)
	end

	task.spawn(function()
		for _ = 1, 50 do
			if not char.Parent then
				return
			end
			local ok = Rig.ensureHip(RIG_SET, char)
			if ok then
				break
			end
			task.wait(0.1)
		end
	end)

	State.setIgnited(char, false)
	State.setBladeOn(char, false)
	VFX.destroyBlade(RIG_SET, char)
	AnimationService.stopEquip(char)
	swapIntent[char] = nil
end

local function onCharacterAdded(_plr: Player, char: Model)
	task.defer(function()
		if char.Parent then
			spawnHolstered(char)
		end
		task.delay(0.25, function()
			if char.Parent then
				spawnHolstered(char)
			end
		end)
	end)
end

local function getOrMakeBladeOn(character: Model): BoolValue
	local folder = State.getFolder(character)
	local bb = folder:FindFirstChild("BladeOn")
	if bb and bb:IsA("BoolValue") then
		return bb
	end
	local v = Instance.new("BoolValue")
	v.Name, v.Value, v.Parent = "BladeOn", false, folder
	return v
end

-- ==== service ====
local EquipService = {}

function EquipService:Init(_services)
	AnimationService.setToggleHooks({
		onEquipSwap = function(character: Model, mode: Mode, _player: Player?)
			if swapIntent[character] ~= mode then
				return
			end
			swapIntent[character] = nil

			if mode == "SwapToHand" then
				local handModel: Model? = nil
				if Rig.ensureHand then
					handModel = Rig.ensureHand(RIG_SET, character)
				end
				if Rig.destroyHip then
					Rig.destroyHip(RIG_SET, character)
				end

				VFX.destroyBlade(RIG_SET, character)

				if handModel then
					local bladeOn = getOrMakeBladeOn(character)
					Audio.attachFromModel(RIG_SET, handModel, bladeOn)
				else
					local cos = character:FindFirstChild("Cosmetics") or character
					local found = (cos and (cos:FindFirstChild("HandSaber") or cos:FindFirstChild("Hand Saber")))
						or character:FindFirstChild("HandSaber", true)
						or character:FindFirstChild("Hand Saber", true)
					if found and found:IsA("Model") then
						Audio.attachFromModel(RIG_SET, found, getOrMakeBladeOn(character))
					end
				end
				return
			end

			-- SwapToHip (post-swap)
			if Rig.destroyHand then
				Rig.destroyHand(RIG_SET, character)
			end
			if Rig.ensureHip then
				Rig.ensureHip(RIG_SET, character)
			end
		end,
	})

	-- NEW API: Use Net.OnServerEvent instead of Ev_ToggleEquip:OnServer
	Net.OnServerEvent("Saber_ToggleEquip", onToggleEquip)

	Players.PlayerAdded:Connect(function(p)
		p.CharacterAdded:Connect(function(c)
			onCharacterAdded(p, c)
		end)
		if p.Character then
			onCharacterAdded(p, p.Character)
		end
	end)
	for _, p in ipairs(Players:GetPlayers()) do
		p.CharacterAdded:Connect(function(c)
			onCharacterAdded(p, c)
		end)
		if p.Character then
			onCharacterAdded(p, p.Character)
		end
	end

	-- NEW API: Use Net.OnServerFunction instead of Fn_RequestState:OnServer
	Net.OnServerFunction("Saber_RequestInitialState", function(plr)
		local c = plr.Character
		if not c then
			return false, false
		end
		return Rig.isEquipped(RIG_SET, c) == true, (getBladeOn(c).Value == true)
	end)
end

function EquipService:Start() end

return EquipService
