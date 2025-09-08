--!strict
local Players = game:GetService("Players")
local SS = game:GetService("ServerStorage")
local SaberFolder = SS:WaitForChild("Saber")

local Remotes = require(SaberFolder:WaitForChild("Remotes"))
local State = require(SaberFolder:WaitForChild("State"))
local Visuals = require(SaberFolder:WaitForChild("Visuals"))
local AnimToggle = require(SaberFolder:WaitForChild("AnimToggle"))
local Audio = require(SaberFolder:WaitForChild("Audio")) -- model-anchored

-- Debounce per character (weak keys)
local debouncing: { [Model]: boolean } = setmetatable({}, { __mode = "k" }) :: any
-- Track which HandSaber model we attached audio to (weak keys)
local attachedModel: { [Model]: Model? } = setmetatable({}, { __mode = "k" }) :: any

-- ----- cosmetics-aware lookup -----
local function getCosmeticsFolder(character: Model): Folder?
	local f = character:FindFirstChild("cosmetics")
	if f and f:IsA("Folder") then
		return f
	end
	local g = character:FindFirstChild("Cosmetics")
	if g and g:IsA("Folder") then
		return g
	end
	local any = character:FindFirstChild("cosmetics", true)
	if any and any:IsA("Folder") then
		return any
	end
	any = character:FindFirstChild("Cosmetics", true)
	if any and any:IsA("Folder") then
		return any
	end
	return nil
end

local function getHandSaber(character: Model): Model?
	local cos = getCosmeticsFolder(character)
	if cos then
		local hand = cos:FindFirstChild("HandSaber")
		if hand and hand:IsA("Model") then
			return hand
		end
		local alt = cos:FindFirstChild("Hand Saber")
		if alt and alt:IsA("Model") then
			return alt
		end
	end
	local any = character:FindFirstChild("HandSaber", true)
	if any and any:IsA("Model") then
		return any
	end
	any = character:FindFirstChild("Hand Saber", true)
	if any and any:IsA("Model") then
		return any
	end
	return nil
end

-- ----- HARD RESET on holster/unequip -----
local function hardReset(character: Model)
	-- stop animation & debounce
	AnimToggle.stopIgniteAnim(character)
	debouncing[character] = nil
	-- force OFF (this also drives Audio OFF via your BladeOn connection)
	if State.getBladeOn(character) then
		State.setBladeOn(character, false)
	end
	-- nuke any audio rig we attached
	local hand = attachedModel[character]
	if hand then
		Audio.stopForModel(hand) -- immediate silence
		Audio.destroyForModel(hand) -- drop connections/rig
		attachedModel[character] = nil
	end
	-- clear visuals
	Visuals.destroyBlade(character)
	-- reason bookkeeping
	State.setLastReason(character, "holster")
end

-- ----- audio wiring helpers -----
local function attachAudioIfPossible(character: Model)
	local folder = State.getFolder(character)
	local bladeOn = folder:FindFirstChild("BladeOn")
	if not (bladeOn and bladeOn:IsA("BoolValue")) then
		return
	end

	local hand = getHandSaber(character)
	if not hand then
		-- debug: no hand found
		print("[SaberBlade] attachAudioIfPossible: NO HandSaber for", character.Name)
		return
	end

	-- If it’s the same instance we already bound, nothing to do.
	if attachedModel[character] == hand then
		return
	end

	-- If we had a previous instance, kill its audio.
	local prev = attachedModel[character]
	if prev and prev ~= hand then
		print("[SaberBlade] Replacing old HandSaber instance for", character.Name)
		Audio.destroyForModel(prev)
	end

	attachedModel[character] = hand

	-- IMPORTANT: clear our pointer when THIS instance goes away
	hand.AncestryChanged:Connect(function(_, parent)
		if parent == nil and attachedModel[character] == hand then
			print("[SaberBlade] HandSaber removed; clearing pointer for", character.Name)
			attachedModel[character] = nil
		end
	end)

	print("[SaberBlade] Attaching audio to", hand:GetFullName(), "BladeOn=", bladeOn.Value)
	Audio.attachFromModel(hand, bladeOn)

	-- If saber was already ON, reassert once after a breath.
	if bladeOn.Value then
		task.delay(0.05, function()
			if hand.Parent then
				print("[SaberBlade] forceApply after attach for", character.Name)
				Audio.forceApply(hand, true)
			end
		end)
	end
end

local function destroyAudio(character: Model)
	local hand = attachedModel[character]
	if hand then
		Audio.destroyForModel(hand)
		attachedModel[character] = nil
	end
end

-- ----- BIND TOOL EQUIP/UNEQUIP (server-visible proxy for "pressed 1") -----
local function bindTool(tool: Tool, character: Model)
	tool.Equipped:Connect(function()
		debouncing[character] = nil
		State.setLastReason(character, "spawn") -- ✅ allowed; use as “equipped fresh”
		attachAudioIfPossible(character)
	end)

	tool.Unequipped:Connect(function()
		-- this fires when player holsters/puts away the current tool (pressing 1 / switching tools)
		hardReset(character)
	end)
end

local function hookTools(character: Model)
	-- bind current tools
	for _, ch in ipairs(character:GetChildren()) do
		if ch:IsA("Tool") then
			bindTool(ch, character)
		end
	end
	-- bind future tools
	character.ChildAdded:Connect(function(ch)
		if ch:IsA("Tool") then
			bindTool(ch, character)
		end
	end)
end

-- ----- remote toggle (ignite/retract) -----
Remotes.Ignite.OnServerEvent:Connect(function(player: Player)
	local char = player.Character
	if not (char and char.Parent) then
		return
	end
	if debouncing[char] then
		return
	end
	if not Visuals.isHandEquipped(char) then
		return
	end

	-- ensure audio is attached before first toggle
	if not attachedModel[char] then
		attachAudioIfPossible(char)
		task.wait(0.05)
	end

	debouncing[char] = true
	task.delay(1, function()
		if debouncing[char] then
			debouncing[char] = nil
		end
	end)

	local wantOn = not State.getBladeOn(char)
	AnimToggle.playIgniteAndToggle(char, wantOn) -- Audio reacts via BladeOn
end)

-- ----- character wiring -----
local function hookCosmetics(character: Model)
	local function bindFolder(f: Folder)
		f.ChildAdded:Connect(function(ch)
			if ch:IsA("Model") and (ch.Name == "HandSaber" or ch.Name == "Hand Saber") then
				print("[SaberBlade] ChildAdded HandSaber ->", ch:GetFullName())
				AnimToggle.stopIgniteAnim(character)
				debouncing[character] = nil
				State.setLastReason(character, "spawn")
				if State.getBladeOn(character) then
					State.setBladeOn(character, false)
				end
				task.defer(function()
					Visuals.apply(character)
					attachAudioIfPossible(character) -- <-- will attach + set ancestry clear
				end)
			end
		end)

		f.ChildRemoved:Connect(function(ch)
			if ch:IsA("Model") and (ch.Name == "HandSaber" or ch.Name == "Hand Saber") then
				print("[SaberBlade] ChildRemoved HandSaber ->", ch:GetFullName())
				AnimToggle.stopIgniteAnim(character)
				debouncing[character] = nil
				State.setLastReason(character, "holster")
				if State.getBladeOn(character) then
					State.setBladeOn(character, false)
				end
				-- Do NOT leave a stale pointer; Audio will also destroy internally
				if attachedModel[character] == ch then
					attachedModel[character] = nil
					print("[SaberBlade] cleared attachedModel pointer for", character.Name)
				end
				Audio.stopForModel(ch)
				Visuals.destroyBlade(character)
			end
		end)
	end

	local cos = getCosmeticsFolder(character)
	if cos then
		bindFolder(cos)
	else
		character.ChildAdded:Connect(function(ch)
			if ch:IsA("Folder") and (ch.Name == "cosmetics" or ch.Name == "Cosmetics") then
				bindFolder(ch)
				task.defer(function()
					attachAudioIfPossible(character)
				end)
			end
		end)
	end
end

local function onCharacterAdded(character: Model)
	State.setLastReason(character, "spawn")
	State.setBladeOn(character, false)

	local bladeOn = State.getFolder(character):WaitForChild("BladeOn") :: BoolValue
	bladeOn.Changed:Connect(function()
		Visuals.apply(character)
		if not attachedModel[character] then
			attachAudioIfPossible(character)
		end
	end)

	-- bind tool equip/unequip (this is your “1 key” reset)
	hookTools(character)

	-- cosmetics-aware hooks
	hookCosmetics(character)

	-- fallback: HandSaber directly under character
	character.ChildAdded:Connect(function(ch)
		if ch:IsA("Model") and (ch.Name == "HandSaber" or ch.Name == "Hand Saber") then
			AnimToggle.stopIgniteAnim(character)
			debouncing[character] = nil
			State.setLastReason(character, "spawn")
			if State.getBladeOn(character) then
				State.setBladeOn(character, false)
			end
			task.defer(function()
				Visuals.apply(character)
				attachAudioIfPossible(character)
			end)
		end
	end)
	character.ChildRemoved:Connect(function(ch)
		if ch:IsA("Model") and (ch.Name == "HandSaber" or ch.Name == "Hand Saber") then
			hardReset(character)
		end
	end)

	local hum = character:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.Died:Once(function()
			State.setLastReason(character, "death")
			if State.getBladeOn(character) then
				State.setBladeOn(character, false)
			end
			destroyAudio(character)
			Visuals.apply(character)
		end)
	end

	task.defer(function()
		Visuals.apply(character)
		attachAudioIfPossible(character)
	end)
end

Players.PlayerAdded:Connect(function(p)
	p.CharacterAdded:Connect(onCharacterAdded)
	if p.Character then
		onCharacterAdded(p.Character)
	end
end)
