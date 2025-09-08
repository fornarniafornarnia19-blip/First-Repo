--!strict
-- ServerScriptService/ServerSaber_NoTool.server.lua

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

-- We do NOT WaitForChild here. We boot when the folder actually exists.
local SABER_FOLDERS: { string } = { "SaberHilt", "Saber" }

local function bootWithFolder(saberFolder: Folder)
	-- === Modules (explicit) ===
	local RemotesModule = saberFolder:WaitForChild("Remotes") :: ModuleScript
	local StateModule = saberFolder:WaitForChild("State") :: ModuleScript
	local NoToolModule = saberFolder:WaitForChild("NoTool") :: ModuleScript
	local RigModule = saberFolder:WaitForChild("Rig") :: ModuleScript
	local EquipAnimModule = saberFolder:WaitForChild("EquipAnim") :: ModuleScript

	local Remotes = (require :: any)(RemotesModule)
	local State = (require :: any)(StateModule)
	local NoTool = (require :: any)(NoToolModule)
	local Rig = (require :: any)(RigModule)
	local EquipAnim = (require :: any)(EquipAnimModule)

	-- Audio is optional in this pack; try local first, then ServerStorage.Saber
	local AudioModule: ModuleScript? = (saberFolder:FindFirstChild("Audio") :: ModuleScript?)
		or (
			ServerStorage:FindFirstChild("Saber") and (ServerStorage.Saber:FindFirstChild("Audio") :: ModuleScript?)
			or nil
		)
	local Audio: any = AudioModule and (require :: any)(AudioModule) or nil

	-- debounce per-character
	local toggling: { [Model]: boolean } = setmetatable({}, { __mode = "k" }) :: any

	-- ===== Audio helpers (server-only) =====
	local attachedModel: { [Model]: Model? } = setmetatable({}, { __mode = "k" }) :: any

	local function getCosmeticsFolder(character: Model): Folder?
		local f = character:FindFirstChild("cosmetics") or character:FindFirstChild("Cosmetics")
		if f and f:IsA("Folder") then
			return f
		end
		f = character:FindFirstChild("cosmetics", true) or character:FindFirstChild("Cosmetics", true)
		return (f and f:IsA("Folder")) and f or nil
	end

	local function getHandSaber(character: Model): Model?
		local cos = getCosmeticsFolder(character)
		if cos then
			local m = cos:FindFirstChild("HandSaber") or cos:FindFirstChild("Hand Saber")
			if m and m:IsA("Model") then
				return m
			end
		end
		local any = character:FindFirstChild("HandSaber", true) or character:FindFirstChild("Hand Saber", true)
		return (any and any:IsA("Model")) and any or nil
	end

	-- strict-safe: never mutate a BoolValue? directly
	local function getBladeOn(character: Model): BoolValue
		-- pick/create the state folder
		local folder: Instance
		if State.getFolder then
			folder = State.getFolder(character)
		else
			local existingFolder = character:FindFirstChild("SaberState")
			if existingFolder and existingFolder:IsA("Folder") then
				folder = existingFolder
			else
				local f = Instance.new("Folder")
				f.Name = "SaberState"
				f.Parent = character
				folder = f
			end
		end

		-- reuse if present
		local existing = folder:FindFirstChild("BladeOn")
		if existing and existing:IsA("BoolValue") then
			return existing
		end

		-- create fresh (use concrete local, then return)
		local bb = Instance.new("BoolValue")
		bb.Name = "BladeOn"
		bb.Value = false
		bb.Parent = folder
		return bb
	end

	local function destroyAudio(character: Model)
		if not Audio then
			return
		end
		local hand = attachedModel[character]
		if hand then
			Audio.stopForModel(hand)
			Audio.destroyForModel(hand)
			attachedModel[character] = nil
		end
	end

	local function attachAudioIfPossible(character: Model)
		if not Audio then
			return
		end
		local hand = getHandSaber(character)
		if not hand then
			return
		end
		if attachedModel[character] == hand then
			return
		end

		local prev = attachedModel[character]
		if prev and prev ~= hand then
			Audio.destroyForModel(prev)
		end
		attachedModel[character] = hand

		hand.AncestryChanged:Connect(function(_, parent)
			if parent == nil and attachedModel[character] == hand then
				attachedModel[character] = nil
			end
		end)

		local bladeOn = getBladeOn(character)
		Audio.attachFromModel(hand, bladeOn)

		if bladeOn.Value then
			task.delay(0.05, function()
				if hand.Parent then
					Audio.forceApply(hand, true)
				end
			end)
		end
	end

	-- ===== equip/unequip toggle =====
	local function equip(character: Model, player: Player)
		State.setIgnited(character, false)
		State.setBladeOn(character, false)
		EquipAnim.play(character, "SwapToHand", player)

		task.defer(function()
			for _ = 1, 30 do -- ~1s max
				if getHandSaber(character) then
					break
				end
				task.wait(0.033)
			end
			attachAudioIfPossible(character)
		end)
	end

	local function unequip(character: Model, player: Player)
		NoTool.setDisignited(character)
		destroyAudio(character)
		EquipAnim.play(character, "SwapToHip", player)
		-- removed State.getBladeOn/State.setBladeOn
	end

	local function onToggle(player: Player)
		local char = player.Character
		if not char or toggling[char] or EquipAnim.isPlaying(char) then
			return
		end
		toggling[char] = true
		task.defer(function()
			toggling[char] = nil
		end)

		if Rig.isEquipped(char) then
			unequip(char, player)
		else
			equip(char, player)
		end
	end

	Remotes.Toggle.OnServerEvent:Connect(onToggle)

	-- ===== spawn handling =====
	local function spawnHolstered(character: Model)
		Rig.destroyHand(character)
		Rig.ensureHip(character)
		State.setIgnited(character, false)
		State.setBladeOn(character, false)
		EquipAnim.stop(character)
		destroyAudio(character)
	end

	local function onCharacterAdded(p: Player, character: Model)
		task.defer(function()
			if character.Parent then
				spawnHolstered(character)
			end

			local cos = getCosmeticsFolder(character)
			if cos then
				cos.ChildAdded:Connect(function(ch)
					if ch:IsA("Model") and (ch.Name == "HandSaber" or ch.Name == "Hand Saber") then
						attachAudioIfPossible(character)
					end
				end)
				cos.ChildRemoved:Connect(function(ch)
					if ch:IsA("Model") and (ch.Name == "HandSaber" or ch.Name == "Hand Saber") then
						destroyAudio(character)
					end
				end)
			end

			character.ChildAdded:Connect(function(ch)
				if ch:IsA("Model") and (ch.Name == "HandSaber" or ch.Name == "Hand Saber") then
					attachAudioIfPossible(character)
				end
			end)
			character.ChildRemoved:Connect(function(ch)
				if ch:IsA("Model") and (ch.Name == "HandSaber" or ch.Name == "Hand Saber") then
					destroyAudio(character)
				end
			end)

			local hum = character:FindFirstChildOfClass("Humanoid")
			if hum then
				hum.Died:Once(function()
					EquipAnim.stop(character)
					NoTool.setDisignited(character)
					Rig.destroyHand(character)
					Rig.destroyHip(character)
					destroyAudio(character)
				end)
			end
		end)
	end

	local function wirePlayer(plr: Player)
		plr.CharacterAdded:Connect(function(char)
			onCharacterAdded(plr, char)
		end)
		if plr.Character then
			onCharacterAdded(plr, plr.Character)
		end
	end

	Players.PlayerAdded:Connect(wirePlayer)
	for _, plr in ipairs(Players:GetPlayers()) do
		wirePlayer(plr)
	end
end

-- Try immediate boot if the folder already exists
local booted = false
for i = 1, #SABER_FOLDERS do
	local name = SABER_FOLDERS[i]
	local inst = ServerStorage:FindFirstChild(name)
	if inst and inst:IsA("Folder") then
		bootWithFolder(inst :: Folder)
		booted = true
		break
	end
end

-- If not found yet, boot when it appears later (no blocking)
if not booted then
	ServerStorage.ChildAdded:Connect(function(child: Instance)
		if child:IsA("Folder") then
			for i = 1, #SABER_FOLDERS do
				local name = SABER_FOLDERS[i]
				if child.Name == name and not booted then
					bootWithFolder(child :: Folder)
					booted = true
					break
				end
			end
		end
	end)
end
