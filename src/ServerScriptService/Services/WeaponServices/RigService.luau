--!strict
local RS = game:GetService("ReplicatedStorage")

export type SetConfig = {
	ModelFolderName: string,
	ModelName: string,
	HandModelName: string,
	HipModelName: string,
	HandOffset: CFrame, -- ignored in this minimalist mode
	WaistOffset: CFrame,
}

local RigService = {}
local _reg: { [string]: SetConfig } = {}
local _creatingHip: { [Model]: { [string]: boolean } } = setmetatable({}, { __mode = "k" }) :: any
local _creatingHand: { [Model]: { [string]: boolean } } = setmetatable({}, { __mode = "k" }) :: any

-- persistent local grip offset applied on the HANDLE side
local GRIP_LOCAL: CFrame = CFrame.new(0, 0, 0.15) * CFrame.Angles(math.rad(90), 0, 0)

-- ===== internals =====
local function _cfg(name: string)
	local c = _reg[name]
	assert(c, `RigService: unknown set '{name}'`)
	return c
end

local function _resolveRSFolder(pathOrName: string): Folder
	local node: Instance = RS
	for seg in string.gmatch(pathOrName, "[^/]+") do
		local nxt = node:FindFirstChild(seg)
		assert(nxt, ("RigService: missing ReplicatedStorage/%s (stopped at '%s')"):format(pathOrName, seg))
		node = nxt :: Instance
	end
	assert(node:IsA("Folder"), ("RigService: expected Folder at ReplicatedStorage/%s"):format(pathOrName))
	return node :: Folder
end

local function _getCosmeticsFolder(character: Model): Folder
	local f = character:FindFirstChild("Cosmetics")
	if f and f:IsA("Folder") then
		return f
	end
	local nf = Instance.new("Folder")
	nf.Name = "Cosmetics"
	nf.Parent = character
	return nf
end

local function _ensureHandle(model: Model): BasePart
	-- Prefer explicitly named Handle.
	local hInst = model:FindFirstChild("Handle", true)
	if hInst and hInst:IsA("BasePart") then
		local h = hInst :: BasePart
		h.Name = "Handle"
		model.PrimaryPart = h
		return h
	end

	-- Use PrimaryPart if possible.
	if model.PrimaryPart and model.PrimaryPart:IsA("BasePart") then
		local h = model.PrimaryPart :: BasePart
		h.Name = "Handle"
		model.PrimaryPart = h
		return h
	end

	-- Fallback: largest BasePart.
	local best: BasePart? = nil
	local bestScore = -math.huge
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			local p = d :: BasePart
			local score = p.Size.X * p.Size.Y * p.Size.Z
			if score > bestScore then
				bestScore = score
				best = p
			end
		end
	end

	assert(best, "RigService: rig model needs at least one BasePart")
	local h = best :: BasePart
	h.Name = "Handle"
	model.PrimaryPart = h
	return h
end

local function _handBase(character: Model): BasePart?
	local part: Instance? = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	return (part and part:IsA("BasePart")) and part or nil
end

local function _waistBase(character: Model): BasePart?
	local part: Instance? = character:FindFirstChild("LowerTorso")
		or character:FindFirstChild("Torso")
		or character:FindFirstChild("HumanoidRootPart")
	return (part and part:IsA("BasePart")) and part or nil
end

-- sockets
local function _ensureBladeSocket(handle: BasePart): Attachment
	local SOCKET_CF = CFrame.new(0, 0.2, 0) * CFrame.Angles(math.rad(90), 0, 0)
	local a = handle:FindFirstChild("BladeSocket")
	if a and a:IsA("Attachment") then
		(a :: Attachment).CFrame = SOCKET_CF
		return a :: Attachment
	end
	local att = Instance.new("Attachment")
	att.Name = "BladeSocket"
	att.CFrame = SOCKET_CF
	att.Parent = handle
	return att
end

-- OneSith weld (no extra rotation; it inherits the handle’s 90° now)
local function _findOneSithGeometry(model: Model): BasePart?
	local inst = model:FindFirstChild("OneSith", true)
	if inst then
		if inst:IsA("BasePart") then
			return inst
		end
		if (inst:IsA("SpecialMesh") or inst:IsA("DataModelMesh")) and inst.Parent and inst.Parent:IsA("BasePart") then
			return inst.Parent :: BasePart
		end
	end
	local hilt = model:FindFirstChild("Hilt", true)
	if hilt then
		for _, d in ipairs(hilt:GetDescendants()) do
			if
				(d:IsA("SpecialMesh") or d:IsA("DataModelMesh"))
				and d.Name == "OneSith"
				and d.Parent
				and d.Parent:IsA("BasePart")
			then
				return d.Parent :: BasePart
			elseif d:IsA("BasePart") and d.Name == "OneSith" then
				return d
			end
		end
	end
	return nil
end

local function _mountHiltGeometry(model: Model, handle: BasePart)
	local geom = _findOneSithGeometry(model)
	if not geom or geom == handle then
		return
	end
	geom.Anchored, geom.CanCollide, geom.Massless = false, false, true
	geom.Parent = handle
	geom.CFrame = handle.CFrame -- inherit handle’s 90°; no extra spin
	for _, ch in ipairs(handle:GetChildren()) do
		if ch:IsA("WeldConstraint") then
			local wc = ch :: WeldConstraint
			if (wc.Part0 == handle and wc.Part1 == geom) or (wc.Part1 == handle and wc.Part0 == geom) then
				return
			end
		end
	end
	local weld = Instance.new("WeldConstraint")
	weld.Name = "OneSithWeld"
	weld.Part0, weld.Part1, weld.Parent = handle, geom, handle
end

local function _weldUpModel(model: Model)
	local handle = _ensureHandle(model)
	model.PrimaryPart = handle
	handle.Name = "Handle"
	handle.Anchored, handle.CanCollide, handle.Massless = false, false, true
	_mountHiltGeometry(model, handle)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			local bp = d :: BasePart
			if bp ~= handle then
				bp.Anchored, bp.CanCollide, bp.Massless = false, false, true
				local already = false
				for _, ch in ipairs(handle:GetChildren()) do
					if ch:IsA("WeldConstraint") then
						local wc = ch :: WeldConstraint
						if wc.Part0 == bp or wc.Part1 == bp then
							already = true
							break
						end
					end
				end
				if not already then
					local wc = Instance.new("WeldConstraint")
					wc.Part0, wc.Part1, wc.Parent = handle, bp, handle
				end
			end
		end
	end
end

local function _pickSourceModel(folder: Folder, desiredName: string): Model
	local exact = folder:FindFirstChild(desiredName)
	if exact and exact:IsA("Model") then
		return exact :: Model
	end
	local lower = string.lower(desiredName)
	for _, ch in ipairs(folder:GetChildren()) do
		if ch:IsA("Model") and string.lower(ch.Name) == lower then
			return ch
		end
	end
	for _, ch in ipairs(folder:GetChildren()) do
		if ch:IsA("Model") then
			return ch
		end
	end
	error(("RigService: no model found in %s (wanted '%s')"):format(folder:GetFullName(), desiredName))
end

local function _tag(model: Model, c: SetConfig)
	model:SetAttribute("__RigService", true)
	model:SetAttribute("SourceFolder", c.ModelFolderName)
	model:SetAttribute("SourceModel", c.ModelName)
end

local function _cloneModel(c: SetConfig): Model
	local folder = _resolveRSFolder(c.ModelFolderName)
	local src = _pickSourceModel(folder, c.ModelName)
	local m = (src :: Model):Clone()
	m.Name = c.ModelName
	_weldUpModel(m)
	_tag(m, c)
	return m
end

-- ===== joints (minimalist grip with persistent offset) =====
local function _removeHandJoint(hand: BasePart)
	for _, ch in ipairs(hand:GetChildren()) do
		if ch:IsA("Motor6D") and (ch.Name == "RightGrip" or ch.Name == "SaberGrip") then
			ch:Destroy()
		end
		if ch:IsA("Weld") and ch.Name == "HandWeld" then
			ch:Destroy()
		end
	end
end

-- C0 = identity (RightHand), C1 = GRIP_LOCAL (Handle). Snap first to avoid popping.
local function _addGripWithOffset(hand: BasePart, handle: BasePart)
	_removeHandJoint(hand)

	pcall(function()
		handle.AssemblyLinearVelocity = Vector3.zero
		handle.AssemblyAngularVelocity = Vector3.zero
	end)

	-- Snap handle to the target pose relative to the hand
	handle.CFrame = hand.CFrame * GRIP_LOCAL

	-- Ensure VFX socket
	_ensureBladeSocket(handle)

	local m = Instance.new("Motor6D")
	m.Name = "RightGrip"
	m.Part0 = hand
	m.Part1 = handle
	m.C0 = CFrame.new() -- RightHand space
	m.C1 = GRIP_LOCAL -- Handle’s local offset (persists across animation/physics)
	m.Parent = hand
end

local function _purgeRogues(character: Model, c: SetConfig, keep: Model?)
	local cos = _getCosmeticsFolder(character)
	for _, ch in ipairs(cos:GetChildren()) do
		if ch:IsA("BasePart") then
			ch:Destroy()
		elseif ch:IsA("Model") and (ch.Name == c.HandModelName or ch.Name == c.HipModelName) then
			if keep and ch == keep then
				continue
			end
			if ch:GetAttribute("__RigService") ~= true then
				ch:Destroy()
			end
		end
	end
end

-- ===== public api =====
function RigService.register(name: string, cfg: SetConfig)
	_reg[name] = cfg
end
function RigService.unregister(name: string)
	_reg[name] = nil
end

function RigService.isEquipped(name: string, character: Model): boolean
	local c = _cfg(name)
	local inst = character:FindFirstChild(c.HandModelName, true)
	if not (inst and inst:IsA("Model")) then
		return false
	end
	local base = _handBase(character)
	if not base then
		return false
	end
	local handle = (inst :: Model).PrimaryPart
	for _, ch in ipairs(base:GetChildren()) do
		if ch:IsA("Motor6D") and (ch.Name == "RightGrip" or ch.Name == "SaberGrip") then
			if ch.Part1 == handle then
				return true
			end
		elseif ch:IsA("Weld") and ch.Name == "HandWeld" then
			if (ch :: Weld).Part0 == base and (ch :: Weld).Part1 == handle then
				return true
			end
		end
	end
	return false
end

function RigService.destroyHip(name: string, character: Model)
	local c = _cfg(name)
	local hip = character:FindFirstChild(c.HipModelName, true)
	if hip and hip:IsA("Model") then
		hip:Destroy()
	end
end

function RigService.ensureHip(name: string, character: Model): Model?
	local c = _cfg(name)
	if not (character and character.Parent) then
		return nil
	end
	local base = _waistBase(character)
	if not base then
		return nil
	end

	local existing = character:FindFirstChild(c.HipModelName, true)
	if existing and existing:IsA("Model") then
		local handle = (existing :: Model).PrimaryPart
		local okW = handle and handle:FindFirstChild("HipWeld")
		if okW and okW:IsA("Weld") and (okW :: Weld).Part0 == base then
			_purgeRogues(character, c, existing)
			return existing
		end
		existing:Destroy()
	end

	_creatingHip[character] = _creatingHip[character] or {}
	if _creatingHip[character][name] then
		return nil
	end
	_creatingHip[character][name] = true

	local m = _cloneModel(c)
	m.Name = c.HipModelName
	m.Parent = _getCosmeticsFolder(character)

	-- hide blade on hip
	local blade = m:FindFirstChild("Blade", true)
	if blade and blade:IsA("BasePart") then
		blade.Transparency, blade.CanCollide = 1, false
	end

	local h = m.PrimaryPart :: BasePart
	h.Anchored = false
	local weld = Instance.new("Weld")
	weld.Name = "HipWeld"
	weld.Part0, weld.Part1 = base, h
	weld.C0, weld.C1 = base.CFrame:ToObjectSpace((base.CFrame * c.WaistOffset)), CFrame.new()
	weld.Parent = h

	_creatingHip[character][name] = nil
	_purgeRogues(character, c, m)
	return m
end

function RigService.destroyHand(name: string, character: Model)
	local c = _cfg(name)
	local hand = character:FindFirstChild(c.HandModelName, true)
	local base = _handBase(character)
	if base then
		_removeHandJoint(base)
	end
	if hand and hand:IsA("Model") then
		hand:Destroy()
	end
end

function RigService.ensureHand(name: string, character: Model): Model?
	local c = _cfg(name)
	if not (character and character.Parent) then
		return nil
	end
	local base = _handBase(character)
	if not base then
		return nil
	end

	local existing = character:FindFirstChild(c.HandModelName, true)
	if existing and existing:IsA("Model") then
		local handleAny = (existing :: Model).PrimaryPart
		local handleBP = handleAny and handleAny:IsA("BasePart") and (handleAny :: BasePart) or nil
		for _, ch in ipairs(base:GetChildren()) do
			if
				ch:IsA("Motor6D")
				and (ch.Name == "RightGrip" or ch.Name == "SaberGrip")
				and handleBP
				and ch.Part1 == handleBP
			then
				ch:Destroy()
				handleBP.CFrame = base.CFrame * GRIP_LOCAL
				_ensureBladeSocket(handleBP)
				_addGripWithOffset(base, handleBP)
				_purgeRogues(character, c, existing)
				return existing
			end
			if ch:IsA("Weld") and ch.Name == "HandWeld" and handleAny and (ch :: Weld).Part1 == handleAny then
				ch:Destroy()
			end
		end
		existing:Destroy()
	end

	_creatingHand[character] = _creatingHand[character] or {}
	if _creatingHand[character][name] then
		return nil
	end
	_creatingHand[character][name] = true

	local m = _cloneModel(c)
	m.Name = c.HandModelName
	m.Parent = _getCosmeticsFolder(character)

	-- show blade in hand (if present)
	local blade2 = m:FindFirstChild("Blade", true)
	if blade2 and blade2:IsA("BasePart") then
		blade2.Transparency, blade2.CanCollide = 0, false
	end

	local h = m.PrimaryPart :: BasePart
	h.Anchored, h.CanCollide, h.Massless = false, false, true

	h.CFrame = base.CFrame * GRIP_LOCAL
	_ensureBladeSocket(h)
	_addGripWithOffset(base, h)

	_creatingHand[character][name] = nil
	_purgeRogues(character, c, m)
	return m
end

function RigService.spawnHolstered(name: string, character: Model): Model?
	RigService.destroyHand(name, character)
	return RigService.ensureHip(name, character)
end
function RigService.attachToCharacter(name: string, character: Model): Model?
	RigService.destroyHip(name, character)
	return RigService.ensureHand(name, character)
end
function RigService.detachFromCharacter(name: string, character: Model)
	RigService.destroyHand(name, character)
	RigService.ensureHip(name, character)
end
function RigService.setEquipped(name: string, character: Model, equipped: boolean): Model?
	if equipped then
		RigService.destroyHip(name, character)
		return RigService.ensureHand(name, character)
	else
		RigService.destroyHand(name, character)
		return RigService.ensureHip(name, character)
	end
end

-- ===== default registration =====
RigService.register("Saber", {
	ModelFolderName = "Assets/SaberModels",
	ModelName = "Lightsaber",
	HandModelName = "HandSaber",
	HipModelName = "HipHilt",
	HandOffset = CFrame.new(), -- ignored
	WaistOffset = CFrame.new(-1, -0.5, -0.5) * CFrame.Angles(0, math.rad(90), math.rad(180)),
})

return RigService
