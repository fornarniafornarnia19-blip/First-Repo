--!strict
-- ServerScriptService/Services/AudioService.luau

local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local ContentProvider = game:GetService("ContentProvider")

-- ========= Types =========
export type SoundIds = { Ignite: string, Hum: string, Disignite: string }
export type SoundVolumes = { Ignite: number?, Hum: number?, Disignite: number? }
export type Rolloff = { Mode: Enum.RollOffMode?, MaxDistance: number? }
export type SetConfig = { Ids: SoundIds, Volumes: SoundVolumes?, Rolloff: Rolloff?, Preload: boolean? }

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
type Registry = { [string]: SetConfig }

-- ========= Module =========
local AudioService = {}

-- Registry by set name
local _reg: Registry = {}
-- Weak per-model rig table, nested by set (values are optional until initialized)
local _rigs: { [HandSaber]: { [string]: Rig }? } = setmetatable({}, { __mode = "k" }) :: any
-- Weak per-model connection table, nested by set (values are optional until initialized)
local _changedConns: { [HandSaber]: { [string]: RBXScriptConnection }? } = setmetatable({}, { __mode = "k" }) :: any

-- ========= Internals =========
local function _assertSet(name: string): SetConfig
	local cfg = _reg[name]
	assert(cfg, `AudioService: unknown set '{name}'`)
	return cfg
end

-- Return BasePart? and NEVER error — callers must guard nil.
local function _getHandle(m: HandSaber): BasePart?
	-- 1) direct child named Handle
	local h = m:FindFirstChild("Handle")
	if h and h:IsA("BasePart") then
		return h
	end
	-- 2) anywhere in descendants
	local deep = m:FindFirstChild("Handle", true)
	if deep and deep:IsA("BasePart") then
		return deep
	end
	-- 3) PrimaryPart fallback
	if m.PrimaryPart and m.PrimaryPart:IsA("BasePart") then
		return m.PrimaryPart
	end
	-- 4) any BasePart as last resort
	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("BasePart") then
			return d
		end
	end
	-- No handle available right now (e.g., during swap/holster)
	return nil
end

local function _applyCommonProps(s: Sound, roll: Rolloff?)
	s.RollOffMode = (roll and roll.Mode) or Enum.RollOffMode.Inverse
	s.RollOffMaxDistance = (roll and roll.MaxDistance) or 90
end

local function _ensureSounds(handle: BasePart, cfg: SetConfig): (Sound, Sound, Sound)
	local vols: SoundVolumes = (cfg.Volumes or ({} :: SoundVolumes))
	local roll: Rolloff? = cfg.Rolloff

	-- Ignite
	local ignite: Sound? = handle:FindFirstChild("Ignite") :: Sound?
	if not ignite or not ignite:IsA("Sound") then
		ignite = Instance.new("Sound")
		ignite.Name = "Ignite"
		ignite.Parent = handle
	end
	local igniteSound = ignite :: Sound
	igniteSound.SoundId = cfg.Ids.Ignite
	igniteSound.Looped = false
	igniteSound.Volume = (vols.Ignite ~= nil and vols.Ignite or 1) :: number
	_applyCommonProps(igniteSound, roll)

	-- Hum (looping)
	local hum: Sound? = handle:FindFirstChild("Hum") :: Sound?
	if not hum or not hum:IsA("Sound") then
		hum = Instance.new("Sound")
		hum.Name = "Hum"
		hum.Parent = handle
	end
	local humSound = hum :: Sound
	humSound.SoundId = cfg.Ids.Hum
	humSound.Looped = true
	humSound.Volume = (vols.Hum ~= nil and vols.Hum or 0.6) :: number
	_applyCommonProps(humSound, roll)

	-- Disignite
	local dis: Sound? = handle:FindFirstChild("Disignite") :: Sound?
	if not dis or not dis:IsA("Sound") then
		dis = Instance.new("Sound")
		dis.Name = "Disignite"
		dis.Parent = handle
	end
	local disSound = dis :: Sound
	disSound.SoundId = cfg.Ids.Disignite
	disSound.Looped = false
	disSound.Volume = (vols.Disignite ~= nil and vols.Disignite or 1) :: number
	_applyCommonProps(disSound, roll)

	if cfg.Preload then
		pcall(function()
			local assets: { Instance } = { igniteSound, humSound, disSound }
			ContentProvider:PreloadAsync(assets)
		end)
	end

	return igniteSound, humSound, disSound
end

local function _rigInvalid(r: Rig): boolean
	if r.handle.Parent == nil or not r.handle:IsDescendantOf(r.model) then
		return true
	end
	if r.ignite.Parent == nil or r.hum.Parent == nil or r.disignite.Parent == nil then
		return true
	end
	return false
end

-- Return Rig? (nil when no usable handle exists).
local function _ensureRig(setName: string, model: HandSaber): Rig?
	local bySet0 = _rigs[model] -- may be nil
	local prev: Rig? = bySet0 and bySet0[setName] or nil
	if prev and prev.model.Parent ~= nil and not _rigInvalid(prev) then
		return prev
	end

	local cfg = _assertSet(setName)
	local handle = _getHandle(model)
	if not handle then
		-- No handle available right now (e.g., during equip/holster swap). Defer.
		return prev
	end

	local ignite, hum, dis = _ensureSounds(handle, cfg)
	local prevApply = (prev and prev.applyToken) or 0

	local newRig: Rig = {
		model = model,
		handle = handle,
		ignite = ignite,
		hum = hum,
		disignite = dis,
		alive = true,
		applyToken = prevApply,
	}

	-- Ensure nested table exists, then write back
	local bySet: { [string]: Rig } = bySet0 or {}
	_rigs[model] = bySet
	bySet[setName] = newRig

	return newRig
end

-- World-anchored one-shot (clone the template, never doubles on handle)
local function _playWorldOneShotFromTemplate(template: Sound?, atCf: CFrame)
	if not template or template.SoundId == "" then
		return
	end

	local anchor = Instance.new("Part")
	anchor.Name = "AudioService_SFXAnchor"
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

-- Concrete actions (all guard against missing rig/handle)
local function _igniteOnce(setName: string, model: HandSaber)
	local r = _ensureRig(setName, model)
	if not r then
		return
	end
	_playWorldOneShotFromTemplate(r.ignite, r.handle.CFrame)
end

local function _disigniteOnce(setName: string, model: HandSaber)
	local r = _ensureRig(setName, model)
	if not r then
		return
	end
	_playWorldOneShotFromTemplate(r.disignite, r.handle.CFrame)
end

local function _reassertHum(setName: string, model: HandSaber, wantOn: boolean)
	local r = _ensureRig(setName, model)
	if not r then
		return
	end

	r.applyToken += 1
	local token = r.applyToken

	if wantOn then
		r.hum.Playing = true
		for _ = 1, 16 do
			if not r.alive or token ~= r.applyToken then
				return
			end
			if not r.hum.IsPlaying then
				r.hum:Play()
			end
			task.wait(0.1)
			if r.hum.IsPlaying then
				return
			end
		end
	else
		r.hum.Playing = false
		for _ = 1, 4 do
			if not r.alive or token ~= r.applyToken then
				return
			end
			if r.hum.IsPlaying then
				r.hum:Stop()
			end
			task.wait(0.05)
		end
	end
end

-- ========= Public API =========

function AudioService.register(name: string, cfg: SetConfig)
	assert(name ~= "", "AudioService.register: name cannot be empty")
	_reg[name] = cfg
end

function AudioService.unregister(name: string)
	_reg[name] = nil
	for model, bySet0 in pairs(_rigs) do
		if bySet0 and bySet0[name] then
			AudioService.destroyForModel(name, model)
		end
	end
end

function AudioService.attachFromModel(setName: string, handSaber: HandSaber, bladeOn: BoolValue)
	_assertSet(setName)
	local r0 = _ensureRig(setName, handSaber)
	if r0 then
		r0.alive = true
	end

	-- narrow the nested map BEFORE indexing
	local bySetConn0 = _changedConns[handSaber]
	local bySetConn: { [string]: RBXScriptConnection } = bySetConn0 or {}
	_changedConns[handSaber] = bySetConn

	-- keep only one Changed connection for this (model,set)
	local existing = bySetConn[setName]
	if existing then
		existing:Disconnect()
		bySetConn[setName] = nil
	end

	-- assert hum to current state on next tick
	task.defer(function()
		_reassertHum(setName, handSaber, bladeOn.Value == true)
	end)

	bySetConn[setName] = bladeOn:GetPropertyChangedSignal("Value"):Connect(function()
		if bladeOn.Value then
			-- turning ON
			_igniteOnce(setName, handSaber)
			_reassertHum(setName, handSaber, true)
		else
			-- turning OFF
			_reassertHum(setName, handSaber, false)

			-- Check for single-use skip flag on the character (set by EquipService)
			local character = handSaber:FindFirstAncestorOfClass("Model")
			local skip = (character and character:GetAttribute("SkipNextDisignite")) == true

			if skip then
				-- clear the flag so the next normal off plays audio again
				pcall(function()
					character:SetAttribute("SkipNextDisignite", nil)
				end)
			else
				_disigniteOnce(setName, handSaber)
			end
		end
	end)

	handSaber.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			AudioService.destroyForModel(setName, handSaber)
		end
	end)
end

function AudioService.attach(setName: string, handle: BasePart, bladeOn: BoolValue)
	local model = handle:FindFirstAncestorOfClass("Model")
	if not model then
		error("AudioService.attach: handle must be inside a Model")
	end
	AudioService.attachFromModel(setName, model :: HandSaber, bladeOn)
end

function AudioService.forceApply(setName: string, handSaber: HandSaber, isOn: boolean)
	_assertSet(setName)
	-- If we can't ensure a rig (no handle right now), just no-op safely.
	if not _ensureRig(setName, handSaber) then
		return
	end
	_reassertHum(setName, handSaber, isOn)
end

function AudioService.stopForModel(setName: string, handSaber: HandSaber)
	_assertSet(setName)
	if not _ensureRig(setName, handSaber) then
		return
	end
	_reassertHum(setName, handSaber, false)
end

function AudioService.destroyForModel(setName: string, handSaber: HandSaber)
	local bySet0 = _rigs[handSaber]
	if bySet0 then
		local r = bySet0[setName]
		if r then
			r.alive = false
			pcall(function()
				r.hum.Playing = false
				r.hum:Stop()
			end)
			-- remove nested rig
			local bySet: { [string]: Rig } = bySet0
			bySet[setName] = nil
			_rigs[handSaber] = bySet
		end
	end

	local bySetConn0 = _changedConns[handSaber]
	if bySetConn0 then
		local c = bySetConn0[setName]
		if c then
			c:Disconnect()
			local bySetConn: { [string]: RBXScriptConnection } = bySetConn0
			bySetConn[setName] = nil
			_changedConns[handSaber] = bySetConn
		end
	end
end

-- ========= Default registration (Saber) =========
local DEFAULT_SABER: SetConfig = {
	Ids = {
		Ignite = "rbxassetid://6815895620",
		Hum = "rbxassetid://605578076",
		Disignite = "rbxassetid://1194453600",
	},
	Volumes = { Ignite = 1, Hum = 0.6, Disignite = 1 },
	Rolloff = { Mode = Enum.RollOffMode.Inverse, MaxDistance = 90 },
	Preload = false,
}

AudioService.register("Saber", DEFAULT_SABER)

return AudioService
