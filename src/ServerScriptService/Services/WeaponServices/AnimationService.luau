--!strict
-- ServerScriptService/Services/AnimationService.luau

local ContentProvider = game:GetService("ContentProvider")

-- ===== Types =====
export type AnimIds = {
	Ignite: string,
	Retract: string, -- "" => reuse Ignite
	Equip: string,
}

export type Markers = {
	Ignite: string,
	Retract: string?, -- falls back to Ignite if nil
	SwapToHand: string?,
	SwapToHip: string?,
}

export type Timings = {
	IgniteSpeed: number?, -- default 1
	RetractSpeed: number?, -- default 1
	IgniteDuration: number?, -- optional seconds (speed-adjusted)
	RetractDuration: number?, -- optional seconds
	FadeIn: number?, -- default 0.07
	FuseRatio: number?, -- default 0.65
	FuseMin: number?, -- default 0.25
	FuseMax: number?, -- default 1.20
}

export type SetConfig = {
	Ids: AnimIds,
	Markers: Markers,
	Timings: Timings?, -- optional
	Preload: boolean?, -- server PreloadAsync won’t warm client but harmless
}

export type AnimTriplet = {
	Ignite: Animation,
	Retract: Animation?, -- nil => use Ignite
	Equip: Animation,
}

export type TracksTriplet = {
	Ignite: AnimationTrack,
	Retract: AnimationTrack?,
	Equip: AnimationTrack,
}

export type Reason = "ignite" | "retract" | "holster" | "spawn" | "death"
export type EquipMode = "SwapToHand" | "SwapToHip"

export type BackCompatAnim = {
	IgniteAnim: Animation,
	RetractAnim: Animation?,
	MarkerIgnite: string,
	MarkerRetract: string,
	IgniteSpeed: number?,
	IgniteDuration: number?,
	RetractSpeed: number?,
	RetractDuration: number?,
	FadeIn: number?,
	FuseRatio: number?,
	FuseMin: number?,
	FuseMax: number?,
}
export type BackCompatConfig = { Anim: BackCompatAnim }

type Registry = { [string]: SetConfig }
type Cache = { [string]: AnimTriplet }

export type ToggleHooks = {
	onToggle: ((character: Model, wantOn: boolean, reason: Reason) -> ())?, -- ignite/retract
	onEquipSwap: ((character: Model, mode: EquipMode, player: Player?) -> ())?, -- equip swap
}

-- Block config
export type BlockCfg = { Id: string, Priority: Enum.AnimationPriority?, FadeIn: number? }

-- ===== Module =====
local AnimationService = {}
AnimationService._registry = {} :: Registry
AnimationService._cache = {} :: Cache
AnimationService._hooks = {} :: ToggleHooks

-- Optional swing animations per set (dir -> id)
local _swingIds: { [string]: { [string]: string } } = {}

-- Optional block animation per set
local _blockCfg: { [string]: BlockCfg } = {}

-- per-character animation state (weak keys)
local igniteTrackByChar: { [Model]: AnimationTrack } = setmetatable({}, { __mode = "k" }) :: any
local animTokenByChar: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any

-- equip anim state (weak keys)
local equipTrackByChar: { [Model]: AnimationTrack? } = setmetatable({}, { __mode = "k" }) :: any
local equipTokenByChar: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any

-- block anim state (weak keys)
local blockTrackByChar: { [Model]: AnimationTrack? } = setmetatable({}, { __mode = "k" }) :: any

-- ===== Internals =====
local function _makeAnimations(cfg: SetConfig): AnimTriplet
	local ign = Instance.new("Animation")
	ign.AnimationId = cfg.Ids.Ignite

	local ret: Animation? = nil
	if cfg.Ids.Retract ~= "" then
		ret = Instance.new("Animation")
		ret.AnimationId = cfg.Ids.Retract
	end

	local eq = Instance.new("Animation")
	eq.AnimationId = cfg.Ids.Equip

	if cfg.Preload then
		pcall(function()
			local assets: { Instance } = { ign, eq }
			if ret then
				table.insert(assets, ret)
			end
			ContentProvider:PreloadAsync(assets)
		end)
	end

	return { Ignite = ign, Retract = ret, Equip = eq }
end

local function _getOrBuild(name: string): AnimTriplet
	local cfg = AnimationService._registry[name]
	assert(cfg, `AnimationService: unknown set '{name}'`)
	local cached = AnimationService._cache[name]
	if not cached then
		cached = _makeAnimations(cfg)
		AnimationService._cache[name] = cached
	end
	return cached
end

local function _ensureAnimator(hum: Humanoid): Animator
	local animator = hum:FindFirstChildOfClass("Animator")
	if animator then
		return animator
	end
	local newAnimator = Instance.new("Animator")
	newAnimator.Parent = hum
	return newAnimator
end

local function _markersFor(name: string): Markers
	local cfg = AnimationService._registry[name]
	assert(cfg, `AnimationService: unknown set '{name}'`)
	return cfg.Markers
end

local function _timingsFor(name: string): Timings
	local cfg = AnimationService._registry[name]
	assert(cfg, `AnimationService: unknown set '{name}'`)
	return cfg.Timings or {}
end

-- ===== Public API: Registry / Cache =====
function AnimationService.register(name: string, cfg: SetConfig)
	assert(name ~= "", "AnimationService.register: name cannot be empty")
	AnimationService._registry[name] = cfg
	AnimationService._cache[name] = _makeAnimations(cfg)
end

function AnimationService.unregister(name: string)
	AnimationService._registry[name] = nil
	AnimationService._cache[name] = nil
	_swingIds[name] = nil
	_blockCfg[name] = nil
end

function AnimationService.getMarkers(name: string): Markers
	return _markersFor(name)
end

function AnimationService.buildAnimations(name: string): (Animation, Animation?, Animation)
	local t = _getOrBuild(name)
	return t.Ignite, t.Retract, t.Equip
end

function AnimationService.loadAll(name: string, animator: Animator): TracksTriplet
	local ign, ret, eq = AnimationService.buildAnimations(name)
	local ignTrack = animator:LoadAnimation(ign)
	local retTrack: AnimationTrack? = (ret and animator:LoadAnimation(ret)) or nil
	local eqTrack = animator:LoadAnimation(eq)
	return { Ignite = ignTrack, Retract = retTrack, Equip = eqTrack }
end

function AnimationService.bindMarker(
	track: AnimationTrack,
	markerName: string,
	cb: (string, number) -> ()
): RBXScriptConnection
	assert(markerName ~= "", "AnimationService.bindMarker: markerName is empty")
	return track:GetMarkerReachedSignal(markerName):Connect(cb)
end

function AnimationService.setToggleHooks(hooks: ToggleHooks)
	AnimationService._hooks = hooks or {}
end

-- ===== Back-compat helper =====
function AnimationService.getConfig(name: string): BackCompatConfig
	local t = _getOrBuild(name)
	local m = _markersFor(name)
	local tm = _timingsFor(name)
	return {
		Anim = {
			IgniteAnim = t.Ignite,
			RetractAnim = t.Retract,
			MarkerIgnite = m.Ignite,
			MarkerRetract = m.Retract or m.Ignite,
			IgniteSpeed = tm.IgniteSpeed,
			IgniteDuration = tm.IgniteDuration,
			RetractSpeed = tm.RetractSpeed,
			RetractDuration = tm.RetractDuration,
			FadeIn = tm.FadeIn,
			FuseRatio = tm.FuseRatio,
			FuseMin = tm.FuseMin,
			FuseMax = tm.FuseMax,
		},
	}
end

-- ===== Ignite/Retact flow =====
function AnimationService.stopIgniteAnim(character: Model)
	animTokenByChar[character] = (animTokenByChar[character] or 0) + 1
	local prev = igniteTrackByChar[character]
	if prev then
		igniteTrackByChar[character] = nil
		pcall(function()
			prev:Stop()
		end)
		pcall(function()
			prev:Destroy()
		end)
	end
end

function AnimationService.playIgniteAndToggle(name: string, character: Model, wantOn: boolean)
	local hum = character:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end

	local animator = _ensureAnimator(hum)
	AnimationService.stopIgniteAnim(character)

	local myToken = (animTokenByChar[character] or 0) + 1
	animTokenByChar[character] = myToken

	local triplet = _getOrBuild(name)
	local timings = _timingsFor(name)
	local markers = _markersFor(name)

	local anim: Animation = wantOn and triplet.Ignite or (triplet.Retract or triplet.Ignite) :: Animation
	local speed: number = wantOn and (timings.IgniteSpeed or 1) or (timings.RetractSpeed or 1)
	local targetDur: number? = wantOn and timings.IgniteDuration or timings.RetractDuration
	local markerName: string = wantOn and markers.Ignite or (markers.Retract or markers.Ignite)
	assert(markerName and markerName ~= "", "AnimationService: markerName missing")

	local track = animator:LoadAnimation(anim)
	track.Priority = Enum.AnimationPriority.Action
	track.Looped = false
	igniteTrackByChar[character] = track

	local toggled = false
	local sawMarker = false
	local conns: { RBXScriptConnection } = {}

	local function doToggleOnce()
		if toggled or animTokenByChar[character] ~= myToken then
			return
		end
		toggled = true
		local reason: Reason = if wantOn then "ignite" else "retract"
		local onToggle = AnimationService._hooks.onToggle
		if onToggle then
			onToggle(character, wantOn, reason)
		end
	end

	table.insert(
		conns,
		track:GetMarkerReachedSignal(markerName):Connect(function()
			if animTokenByChar[character] ~= myToken then
				return
			end
			sawMarker = true
			doToggleOnce()
		end)
	)

	table.insert(
		conns,
		track.KeyframeReached:Connect(function(kfName)
			if animTokenByChar[character] ~= myToken then
				return
			end
			if kfName == markerName then
				sawMarker = true
				doToggleOnce()
			end
		end)
	)

	table.insert(
		conns,
		track.Stopped:Connect(function()
			if animTokenByChar[character] ~= myToken then
				return
			end
			for _, c in ipairs(conns) do
				pcall(function()
					c:Disconnect()
				end)
			end
			if igniteTrackByChar[character] == track then
				igniteTrackByChar[character] = nil
			end
			if not toggled then
				doToggleOnce()
			end
			pcall(function()
				track:Destroy()
			end)
		end)
	)

	local fadeIn = timings.FadeIn or 0.07
	track:Play(fadeIn, 1.0, speed)

	if targetDur and targetDur > 0 then
		local function applyDur(): boolean
			if track.Length and track.Length > 0 then
				track:AdjustSpeed(track.Length / targetDur)
				return true
			end
			return false
		end
		if not applyDur() then
			local lenConn: RBXScriptConnection?
			lenConn = track:GetPropertyChangedSignal("Length"):Connect(function()
				if applyDur() and lenConn then
					lenConn:Disconnect()
				end
			end)
		end
	end

	local ratio = timings.FuseRatio or 0.65
	local fuseMin = timings.FuseMin or 0.25
	local fuseMax = timings.FuseMax or 1.20
	local base = (targetDur and targetDur * ratio) or 0.50
	local fuseDelay = math.clamp(base, fuseMin, fuseMax)

	task.delay(fuseDelay, function()
		if animTokenByChar[character] ~= myToken then
			return
		end
		if not toggled and not sawMarker then
			doToggleOnce()
		end
	end)
end

-- ===== Equip flow =====
function AnimationService.isEquipPlaying(character: Model): boolean
	return equipTrackByChar[character] ~= nil
end

function AnimationService.stopEquip(character: Model)
	equipTokenByChar[character] = (equipTokenByChar[character] or 0) + 1
	local t = equipTrackByChar[character]
	if t then
		equipTrackByChar[character] = nil
		pcall(function()
			t:Stop()
		end)
		pcall(function()
			t:Destroy()
		end)
	end
end

function AnimationService.playEquip(name: string, character: Model, mode: EquipMode, player: Player?)
	local hum = character:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end

	local animator: Animator = _ensureAnimator(hum)
	AnimationService.stopEquip(character)

	local myToken = (equipTokenByChar[character] or 0) + 1
	equipTokenByChar[character] = myToken

	local eqAnim: Animation = _getOrBuild(name).Equip
	local markers = _markersFor(name)
	local targetMarker = if mode == "SwapToHip" then markers.SwapToHip else markers.SwapToHand
	assert(targetMarker and targetMarker ~= "", "AnimationService: missing SwapToHand/SwapToHip markers")

	local track = animator:LoadAnimation(eqAnim)
	track.Priority = Enum.AnimationPriority.Action
	track.Looped = false
	equipTrackByChar[character] = track

	local applied = false
	local conns: { RBXScriptConnection } = {}

	local function applyOnce()
		if applied or equipTokenByChar[character] ~= myToken then
			return
		end
		applied = true
		local onEquipSwap = AnimationService._hooks.onEquipSwap
		if onEquipSwap then
			onEquipSwap(character, mode, player)
		end
	end

	table.insert(
		conns,
		track:GetMarkerReachedSignal(targetMarker):Connect(function()
			if equipTokenByChar[character] ~= myToken then
				return
			end
			applyOnce()
		end)
	)

	table.insert(
		conns,
		track.KeyframeReached:Connect(function(kfName)
			if equipTokenByChar[character] ~= myToken then
				return
			end
			if kfName == targetMarker then
				applyOnce()
			end
		end)
	)

	table.insert(
		conns,
		track.Stopped:Connect(function()
			if equipTokenByChar[character] ~= myToken then
				return
			end
			applyOnce()
			for _, c in ipairs(conns) do
				pcall(function()
					c:Disconnect()
				end)
			end
			if equipTrackByChar[character] == track then
				equipTrackByChar[character] = nil
			end
			pcall(function()
				track:Destroy()
			end)
		end)
	)

	track:Play()
end

-- ===== Swings (optional) =====
function AnimationService.registerSwings(setName: string, dirToId: { [string]: string })
	_swingIds[setName] = dirToId
end

function AnimationService.playSwing(setName: string, character: Model, dir: string)
	local map = _swingIds[setName]
	if not map then
		return
	end
	local id = map[dir]
	if not id or id == "" then
		return
	end

	local hum = character:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end
	local animator = _ensureAnimator(hum)

	local anim = Instance.new("Animation")
	anim.AnimationId = id
	local track = animator:LoadAnimation(anim)
	track.Priority = Enum.AnimationPriority.Action4
	track.Looped = false
	track:Play(0.06, 1.0, 1.0)
	return track
end

-- ===== Block (RMB hold) =====
function AnimationService.registerBlock(setName: string, idOrCfg: string | BlockCfg)
	if typeof(idOrCfg) == "string" then
		_blockCfg[setName] = {
			Id = idOrCfg :: string,
			Priority = Enum.AnimationPriority.Core, -- default Action
			FadeIn = 0.04,
		}
	else
		local c = idOrCfg :: BlockCfg
		assert(c.Id and c.Id ~= "", "AnimationService.registerBlock: missing Id")
		_blockCfg[setName] = {
			Id = c.Id,
			Priority = c.Priority or Enum.AnimationPriority.Core, -- default Action
			FadeIn = c.FadeIn or 0.04,
		}
	end
end

function AnimationService.playBlock(setName: string, character: Model): AnimationTrack?
	local cfg = _blockCfg[setName]
	if not cfg then
		return nil
	end

	local hum = character:FindFirstChildOfClass("Humanoid")
	if not hum then
		return nil
	end
	local animator = _ensureAnimator(hum)

	-- Stop any existing block track first
	AnimationService.stopBlock(character)

	local anim = Instance.new("Animation")
	anim.AnimationId = cfg.Id
	-- Ensure Action priority regardless of asset-baked priority
	anim.Priority = Enum.AnimationPriority.Core

	local track = animator:LoadAnimation(anim)
	track.Priority = Enum.AnimationPriority.Core
	track.Looped = true -- no more manual freeze; just loop while blocking
	blockTrackByChar[character] = track

	track:Play((cfg.FadeIn or 0.04), 1.0, 1.0)
	pcall(function()
		track:AdjustSpeed(1)
	end)

	return track
end

function AnimationService.stopBlock(character: Model)
	local t = blockTrackByChar[character]
	if t then
		blockTrackByChar[character] = nil
		pcall(function()
			t:AdjustSpeed(1)
		end)
		pcall(function()
			t:Stop()
		end)
		pcall(function()
			t:Destroy()
		end)
	end
end

-- ===== Default registration (Saber) =====
AnimationService.register("Saber", {
	Ids = {
		Ignite = "rbxassetid://70744203501030",
		Retract = "rbxassetid://109921934993891",
		Equip = "rbxassetid://122681916196297",
	},
	Markers = {
		Ignite = "Ignite",
		Retract = "Ignite",
		SwapToHand = "SwapToHand",
		SwapToHip = "SwapToHip",
	},
	Timings = {
		IgniteSpeed = 1,
		RetractSpeed = 1,
		IgniteDuration = 0.40,
		RetractDuration = 0.40,
		FadeIn = 0.07,
		FuseRatio = 0.65,
		FuseMin = 0.25,
		FuseMax = 1.20,
	},
	Preload = true,
})

-- Default swing IDs (server can override via registerSwings)
AnimationService.registerSwings("Saber", {
	Overhead = "rbxassetid://91356563717212",
	Left = "rbxassetid://114496528738350",
	Right = "rbxassetid://135467732004248",
	UpLeft = "rbxassetid://93592035667236",
	UpRight = "rbxassetid://89080841575247",
	DownLeft = "rbxassetid://112091636854822",
	DownRight = "rbxassetid://104057985989470",
})

-- Default block (hold RMB)
AnimationService.registerBlock("Saber", "rbxassetid://77984271610705") -- BlockGuard

-- add these after function AnimationService.registerBlock(...)
function AnimationService.getBlockCfg(setName: string): BlockCfg?
	return _blockCfg[setName]
end

function AnimationService.buildBlockAnimation(setName: string): Animation?
	local cfg = _blockCfg[setName]
	if not cfg then
		return nil
	end
	local a = Instance.new("Animation")
	a.AnimationId = cfg.Id
	return a
end

return AnimationService
