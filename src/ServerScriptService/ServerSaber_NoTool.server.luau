-- ServerScriptService/SaberServer_NoTool.server.lua
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")

local MODEL_NAME: string = "Lightsaber" -- Model in ReplicatedStorage
local TOGGLE_EVENT = RS:WaitForChild("SaberToggle") :: RemoteEvent

-- Placement offsets (tweak to taste)
local HAND_OFFSET = CFrame.new(0, -0.2, 0) * CFrame.Angles(0, math.rad(90), math.rad(270)) -- in-hand orientation
local WAIST_OFFSET = CFrame.new(1, -0.5, -0.5) * CFrame.Angles(0, math.rad(90), math.rad(180))

-- Debouncers
local creatingHip = setmetatable({}, { __mode = "k" })
local creatingHand = setmetatable({}, { __mode = "k" })

-- ========== helpers ==========

local function weldUpModel(model: Model)
	local handleInst = model:FindFirstChild("Handle", true)
	assert(handleInst and handleInst:IsA("BasePart"), "Lightsaber model needs a BasePart named 'Handle'")
	local handle = handleInst :: BasePart
	model.PrimaryPart = handle

	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and d ~= handle then
			d.Anchored = false
			d.CanCollide = false
			d.Massless = true
			local w = Instance.new("WeldConstraint")
			w.Part0 = handle
			w.Part1 = d
			w.Parent = handle
		end
	end
	handle.Anchored = false
	handle.CanCollide = false
	handle.Massless = true
end

local function cloneSaber(): Model
	local srcInst = RS:FindFirstChild(MODEL_NAME)
	assert(srcInst and srcInst:IsA("Model"), ("Missing %s in ReplicatedStorage"):format(MODEL_NAME))
	local src = srcInst :: Model
	local m = src:Clone()
	weldUpModel(m)
	return m
end

local function getWaistBase(character: Model): BasePart?
	local part = character:FindFirstChild("LowerTorso")
		or character:FindFirstChild("Torso")
		or character:FindFirstChild("HumanoidRootPart")
	if part and part:IsA("BasePart") then
		return part
	end
	return nil
end

local function getHandBase(character: Model): BasePart?
	local part = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	if part and part:IsA("BasePart") then
		return part
	end
	return nil
end

-- ========== HIP HILT ==========

local function destroyHip(character: Model)
	local hip = character and character:FindFirstChild("HipHilt", true)
	if hip and hip:IsA("Model") then
		hip:Destroy()
	end
end

local function ensureHip(character: Model): Model?
	if not character or not character.Parent then
		return nil
	end

	local base = getWaistBase(character)
	if not base then
		return nil
	end

	do
		local existingInst = character:FindFirstChild("HipHilt", true)
		if existingInst and existingInst:IsA("Model") then
			local existing = existingInst :: Model
			local handle = existing.PrimaryPart
			if handle then
				local okWeld = handle:FindFirstChild("HipWeld")
				if okWeld and okWeld:IsA("Weld") then
					local w = okWeld :: Weld
					if w.Part0 == base then
						return existing
					end
				end
			end
			existing:Destroy()
		end
	end

	if creatingHip[character] then
		task.wait(0.1)
		local again = character:FindFirstChild("HipHilt", true)
		return (again and again:IsA("Model")) and (again :: Model) or nil
	end
	creatingHip[character] = true

	local ok, result = pcall(function(): Model
		local m = cloneSaber()
		m.Name = "HipHilt"
		-- hide blade on hip
		local bladeInst = m:FindFirstChild("Blade", true)
		if bladeInst and bladeInst:IsA("BasePart") then
			local blade = bladeInst :: BasePart
			blade.Transparency = 1
			blade.CanCollide = false
		end

		local cosmeticsInst = character:FindFirstChild("Cosmetics")
		local cosmetics: Folder
		if cosmeticsInst and cosmeticsInst:IsA("Folder") then
			cosmetics = cosmeticsInst
		else
			cosmetics = Instance.new("Folder")
			cosmetics.Name = "Cosmetics"
			cosmetics.Parent = character
		end

		m.Parent = cosmetics

		local handle = m.PrimaryPart
		assert(handle, "HipHilt clone missing PrimaryPart after weldUpModel")
		handle.CFrame = base.CFrame * WAIST_OFFSET

		local weld = Instance.new("Weld")
		weld.Name = "HipWeld"
		weld.Part0 = base
		weld.Part1 = handle
		weld.C0 = base.CFrame:ToObjectSpace(handle.CFrame)
		weld.C1 = CFrame.new()
		weld.Parent = handle
		return m
	end)

	creatingHip[character] = nil
	if ok then
		return result :: Model
	else
		warn("[Saber] ensureHip failed:", result)
		return nil
	end
end

-- ========== HAND SABER ==========

local function destroyHand(character: Model)
	local hand = character and character:FindFirstChild("HandSaber", true)
	if hand and hand:IsA("Model") then
		hand:Destroy()
	end
end

local function ensureHand(character: Model): Model?
	if not character or not character.Parent then
		return nil
	end

	local base = getHandBase(character)
	if not base then
		return nil
	end

	do
		local existingInst = character:FindFirstChild("HandSaber", true)
		if existingInst and existingInst:IsA("Model") then
			local existing = existingInst :: Model
			local handle = existing.PrimaryPart
			if handle then
				local okWeld = handle:FindFirstChild("HandWeld")
				if okWeld and okWeld:IsA("Weld") then
					local w = okWeld :: Weld
					if w.Part0 == base then
						return existing
					end
				end
			end
			existing:Destroy()
		end
	end

	if creatingHand[character] then
		task.wait(0.1)
		local again = character:FindFirstChild("HandSaber", true)
		return (again and again:IsA("Model")) and (again :: Model) or nil
	end
	creatingHand[character] = true

	local ok, result = pcall(function(): Model
		local m = cloneSaber()
		m.Name = "HandSaber"
		-- show blade in hand
		local bladeInst = m:FindFirstChild("Blade", true)
		if bladeInst and bladeInst:IsA("BasePart") then
			(bladeInst :: BasePart).Transparency = 0
		end

		m.Parent = character

		local handle = m.PrimaryPart
		assert(handle, "HandSaber clone missing PrimaryPart after weldUpModel")
		handle.CFrame = base.CFrame * HAND_OFFSET

		local weld = Instance.new("Weld")
		weld.Name = "HandWeld"
		weld.Part0 = base
		weld.Part1 = handle
		weld.C0 = base.CFrame:ToObjectSpace(handle.CFrame)
		weld.C1 = CFrame.new()
		weld.Parent = handle
		return m
	end)

	creatingHand[character] = nil
	if ok then
		return result :: Model
	else
		warn("[Saber] ensureHand failed:", result)
		return nil
	end
end

-- ========== state + toggle ==========

local function isEquipped(character: Model): boolean
	local inst = character:FindFirstChild("HandSaber", true)
	return inst ~= nil and inst:IsA("Model")
end

local function equip(character: Model)
	destroyHip(character)
	ensureHand(character)
end

local function unequip(character: Model)
	destroyHand(character)
	ensureHip(character)
end

local function toggle(player: Player)
	local char = player.Character
	if not char then
		return
	end
	if isEquipped(char) then
		unequip(char)
	else
		equip(char)
	end
end

-- ========== wiring ==========

TOGGLE_EVENT.OnServerEvent:Connect(toggle)

local function onCharacterAdded(character: Model)
	task.defer(function()
		-- start with a hip hilt
		destroyHand(character)
		ensureHip(character)

		-- clean up on death
		local hum = character:FindFirstChildOfClass("Humanoid")
		if hum then
			hum.Died:Once(function()
				destroyHand(character)
				destroyHip(character)
			end)
		end
	end)
end

Players.PlayerAdded:Connect(function(p: Player)
	p.CharacterAdded:Connect(onCharacterAdded)
	if p.Character then
		onCharacterAdded(p.Character)
	end
end)
