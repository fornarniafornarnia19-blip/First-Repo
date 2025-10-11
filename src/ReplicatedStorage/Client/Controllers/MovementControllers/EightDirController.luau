-- EightDirController (client, dual-layer, 0.15s crossfade)
-- Primary = Movement, Secondary = Movement (phase-locked). No GUI/HRP/Q/J/V.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local M = {}

-- ===== Anim Sets =====
local ANIMS_8_PRIMARY = {
	F = "rbxassetid://117259060654947",
	FR = "rbxassetid://97439699620767",
	R = "rbxassetid://85047128221566",
	BR = "rbxassetid://96383285518170",
	B = "rbxassetid://89363803841322",
	BL = "rbxassetid://80712335075758",
	L = "rbxassetid://73246874799560",
	FL = "rbxassetid://100296251128923",
}

local ANIMS_8_SECONDARY = {
	F = "rbxassetid://112503433100334",
	FR = "rbxassetid://136957112006678",
	FL = "rbxassetid://118898865447576",
	L = "rbxassetid://86305878357879",
	R = "rbxassetid://128415616067334",
	BR = "rbxassetid://119783787830715",
	BL = "rbxassetid://112929833091681",
	B = "rbxassetid://83853326163861",
}

-- ===== Playback params =====
local FADE_TIME = 0.15
local SPEED_PRI = 1.0
local SPEED_SEC = 1.0
local RESYNC_EPS = 0.08
local SEC_WEIGHT = 1.0 -- secondary layer blend weight (applied instantly)

-- Priorities (both Movement)
local PRI_PRIORITY = Enum.AnimationPriority.Movement
local SEC_PRIORITY = Enum.AnimationPriority.Action2

-- ===== Locals =====
local plr = Players.LocalPlayer
local char, hum, lt, animator
-- tracks[dir] = { primary=AnimationTrack?, secondary=AnimationTrack? }
local tracks = {}
local currentDir
local steppedConn, ancestryConn

-- ===== Helpers =====
local DIRS = { "F", "FR", "R", "BR", "B", "BL", "L", "FL" }

local function octantFromXZ(x, z)
	if math.abs(x) < 1e-4 and math.abs(z) < 1e-4 then
		return nil
	end
	local ang = math.atan2(x, -z)
	local idx = (math.floor((ang / (2 * math.pi)) * 8 + 0.5) % 8) + 1
	return DIRS[idx]
end

local function stopAll()
	if not hum then
		return
	end
	local animator0 = hum:FindFirstChildOfClass("Animator")
	if animator0 then
		for _, t in ipairs(animator0:GetPlayingAnimationTracks()) do
			pcall(function()
				t:Stop(0)
			end)
		end
	end
	local animate = char and char:FindFirstChild("Animate")
	if animate and animate:IsA("LocalScript") then
		animate.Disabled = true
	end
end

local function loadTrack(animId, priority)
	local anim = Instance.new("Animation")
	anim.AnimationId = animId
	pcall(function()
		anim.Priority = priority
	end)
	local tr = animator:LoadAnimation(anim)
	tr.Looped = true
	pcall(function()
		tr.Priority = priority
	end)
	return tr
end

local function buildTracks()
	tracks = {}
	for _, dir in ipairs(DIRS) do
		local priId = ANIMS_8_PRIMARY[dir]
		local secId = ANIMS_8_SECONDARY[dir]
		tracks[dir] = {
			primary = priId and loadTrack(priId, PRI_PRIORITY) or nil,
			secondary = secId and loadTrack(secId, SEC_PRIORITY) or nil,
		}
	end
	-- overlay was removed
end

local function stopBundle(bndl, fade)
	if not bndl then
		return
	end
	if bndl.primary then
		pcall(function()
			bndl.primary:Stop(fade or FADE_TIME)
		end)
	end
	if bndl.secondary then
		pcall(function()
			bndl.secondary:Stop(fade or FADE_TIME)
		end)
	end
end

local function playBundle(bndl)
	if not bndl then
		return
	end
	-- primary first (to phase-lock)
	if bndl.primary then
		pcall(function()
			bndl.primary:Play(FADE_TIME, 1.0, SPEED_PRI)
			bndl.primary:AdjustSpeed(SPEED_PRI)
			-- keep primary normal; no instant jump needed here
			if bndl.primary.AdjustWeight then
				bndl.primary:AdjustWeight(1.0, FADE_TIME)
			end
		end)
	end
	if bndl.secondary then
		pcall(function()
			-- Play at desired speed; then force weight to 1 instantly (no fade)
			bndl.secondary:Play(FADE_TIME, SEC_WEIGHT, SPEED_SEC)
			bndl.secondary:AdjustSpeed(SPEED_SEC)
			if bndl.secondary.AdjustWeight then
				-- instant set (0 seconds)
				bndl.secondary:AdjustWeight(SEC_WEIGHT, 0)
			end
			-- phase-lock to primary if present
			if bndl.primary and bndl.primary.IsPlaying then
				bndl.secondary.TimePosition = bndl.primary.TimePosition
			end
		end)
	end
end

local function resyncIfNeeded(bndl)
	if not bndl or not bndl.primary or not bndl.secondary then
		return
	end
	local ok1, tp1 = pcall(function()
		return bndl.primary.TimePosition
	end)
	local ok2, tp2 = pcall(function()
		return bndl.secondary.TimePosition
	end)
	if ok1 and ok2 and math.abs(tp1 - tp2) > RESYNC_EPS then
		pcall(function()
			bndl.secondary.TimePosition = tp1
		end)
	end
end

-- ===== Tick =====
local function onRender(_dt)
	if not (hum and lt) then
		return
	end

	-- Pick direction in hips space
	local hipsCF = lt.CFrame
	local mv = hum.MoveDirection
	local mvHips = hipsCF:VectorToObjectSpace(Vector3.new(mv.X, 0, mv.Z))
	local pick = octantFromXZ(mvHips.X, mvHips.Z)

	-- 0.15s crossfades between octants
	if pick ~= currentDir then
		if currentDir then
			stopBundle(tracks[currentDir], FADE_TIME)
		end
		currentDir = pick
		if pick then
			playBundle(tracks[pick])
		end
	else
		if currentDir then
			resyncIfNeeded(tracks[currentDir])
		end
	end
end

local function attach(character)
	-- cleanup
	if currentDir then
		stopBundle(tracks[currentDir], 0)
	end
	currentDir = nil
	tracks = {}
	if steppedConn then
		steppedConn:Disconnect()
		steppedConn = nil
	end
	if ancestryConn then
		ancestryConn:Disconnect()
		ancestryConn = nil
	end
	stopAll()

	char = character
	if not char then
		return
	end

	hum = char:WaitForChild("Humanoid")
	lt = char:WaitForChild("LowerTorso")
	animator = hum:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end

	buildTracks()
	steppedConn = RunService.RenderStepped:Connect(onRender)

	ancestryConn = char.AncestryChanged:Connect(function(_, parent)
		if not parent and currentDir then
			stopBundle(tracks[currentDir], 0)
			currentDir = nil
		end
	end)
end

-- ===== Public API =====
function M.setSpeeds(primarySpeed, secondarySpeed)
	if primarySpeed then
		SPEED_PRI = primarySpeed
	end
	if secondarySpeed then
		SPEED_SEC = secondarySpeed
	end
	-- apply to current playing bundle
	if currentDir and tracks[currentDir] then
		local b = tracks[currentDir]
		if b.primary then
			pcall(function()
				b.primary:AdjustSpeed(SPEED_PRI)
			end)
		end
		if b.secondary then
			pcall(function()
				b.secondary:AdjustSpeed(SPEED_SEC)
			end)
		end
	end
end

function M.setSecondaryWeight(w)
	if typeof(w) == "number" then
		SEC_WEIGHT = math.clamp(w, 0, 1)
		-- apply immediately if something is playing (no fade)
		if currentDir and tracks[currentDir] and tracks[currentDir].secondary then
			local s = tracks[currentDir].secondary
			pcall(function()
				if s.AdjustWeight then
					s:AdjustWeight(SEC_WEIGHT, 0) -- instant
				end
			end)
		end
	end
end

function M.start()
	local player = Players.LocalPlayer
	if player.Character then
		task.defer(function()
			attach(player.Character)
		end)
	end
	player.CharacterAdded:Connect(function(c)
		attach(c)
	end)
end

return M
