--!strict
local RS = game:GetService("ReplicatedStorage")

local Rig = {}

-- Concurrency guards (weak keys)
local creatingHip: { [Model]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local creatingHand: { [Model]: boolean } = setmetatable({}, { __mode = "k" }) :: any

-- === config ===
local MODEL_FOLDER_NAME = "SaberModels"
local MODEL_NAME = "Lightsaber"

local HAND_OFFSET = CFrame.new(0, -0.2, 0) * CFrame.Angles(0, math.rad(90), math.rad(270))
local WAIST_OFFSET = CFrame.new(-1, -0.5, -0.5) * CFrame.Angles(0, math.rad(90), math.rad(180))

-- internals ---------------------------------------------------------

local function getCosmeticsFolder(character: Model): Folder
	local f = character:FindFirstChild("Cosmetics")
	if f and f:IsA("Folder") then
		return f
	end
	local nf = Instance.new("Folder")
	nf.Name = "Cosmetics"
	nf.Parent = character
	return nf
end

local function weldUpModel(model: Model)
	local handleInst = model:FindFirstChild("Handle", true)
	assert(handleInst and handleInst:IsA("BasePart"), "Lightsaber model needs a BasePart named 'Handle'")
	local handle = handleInst :: BasePart
	model.PrimaryPart = handle
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and d ~= handle then
			d.Anchored, d.CanCollide, d.Massless = false, false, true
			local wc = Instance.new("WeldConstraint")
			wc.Part0, wc.Part1, wc.Parent = handle, d, handle
		end
	end
	handle.Anchored, handle.CanCollide, handle.Massless = false, false, true
end

local function cloneSaber(): Model
	local modelsFolder = RS:WaitForChild(MODEL_FOLDER_NAME) :: Folder
	local src = modelsFolder:FindFirstChild(MODEL_NAME)
	assert(src and src:IsA("Model"), ("Missing %s in ReplicatedStorage/%s"):format(MODEL_NAME, MODEL_FOLDER_NAME))
	local m = (src :: Model):Clone()
	weldUpModel(m)
	return m
end

local function getWaistBase(character: Model): BasePart?
	local part: Instance? = character:FindFirstChild("LowerTorso")
		or character:FindFirstChild("Torso")
		or character:FindFirstChild("HumanoidRootPart")
	return (part and part:IsA("BasePart")) and part or nil
end

local function getHandBase(character: Model): BasePart?
	local part: Instance? = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	return (part and part:IsA("BasePart")) and part or nil
end

-- public API --------------------------------------------------------

function Rig.isEquipped(character: Model): boolean
	local inst = character:FindFirstChild("HandSaber", true)
	return inst ~= nil and inst:IsA("Model")
end

function Rig.destroyHip(character: Model)
	local hip = character:FindFirstChild("HipHilt", true)
	if hip and hip:IsA("Model") then
		hip:Destroy()
	end
end

function Rig.ensureHip(character: Model): Model?
	if not (character and character.Parent) then
		return nil
	end
	local base = getWaistBase(character)
	if not base then
		return nil
	end

	-- reuse only if welded to THIS base with a proper Weld
	local existingInst = character:FindFirstChild("HipHilt", true)
	if existingInst and existingInst:IsA("Model") then
		local existing = existingInst :: Model
		local handle = existing.PrimaryPart
		if handle and handle:IsA("BasePart") then
			local okW = handle:FindFirstChild("HipWeld")
			if okW and okW:IsA("Weld") then
				local w = okW :: Weld
				if w.Part0 == base then
					return existing
				end
			end
		end
		existing:Destroy()
	end

	if creatingHip[character] then
		return nil
	end
	creatingHip[character] = true

	local m = cloneSaber()
	m.Name = "HipHilt"

	-- hide blade on hip
	local blade = m:FindFirstChild("Blade", true)
	if blade and blade:IsA("BasePart") then
		blade.Transparency, blade.CanCollide = 1, false
	end

	m.Parent = getCosmeticsFolder(character)

	local handle = m.PrimaryPart
	if handle and handle:IsA("BasePart") then
		local h = handle :: BasePart
		h.CFrame = base.CFrame * WAIST_OFFSET

		local weld = Instance.new("Weld")
		weld.Name = "HipWeld"
		weld.Part0 = base
		weld.Part1 = h
		weld.C0 = base.CFrame:ToObjectSpace(h.CFrame)
		weld.C1 = CFrame.new()
		weld.Parent = h
	end

	creatingHip[character] = nil
	return m
end

function Rig.destroyHand(character: Model)
	local hand = character:FindFirstChild("HandSaber", true)
	if hand and hand:IsA("Model") then
		hand:Destroy()
	end
end

function Rig.ensureHand(character: Model): Model?
	if not (character and character.Parent) then
		return nil
	end
	local base = getHandBase(character)
	if not base then
		return nil
	end

	-- reuse only if welded to THIS base with a proper Weld
	local existingInst = character:FindFirstChild("HandSaber", true)
	if existingInst and existingInst:IsA("Model") then
		local existing = existingInst :: Model
		local handle = existing.PrimaryPart
		if handle and handle:IsA("BasePart") then
			local okW = handle:FindFirstChild("HandWeld")
			if okW and okW:IsA("Weld") then
				local w = okW :: Weld
				if w.Part0 == base then
					return existing
				end
			end
		end
		existing:Destroy()
	end

	if creatingHand[character] then
		return nil
	end
	creatingHand[character] = true

	local m = cloneSaber()
	m.Name = "HandSaber"

	-- blade visible in hand
	local blade = m:FindFirstChild("Blade", true)
	if blade and blade:IsA("BasePart") then
		blade.Transparency = 0
	end

	m.Parent = getCosmeticsFolder(character)

	local handle = m.PrimaryPart
	if handle and handle:IsA("BasePart") then
		local h = handle :: BasePart
		h.CFrame = base.CFrame * HAND_OFFSET

		local weld = Instance.new("Weld")
		weld.Name = "HandWeld"
		weld.Part0 = base
		weld.Part1 = h
		weld.C0 = HAND_OFFSET
		weld.C1 = CFrame.new()
		weld.Parent = h
	end

	creatingHand[character] = nil
	return m
end

function Rig.spawnHolstered(character: Model): Model?
	Rig.destroyHand(character)
	return Rig.ensureHip(character)
end

return Rig
