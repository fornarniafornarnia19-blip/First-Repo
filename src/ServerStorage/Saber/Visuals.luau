--!strict
type Reason = "ignite" | "retract" | "holster" | "spawn" | "death"

local State = require(script.Parent:WaitForChild("State"))
local TweenService = game:GetService("TweenService")

-- ===== Blade config =====
local B = {
	CoreName = "BladeCore",
	GlowName = "BladeGlow",
	TipCoreName = "BladeTip_Core",
	TipGlowName = "BladeTip_Glow",

	CoreTexture = "rbxassetid://93189077780707",
	GlowTexture = "rbxassetid://93189077780707",
	TextureMode = Enum.TextureMode.Stretch,
	TextureLength = 1,
	TextureSpeed = 0,

	CoreWidth = 0.4,
	GlowWidth = 1.2,
	CoreColor = Color3.fromRGB(255, 255, 255),
	GlowColor = Color3.fromRGB(255, 0, 0),

	BaseLength = 5.5,
	CoreLenRatio = 0.95,
	GlowLenRatio = 1.00,
	CoreLength = 0, -- derived below
	GlowLength = 0, -- derived below

	Rot = CFrame.Angles(0, 0, 0),
	Sign = -1,
	Segments = 32,

	HandModelName = "HandSaber",
	SocketName = "BladeSocket",
}
B.CoreLength = B.BaseLength * B.CoreLenRatio
B.GlowLength = B.BaseLength * B.GlowLenRatio
-- =================================

-- Visual-only tween params
local INITIAL_LEN = 0.05 -- small non-zero to avoid degenerate 0-length beam

local IGNITE_TIME = 1.0
local IGNITE_TWEEN = TweenInfo.new(IGNITE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local RETRACT_TIME = 1.0
local RETRACT_TWEEN = TweenInfo.new(RETRACT_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local RETRACT_ATTR = "SaberRetracting" -- guard against duplicate starts

local function tipCFrame(socket: Attachment, len: number): CFrame
	return socket.CFrame * B.Rot * CFrame.new(0, 0, B.Sign * len)
end

-- Hand / handle helpers
local function getHand(character: Model): Model?
	local m = character:FindFirstChild(B.HandModelName, true)
	return (m and m:IsA("Model")) and m or nil
end

local function getHandle(hand: Model): BasePart?
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

local Visuals = {}

function Visuals.isHandEquipped(character: Model): boolean
	return getHand(character) ~= nil
end

local function ensureTipAttachmentNamed(
	handle: BasePart,
	socket: Attachment,
	tipName: string,
	length: number
): Attachment
	local a = handle:FindFirstChild(tipName)
	if a and a:IsA("Attachment") then
		return a
	end
	local tip = Instance.new("Attachment")
	tip.Name = tipName
	tip.CFrame = tipCFrame(socket, length)
	tip.Parent = handle
	return tip
end

local function ensureTexturedBeam(
	handle: BasePart,
	name: string,
	socket: Attachment,
	tip: Attachment,
	width: number,
	color: Color3,
	textureId: string
): Beam
	local existing = handle:FindFirstChild(name)
	local beam: Beam
	if existing and existing:IsA("Beam") then
		beam = existing
	else
		beam = Instance.new("Beam")
		beam.Name = name
		beam.Parent = handle
	end
	beam.Attachment0 = socket
	beam.Attachment1 = tip
	beam.FaceCamera = true
	beam.Segments = B.Segments
	beam.Width0 = width
	beam.Width1 = width
	beam.Color = ColorSequence.new(color)
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.Texture = textureId
	beam.TextureMode = B.TextureMode
	beam.TextureLength = B.TextureLength
	beam.TextureSpeed = B.TextureSpeed
	beam.Transparency = NumberSequence.new(0) -- PNG alpha does the shaping
	beam.Enabled = true
	return beam
end

function Visuals.destroyBlade(character: Model): boolean
	local hand = getHand(character)
	if not hand then
		return false
	end
	local handle = getHandle(hand)
	if not handle then
		return false
	end

	local removed = false
	for _, obj in ipairs(handle:GetChildren()) do
		if obj:IsA("Beam") and (obj.Name == B.CoreName or obj.Name == B.GlowName) then
			removed = true
			obj:Destroy()
		elseif obj:IsA("Attachment") and (obj.Name == B.TipCoreName or obj.Name == B.TipGlowName) then
			obj:Destroy()
		end
	end
	return removed
end

function Visuals.createBlade(character: Model)
	local hand = getHand(character)
	if not hand then
		return
	end
	local handle = getHandle(hand)
	if not handle then
		return
	end

	local sock = handle:FindFirstChild(B.SocketName)
	if not (sock and sock:IsA("Attachment")) then
		warn("[Saber/Visuals] Missing Attachment '" .. B.SocketName .. "' on Handle")
		return
	end
	local socket = sock :: Attachment

	local reason = State.getLastReason(character)
	local doTween = (reason == "ignite")

	local startGlow = doTween and INITIAL_LEN or B.GlowLength
	local startCore = doTween and INITIAL_LEN or B.CoreLength

	local tipGlow = ensureTipAttachmentNamed(handle, socket, B.TipGlowName, startGlow)
	local tipCore = ensureTipAttachmentNamed(handle, socket, B.TipCoreName, startCore)

	-- force current pose (covers reused attachments)
	tipGlow.CFrame = tipCFrame(socket, startGlow)
	tipCore.CFrame = tipCFrame(socket, startCore)

	ensureTexturedBeam(handle, B.GlowName, socket, tipGlow, B.GlowWidth, B.GlowColor, B.GlowTexture)
	ensureTexturedBeam(handle, B.CoreName, socket, tipCore, B.CoreWidth, B.CoreColor, B.CoreTexture)

	if doTween then
		TweenService:Create(tipGlow, IGNITE_TWEEN, { CFrame = tipCFrame(socket, B.GlowLength) }):Play()
		TweenService:Create(tipCore, IGNITE_TWEEN, { CFrame = tipCFrame(socket, B.CoreLength) }):Play()
	end

	local s = handle:FindFirstChild("IgniteSound")
	if s and s:IsA("Sound") then
		s:Play()
	end
end

function Visuals.retractBlade(character: Model)
	local hand = getHand(character)
	if not hand then
		return
	end
	local handle = getHandle(hand)
	if not handle then
		return
	end

	-- prevent duplicate tweens if apply() fires multiple times
	if handle:GetAttribute(RETRACT_ATTR) then
		return
	end
	handle:SetAttribute(RETRACT_ATTR, true)

	local sock = handle:FindFirstChild(B.SocketName)
	if not (sock and sock:IsA("Attachment")) then
		handle:SetAttribute(RETRACT_ATTR, nil)
		Visuals.destroyBlade(character)
		return
	end
	local socket = sock :: Attachment

	-- find existing tips; if missing, nothing to tween -> just nuke
	local tipGlowInst = handle:FindFirstChild(B.TipGlowName)
	local tipCoreInst = handle:FindFirstChild(B.TipCoreName)
	if not (tipGlowInst and tipCoreInst and tipGlowInst:IsA("Attachment") and tipCoreInst:IsA("Attachment")) then
		handle:SetAttribute(RETRACT_ATTR, nil)
		Visuals.destroyBlade(character)
		return
	end
	local tipGlow = tipGlowInst :: Attachment
	local tipCore = tipCoreInst :: Attachment

	-- SFX only for true retracts
	local s = handle:FindFirstChild("RetractSound")
	if s and s:IsA("Sound") then
		s:Play()
	end

	local target = { CFrame = tipCFrame(socket, INITIAL_LEN) }
	local done = 0
	local function onDone()
		done += 1
		if done >= 2 then
			handle:SetAttribute(RETRACT_ATTR, nil)
			Visuals.destroyBlade(character)
		end
	end

	local glowTween = TweenService:Create(tipGlow, RETRACT_TWEEN, target)
	local coreTween = TweenService:Create(tipCore, RETRACT_TWEEN, target)
	glowTween.Completed:Connect(onDone)
	coreTween.Completed:Connect(onDone)
	glowTween:Play()
	coreTween:Play()
end

function Visuals.apply(character: Model)
	local on = State.getBladeOn(character)
	local drawn = Visuals.isHandEquipped(character)

	if on and drawn then
		Visuals.createBlade(character)
	else
		-- Tween retract only when the *reason* is 'retract'
		if drawn and State.getLastReason(character) == "retract" then
			Visuals.retractBlade(character)
		else
			-- spawn/holster/death or not drawn: instant cleanup, no SFX
			Visuals.destroyBlade(character)
		end
	end
end

-- Optional: tweak base length at runtime
function Visuals.setBaseLength(len: number)
	B.BaseLength = len
	B.CoreLength = len * B.CoreLenRatio
	B.GlowLength = len * B.GlowLenRatio
end

return Visuals
