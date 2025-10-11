--!strict
-- ServerScriptService/Services/VFXService.luau
-- Saber-style beam VFX. Server-only. Trail handled by TrailVFXService.

local TweenService = game:GetService("TweenService")
local SSS = game:GetService("ServerScriptService")

-- === Path-agnostic resolver (under SSS/Services) ===
local ServicesRoot = SSS:WaitForChild("Services")

local function findModule(root: Instance, name: string): ModuleScript
	-- direct child first (supports Folder/init)
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
	-- recursive search
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
	error(("[VFXService] Dependency module '%s' not found under %s"):format(name, root:GetFullName()))
end

local function requireService(name: string): any
	return require(findModule(ServicesRoot, name))
end

-- Use resolver instead of a hard path:
local TrailVFXService: any = requireService("TrailVFXService")

export type Reason = "ignite" | "retract" | "holster" | "spawn" | "death"

-- ===== Config types (kept here; TrailVFXService just reads pieces) =====
export type BladeNames = {
	CoreName: string,
	GlowName: string,
	TipCoreName: string,
	TipGlowName: string,
	HandModelName: string,
	SocketName: string,
	TrailName: string?, -- optional
}

export type BladeTextures = {
	CoreTexture: string,
	GlowTexture: string,
	TextureMode: Enum.TextureMode?,
	TextureLength: number?,
	TextureSpeed: number?,
}

export type BladeAppearance = {
	CoreWidth: number,
	GlowWidth: number,
	CoreColor: Color3,
	GlowColor: Color3,
}

export type BladeGeometry = {
	BaseLength: number,
	CoreLenRatio: number,
	GlowLenRatio: number,
	Rot: CFrame,
	Sign: number,
	Segments: number,
}

export type Timings = {
	InitialLen: number?, -- default 0.05
	IgniteTime: number?, -- default 1.0
	RetractTime: number?, -- default 1.0
	IgniteEasingStyle: Enum.EasingStyle?, -- default Quad
	IgniteEasingDir: Enum.EasingDirection?, -- default Out
	RetractEasingStyle: Enum.EasingStyle?, -- default Quad
	RetractEasingDir: Enum.EasingDirection?, -- default In
	RetractAttrName: string?, -- default "SaberRetracting"

	-- Passed through to TrailVFXService (optional)
	TrailLifetime: number?, -- default 0.12
	TrailMinLength: number?, -- default 0.1
}

export type SetConfig = {
	Names: BladeNames,
	Textures: BladeTextures,
	Appearance: BladeAppearance,
	Geometry: BladeGeometry,
	Timings: Timings?,
}

-- Only the hooks this module actually uses.
export type StateHooks = {
	getBladeOn: ((character: Model) -> boolean)?,
	getLastReason: ((character: Model) -> Reason)?,
}

-- ===== Module =====
local VFXService = {}

local _registry: { [string]: SetConfig } = {}
local _hooks: StateHooks = {}

function VFXService.register(name: string, cfg: SetConfig)
	assert(name ~= "", "VFXService.register: name cannot be empty")
	_registry[name] = cfg
end

function VFXService.unregister(name: string)
	_registry[name] = nil
end

function VFXService.setStateHooks(h: StateHooks)
	_hooks = h or {}
end

local function _cfg(name: string): SetConfig
	local c = _registry[name]
	assert(c, `VFXService: unknown set '{name}'`)
	return c
end

-- ===== Helpers =====
local function _tipCFrame(geom: BladeGeometry, socket: Attachment, len: number): CFrame
	return socket.CFrame * geom.Rot * CFrame.new(0, 0, geom.Sign * len)
end

local function _getHand(names: BladeNames, character: Model): Model?
	local m = character:FindFirstChild(names.HandModelName, true)
	return (m and m:IsA("Model")) and m or nil
end

local function _getHandle(hand: Model): BasePart?
	local pp = hand.PrimaryPart
	if pp and pp:IsA("BasePart") then
		return pp
	end
	local h = hand:FindFirstChild("Handle", true)
	if h and h:IsA("BasePart") then
		return h
	end
	return nil
end

local function _ensureTipAttachmentNamed(handle: BasePart, socket: Attachment, tipName: string, cf: CFrame): Attachment
	local a = handle:FindFirstChild(tipName)
	if a and a:IsA("Attachment") then
		(a :: Attachment).CFrame = cf
		return a
	end
	local tip = Instance.new("Attachment")
	tip.Name = tipName
	tip.CFrame = cf
	tip.Parent = handle
	return tip
end

local function _ensureTexturedBeam(
	handle: BasePart,
	beamName: string,
	socket: Attachment,
	tip: Attachment,
	segments: number,
	width: number,
	color: Color3,
	textureId: string,
	textureMode: Enum.TextureMode,
	textureLength: number,
	textureSpeed: number
): Beam
	local existing = handle:FindFirstChild(beamName)
	local beam: Beam
	if existing and existing:IsA("Beam") then
		beam = existing
	else
		beam = Instance.new("Beam")
		beam.Name = beamName
		beam.Parent = handle
	end
	beam.Attachment0 = socket
	beam.Attachment1 = tip
	beam.FaceCamera = true
	beam.Segments = segments
	beam.Width0 = width
	beam.Width1 = width
	beam.Color = ColorSequence.new(color)
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.Texture = textureId
	beam.TextureMode = textureMode
	beam.TextureLength = textureLength
	beam.TextureSpeed = textureSpeed
	beam.Transparency = NumberSequence.new(0)
	beam.Enabled = true
	return beam
end

-- TweenInfo helpers
local function _igniteTweenInfo(t: Timings): TweenInfo
	return TweenInfo.new(
		t.IgniteTime or 1.0,
		t.IgniteEasingStyle or Enum.EasingStyle.Quad,
		t.IgniteEasingDir or Enum.EasingDirection.Out
	)
end

local function _retractTweenInfo(t: Timings): TweenInfo
	return TweenInfo.new(
		t.RetractTime or 1.0,
		t.RetractEasingStyle or Enum.EasingStyle.Quad,
		t.RetractEasingDir or Enum.EasingDirection.In
	)
end

-- ===== Public API =====

function VFXService.isHandEquipped(setName: string, character: Model): boolean
	local names = _cfg(setName).Names
	return _getHand(names, character) ~= nil
end

function VFXService.destroyBlade(setName: string, character: Model): boolean
	local names = _cfg(setName).Names
	local hand = _getHand(names, character)
	if not hand then
		return false
	end
	local handle = _getHandle(hand)
	if not handle then
		return false
	end

	local removed = false
	for _, obj in ipairs(handle:GetChildren()) do
		if obj:IsA("Beam") and (obj.Name == names.CoreName or obj.Name == names.GlowName) then
			removed = true
			obj:Destroy()
		elseif obj:IsA("Attachment") and (obj.Name == names.TipCoreName or obj.Name == names.TipGlowName) then
			obj:Destroy()
		elseif obj:IsA("Trail") and (obj.Name == (names.TrailName or "BladeTrail")) then
			obj:Destroy()
		end
	end

	-- Drop Trail binding (listener lives in TrailVFXService)
	TrailVFXService.drop(character)

	return removed
end

function VFXService.createBlade(setName: string, character: Model)
	local cfg = _cfg(setName)
	local names, tex, app, geom = cfg.Names, cfg.Textures, cfg.Appearance, cfg.Geometry
	local t: Timings = cfg.Timings or {}

	local hand = _getHand(names, character)
	if not hand then
		return
	end
	local handle = _getHandle(hand)
	if not handle then
		return
	end

	local sockInst = handle:FindFirstChild(names.SocketName)
	if not (sockInst and sockInst:IsA("Attachment")) then
		warn(("[VFXService:%s] Missing Attachment '%s' on Handle"):format(setName, names.SocketName))
		return
	end
	local socket = sockInst :: Attachment

	-- Decide tween based on last reason
	local lastReason: Reason? = _hooks.getLastReason and _hooks.getLastReason(character) or nil
	local doTween = (lastReason == "ignite")
	local initial = t.InitialLen or 0.05

	local coreLen = geom.BaseLength * geom.CoreLenRatio
	local glowLen = geom.BaseLength * geom.GlowLenRatio
	local startCore = doTween and initial or coreLen
	local startGlow = doTween and initial or glowLen

	local tipGlow = _ensureTipAttachmentNamed(handle, socket, names.TipGlowName, _tipCFrame(geom, socket, startGlow))
	local tipCore = _ensureTipAttachmentNamed(handle, socket, names.TipCoreName, _tipCFrame(geom, socket, startCore))

	-- pose
	tipGlow.CFrame = _tipCFrame(geom, socket, startGlow)
	tipCore.CFrame = _tipCFrame(geom, socket, startCore)

	-- beams
	local textureMode = tex.TextureMode or Enum.TextureMode.Stretch
	local textureLen = tex.TextureLength or 1
	local textureSpeed = tex.TextureSpeed or 0

	_ensureTexturedBeam(
		handle,
		names.GlowName,
		socket,
		tipGlow,
		geom.Segments,
		app.GlowWidth,
		app.GlowColor,
		tex.GlowTexture,
		textureMode,
		textureLen,
		textureSpeed
	)
	_ensureTexturedBeam(
		handle,
		names.CoreName,
		socket,
		tipCore,
		geom.Segments,
		app.CoreWidth,
		app.CoreColor,
		tex.CoreTexture,
		textureMode,
		textureLen,
		textureSpeed
	)

	-- trail (delegated)
	TrailVFXService.ensureAndBind(handle, socket, tipGlow, names, app, t, character)

	-- tween on ignite
	if doTween then
		local ti = _igniteTweenInfo(t)
		TweenService:Create(tipGlow, ti, { CFrame = _tipCFrame(geom, socket, glowLen) }):Play()
		TweenService:Create(tipCore, ti, { CFrame = _tipCFrame(geom, socket, coreLen) }):Play()
	end

	-- optional SFX
	local s = handle:FindFirstChild("IgniteSound")
	if s and s:IsA("Sound") then
		s:Play()
	end
end

function VFXService.retractBlade(setName: string, character: Model)
	local cfg = _cfg(setName)
	local names, geom = cfg.Names, cfg.Geometry
	local t: Timings = cfg.Timings or {}

	local hand = _getHand(names, character)
	if not hand then
		return
	end
	local handle = _getHandle(hand)
	if not handle then
		return
	end

	local retractAttr = t.RetractAttrName or "SaberRetracting"
	if handle:GetAttribute(retractAttr) then
		return
	end
	handle:SetAttribute(retractAttr, true)

	local sockInst = handle:FindFirstChild(names.SocketName)
	if not (sockInst and sockInst:IsA("Attachment")) then
		handle:SetAttribute(retractAttr, nil)
		VFXService.destroyBlade(setName, character)
		return
	end
	local socket = sockInst :: Attachment

	local tipGlowInst = handle:FindFirstChild(names.TipGlowName)
	local tipCoreInst = handle:FindFirstChild(names.TipCoreName)
	if not (tipGlowInst and tipCoreInst and tipGlowInst:IsA("Attachment") and tipCoreInst:IsA("Attachment")) then
		handle:SetAttribute(retractAttr, nil)
		VFXService.destroyBlade(setName, character)
		return
	end
	local tipGlow = tipGlowInst :: Attachment
	local tipCore = tipCoreInst :: Attachment

	-- best-effort SFX
	local s = handle:FindFirstChild("RetractSound")
	if s and s:IsA("Sound") then
		pcall(function()
			s:Play()
		end)
	end

	local targetCF = _tipCFrame(geom, socket, (t.InitialLen or 0.05))
	local target = { CFrame = targetCF }

	-- tweeninfo (guarded)
	local ti: TweenInfo
	do
		local ok, res = pcall(function()
			return _retractTweenInfo(t)
		end)
		if ok and typeof(res) == "TweenInfo" then
			ti = res
		else
			ti = TweenInfo.new(1.0, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		end
	end

	-- create tweens defensively
	local glowTween: Tween? = nil
	local coreTween: Tween? = nil

	do
		local result: any = nil
		local ok = pcall(function()
			result = TweenService:Create(tipGlow, ti, target)
		end)
		if ok and typeof(result) == "Instance" and (result :: Instance):IsA("Tween") then
			glowTween = result :: Tween
		end
	end
	do
		local result: any = nil
		local ok = pcall(function()
			result = TweenService:Create(tipCore, ti, target)
		end)
		if ok and typeof(result) == "Instance" and (result :: Instance):IsA("Tween") then
			coreTween = result :: Tween
		end
	end

	if not glowTween or not coreTween then
		pcall(function()
			tipGlow.CFrame = targetCF
		end)
		pcall(function()
			tipCore.CFrame = targetCF
		end)
		handle:SetAttribute(retractAttr, nil)
		VFXService.destroyBlade(setName, character)
		return
	end

	local done = 0
	local function onDone()
		done += 1
		if done >= 2 then
			handle:SetAttribute(retractAttr, nil)
			VFXService.destroyBlade(setName, character)
		end
	end

	pcall(function()
		glowTween.Completed:Connect(onDone)
	end)
	pcall(function()
		coreTween.Completed:Connect(onDone)
	end)
	pcall(function()
		glowTween:Play()
	end)
	pcall(function()
		coreTween:Play()
	end)
end

function VFXService.apply(setName: string, character: Model)
	local getOn = _hooks.getBladeOn
	local getReason = _hooks.getLastReason
	local on = (getOn and getOn(character)) or false
	local drawn = VFXService.isHandEquipped(setName, character)
	if on and drawn then
		VFXService.createBlade(setName, character)
	else
		if drawn and getReason and getReason(character) == "retract" then
			VFXService.retractBlade(setName, character)
		else
			VFXService.destroyBlade(setName, character)
		end
	end
end

function VFXService.setBaseLength(setName: string, len: number)
	local g = _cfg(setName).Geometry
	g.BaseLength = len
end

-- ===== Default registration (Saber) =====
VFXService.register("Saber", {
	Names = {
		CoreName = "BladeCore",
		GlowName = "BladeGlow",
		TipCoreName = "BladeTip_Core",
		TipGlowName = "BladeTip_Glow",
		HandModelName = "HandSaber",
		SocketName = "BladeSocket",
		TrailName = "BladeTrail",
	},
	Textures = {
		CoreTexture = "rbxassetid://139556283966041",
		GlowTexture = "rbxassetid://119832340638011",
		TextureMode = Enum.TextureMode.Stretch,
		TextureLength = 1,
		TextureSpeed = 0,
	},
	Appearance = {
		CoreWidth = 0.6,
		GlowWidth = 0.9,
		CoreColor = Color3.fromRGB(255, 255, 255),
		GlowColor = Color3.fromRGB(255, 0, 0),
	},
	Geometry = {
		BaseLength = 5,
		CoreLenRatio = 1.00,
		GlowLenRatio = 1.00,
		Rot = CFrame.Angles(0, 0, 0),
		Sign = -1,
		Segments = 32,
	},
	Timings = {
		InitialLen = 0.05,
		IgniteTime = 1.0,
		RetractTime = 1.0,
		IgniteEasingStyle = Enum.EasingStyle.Quad,
		IgniteEasingDir = Enum.EasingDirection.Out,
		RetractEasingStyle = Enum.EasingStyle.Quad,
		RetractEasingDir = Enum.EasingDirection.In,
		RetractAttrName = "SaberRetracting",
		TrailLifetime = 0.12,
		TrailMinLength = 0.1,
	},
})

return VFXService
