--!strict
-- Server-only Saber audio. No duplicates, no stale handles.
-- One-shots (ignite/disignite) play ONLY from a world anchor. Hum lives on Handle.
-- Exactly one BladeOn connection per HandSaber model. With debug prints.

local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

local IGNITE_ID = "rbxassetid://6815895620"
local HUM_ID = "rbxassetid://605578076"
local DISIGNITE_ID = "rbxassetid://1194453600"

-- ===== debug =====
local DEBUG = true
local function dprint(...: any)
	if DEBUG then
		print("[SaberAudio]", ...)
	end
end

type HandSaber = Model
type Rig = {
	model: HandSaber,
	handle: BasePart,
	ignite: Sound,
	hum: Sound,
	disignite: Sound,
	alive: boolean,
	applyToken: number,
}

local rigs: { [HandSaber]: Rig } = setmetatable({}, { __mode = "k" }) :: any
local changedConns: { [HandSaber]: RBXScriptConnection } = setmetatable({}, { __mode = "k" }) :: any

local function rigInfo(r: Rig): string
	local hp = r.handle.Parent
	local hup = r.hum.Parent
	local igp = r.ignite.Parent
	local dip = r.disignite.Parent
	return string.format(
		"modelParent=%s | handleParent=%s | humParent=%s | igniteParent=%s | disParent=%s | humPlaying=%s",
		tostring(r.model.Parent),
		tostring(hp),
		tostring(hup),
		tostring(igp),
		tostring(dip),
		tostring(r.hum.IsPlaying)
	)
end

-- ---------- build ----------
local function getHandle(m: HandSaber): BasePart
	local h = m:FindFirstChild("Handle")
	if h and h:IsA("BasePart") then
		return h
	end
	error("SaberAudio: HandSaber.Handle missing or not a BasePart")
end

local function ensureSounds(handle: BasePart): (Sound, Sound, Sound)
	local ignite: Sound? = handle:FindFirstChild("Ignite") :: Sound?
	if not ignite or not ignite:IsA("Sound") then
		local s = Instance.new("Sound")
		s.Name = "Ignite"
		s.Parent = handle
		ignite = s
	end
	local igniteSound: Sound = ignite :: Sound
	igniteSound.SoundId = IGNITE_ID
	igniteSound.Looped = false
	igniteSound.Volume = 1
	igniteSound.RollOffMode = Enum.RollOffMode.Inverse
	igniteSound.RollOffMaxDistance = 90

	local hum: Sound? = handle:FindFirstChild("Hum") :: Sound?
	if not hum or not hum:IsA("Sound") then
		local s = Instance.new("Sound")
		s.Name = "Hum"
		s.Parent = handle
		hum = s
	end
	local humSound: Sound = hum :: Sound
	humSound.SoundId = HUM_ID
	humSound.Looped = true
	humSound.Volume = 0.6
	humSound.RollOffMode = Enum.RollOffMode.Inverse
	humSound.RollOffMaxDistance = 90

	local dis: Sound? = handle:FindFirstChild("Disignite") :: Sound?
	if not dis or not dis:IsA("Sound") then
		local s = Instance.new("Sound")
		s.Name = "Disignite"
		s.Parent = handle
		dis = s
	end
	local disSound: Sound = dis :: Sound
	disSound.SoundId = DISIGNITE_ID
	disSound.Looped = false
	disSound.Volume = 1
	disSound.RollOffMode = Enum.RollOffMode.Inverse
	disSound.RollOffMaxDistance = 90

	return igniteSound, humSound, disSound
end

local function rigInvalid(r: Rig): boolean
	if r.handle.Parent == nil or not r.handle:IsDescendantOf(r.model) then
		return true
	end
	if r.ignite.Parent == nil or r.hum.Parent == nil or r.disignite.Parent == nil then
		return true
	end
	return false
end

local function ensureRig(model: HandSaber): Rig
	local rMaybe: Rig? = rigs[model]
	if rMaybe and rMaybe.model.Parent ~= nil and not rigInvalid(rMaybe) then
		return rMaybe
	end
	if rMaybe then
		dprint("ensureRig: rebuilding (stale rig) ->", rigInfo(rMaybe))
	end
	local handle = getHandle(model)
	local ignite, hum, dis = ensureSounds(handle)
	local newRig: Rig = {
		model = model,
		handle = handle,
		ignite = ignite,
		hum = hum,
		disignite = dis,
		alive = true,
		applyToken = if rMaybe then rMaybe.applyToken else 0,
	}
	rigs[model] = newRig
	dprint("ensureRig: built ->", rigInfo(newRig))
	return newRig
end

-- ---------- world-anchored one-shot ----------
local function playWorldOneShotFromTemplate(template: Sound, atCf: CFrame)
	local anchor = Instance.new("Part")
	anchor.Name = "SaberSFXAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.CFrame = atCf
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

-- ---------- playback (always fetch a fresh rig) ----------
local function igniteOnce(model: HandSaber)
	local r = ensureRig(model)
	dprint("igniteOnce ->", rigInfo(r))
	playWorldOneShotFromTemplate(r.ignite, r.handle.CFrame) -- only world clone (no doubles)
end

local function disigniteOnce(model: HandSaber)
	local r = ensureRig(model)
	if r.disignite.SoundId == "" then
		return
	end
	dprint("disigniteOnce ->", rigInfo(r))
	playWorldOneShotFromTemplate(r.disignite, r.handle.CFrame)
end

local function reassertHum(model: HandSaber, wantOn: boolean)
	local r = ensureRig(model)
	r.applyToken += 1
	local token = r.applyToken
	dprint("reassertHum(", wantOn, ") start ->", rigInfo(r))

	if wantOn then
		r.hum.Playing = true
		for _ = 1, 16 do
			if not r.alive or token ~= r.applyToken then
				dprint("reassertHum(cancelled) ->", rigInfo(r))
				return
			end
			if not r.hum.IsPlaying then
				r.hum:Play()
			end
			task.wait(0.1)
			if r.hum.IsPlaying then
				dprint("reassertHum(ON ok) ->", rigInfo(r))
				return
			end
		end
		dprint("reassertHum(ON timeout) ->", rigInfo(r))
	else
		r.hum.Playing = false
		for _ = 1, 4 do
			if not r.alive or token ~= r.applyToken then
				dprint("reassertHum(cancelled) ->", rigInfo(r))
				return
			end
			if r.hum.IsPlaying then
				r.hum:Stop()
			end
			task.wait(0.05)
		end
		dprint("reassertHum(OFF done) ->", rigInfo(r))
	end
end

-- ---------- public ----------
local Audio = {}

function Audio.attachFromModel(handSaber: HandSaber, bladeOn: BoolValue)
	local r0 = ensureRig(handSaber)
	r0.alive = true
	dprint("attachFromModel:", handSaber:GetFullName(), "BladeOn=", bladeOn.Value)

	-- keep only one Changed connection per model
	local old = changedConns[handSaber]
	if old then
		old:Disconnect()
		changedConns[handSaber] = nil
	end

	task.defer(function()
		if bladeOn.Value then
			reassertHum(handSaber, true) -- no ignite on attach
		else
			reassertHum(handSaber, false)
		end
	end)

	changedConns[handSaber] = bladeOn:GetPropertyChangedSignal("Value"):Connect(function()
		dprint("BladeOn changed ->", bladeOn.Value)
		if bladeOn.Value then
			igniteOnce(handSaber)
			reassertHum(handSaber, true)
		else
			reassertHum(handSaber, false)
			disigniteOnce(handSaber)
		end
	end)

	handSaber.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			dprint("AncestryChanged: model removed; destroying rig")
			Audio.destroyForModel(handSaber)
		end
	end)
end

function Audio.attach(handle: BasePart, bladeOn: BoolValue)
	local model = handle:FindFirstAncestorOfClass("Model")
	if not model then
		error("SaberAudio.attach: handle must be inside a Model")
	end
	Audio.attachFromModel(model :: HandSaber, bladeOn)
end

function Audio.forceApply(handSaber: HandSaber, isOn: boolean)
	ensureRig(handSaber)
	dprint("forceApply:", isOn)
	if isOn then
		reassertHum(handSaber, true)
	else
		reassertHum(handSaber, false)
	end
end

function Audio.stopForModel(handSaber: HandSaber)
	dprint("stopForModel")
	reassertHum(handSaber, false)
end

function Audio.destroyForModel(handSaber: HandSaber)
	local r = rigs[handSaber]
	if r then
		r.alive = false
	end
	local c = changedConns[handSaber]
	if c then
		c:Disconnect()
		changedConns[handSaber] = nil
	end
	if r then
		pcall(function()
			r.hum.Playing = false
			r.hum:Stop()
		end)
		dprint("destroyForModel ->", rigInfo(r))
	end
	rigs[handSaber] = nil
end

-- debug hooks
function Audio.debugSet(flag: boolean)
	DEBUG = flag
	dprint("DEBUG =", flag)
end

function Audio.debugDump(handSaber: HandSaber)
	local r = rigs[handSaber]
	if r then
		dprint("DUMP ->", rigInfo(r))
	else
		print("[SaberAudio] DUMP -> no rig for", handSaber)
	end
end

return Audio
