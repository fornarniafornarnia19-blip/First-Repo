--!strict
-- ServerScriptService/Services/BlockService.luau

local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

-- Net wiring - FIXED PATH
local Net = require(RS:WaitForChild("Shared"):WaitForChild("NetUtil"))

-- =========================
-- Dependency resolution (path-agnostic under Services)
-- =========================
local ServicesRoot: Folder = (SSS:WaitForChild("Services")) :: Folder

local function findModule(root: Instance, name: string): ModuleScript
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
	error(("[BlockService] Service module '%s' not found under %s"):format(name, root:GetFullName()))
end

local function requireService(name: string): any
	local mod: ModuleScript = findModule(ServicesRoot, name) :: ModuleScript
	return require(mod)
end

-- Dependencies (agnostic to folder structure)
local Rig: any = requireService("RigService")
local State: any = requireService("StateService")
local AnimSvc: any = requireService("AnimationService")

-- =========================

local SET = "Saber"

type CharState = {
	track: AnimationTrack?,
	holding: boolean,
	stoppedConn: RBXScriptConnection?,
	playedConn: RBXScriptConnection?, -- intercept newly started tracks while blocking
	ignoreUntil: number?, -- grace period end (spawn)
}

-- IMPORTANT: strong keys (no weak table)
local byChar: { [Model]: CharState } = {} :: any

-- ===== Utilities =====

local function getAnimator(char: Model): Animator?
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return nil
	end
	local animator = hum:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = hum
	end
	return animator
end

local function clearConns(st: CharState?)
	if not st then
		return
	end
	local list = { st.stoppedConn, st.playedConn }
	for _, c in ipairs(list) do
		if c then
			pcall(function()
				c:Disconnect()
			end)
		end
	end
	st.stoppedConn, st.playedConn = nil, nil
end

local function stopTrack(char: Model)
	local st = byChar[char]
	if not st then
		return
	end
	clearConns(st)
	if st.track then
		pcall(function()
			st.track:AdjustSpeed(1)
		end)
		pcall(function()
			st.track:Stop(0.05)
		end)
		pcall(function()
			st.track:Destroy()
		end)
	end
	st.track = nil
end

local function setBlocking(char: Model, value: boolean)
	-- Canonical flag (and let StateService enforce mutual exclusion)
	local folder = State.getFolder and State.getFolder(char)
	if folder then
		local b: Instance? = folder:FindFirstChild("Blocking")
		if not b then
			b = Instance.new("BoolValue")
			b.Name = "Blocking"
			b.Parent = folder
		end
		(b :: BoolValue).Value = value
	end
	if State.setBlocking then
		State.setBlocking(char, value)
		-- (Assumption: StateService clears Swinging when Blocking=true)
	end
end

local function canBlock(char: Model): boolean
	if not (Rig and Rig.isEquipped and State and State.getBladeOn) then
		return false
	end
	if not Rig.isEquipped(SET, char) then
		return false
	end
	return State.getBladeOn(char) == true
end

-- Identify swing tracks to kill while blocking (server authority)
local function isSwingTrack(track: AnimationTrack): boolean
	if AnimSvc.isSwingTrack then
		local ok, res = pcall(function()
			return AnimSvc.isSwingTrack(track)
		end)
		if ok and res == true then
			return true
		end
	end
	if AnimSvc.isSwingId and track.Animation and track.Animation:IsA("Animation") then
		local assetId = (track.Animation.AnimationId :: any) :: string?
		if assetId then
			local ok, res = pcall(function()
				return AnimSvc.isSwingId(assetId)
			end)
			if ok and res == true then
				return true
			end
		end
	end
	local nm = (track.Name ~= "" and track.Name) or (track.Animation and track.Animation.Name) or ""
	if typeof(nm) == "string" then
		return string.find(string.lower(nm), "swing", 1, true) ~= nil
	end
	return false
end

local function stopAllSwings(animator: Animator, except: AnimationTrack?)
	for _, t in ipairs(animator:GetPlayingAnimationTracks()) do
		if t ~= except and isSwingTrack(t) then
			pcall(function()
				t:Stop(0.05)
			end)
		end
	end
end

-- Pull ONLY the block animation defined by WeaponServices.AnimationService
local function getBlockAnimationFor(char: Model): Animation?
	-- Try a few common function names; adapt to your AnimSvc API
	-- Priority order: explicit getter → builder → id resolver
	if AnimSvc.getBlockAnimation then
		local ok, anim = pcall(function()
			return AnimSvc.getBlockAnimation(SET, char)
		end)
		if ok and anim and anim:IsA("Animation") then
			return anim
		end
	end
	if AnimSvc.buildBlockAnimation then
		local ok, anim = pcall(function()
			return AnimSvc.buildBlockAnimation(SET, char)
		end)
		if ok and anim and anim:IsA("Animation") then
			return anim
		end
	end
	if AnimSvc.getBlockId then
		local ok, id = pcall(function()
			return AnimSvc.getBlockId(SET, char)
		end)
		if ok and typeof(id) == "string" and id ~= "" then
			local anim = Instance.new("Animation")
			anim.AnimationId = id
			return anim
		end
	end
	return nil
end

-- ===== Playback (server-owned) =====

local function playBlock(char: Model)
	local animator = getAnimator(char)
	if not animator then
		return
	end

	-- Only use the block anim provided by WeaponServices.AnimationService
	local anim = getBlockAnimationFor(char)
	if not anim then
		-- If there is no registered block anim for this weapon, do nothing.
		return
	end

	local st: CharState = byChar[char] or { holding = false } :: any
	byChar[char] = st

	-- If we already have an active block track for this char and it's still playing, don't stack
	if st.track and st.track.IsPlaying then
		-- Keep it idempotent
		return
	end

	-- stop previous block track (idempotent)
	stopTrack(char)

	-- load & play (respect priority configured elsewhere)
	local track = animator:LoadAnimation(anim)
	-- DO NOT override priority here; keep whatever was configured.
	track.Looped = true
	st.track = track

	-- Kill swings that might trigger while holding
	stopAllSwings(animator, track)

	-- (Re)attach listeners once per active block track
	st.playedConn = animator.AnimationPlayed:Connect(function(newTrack: AnimationTrack)
		if st.holding and newTrack ~= track and isSwingTrack(newTrack) then
			pcall(function()
				newTrack:Stop(0)
			end)
		end
	end)

	st.stoppedConn = track.Stopped:Connect(function()
		if st.track ~= track then
			return
		end
		stopTrack(char)
	end)

	track:Play(0.04, 1.0, 1.0)
	track:AdjustWeight(1, 0)
	pcall(function()
		track:AdjustSpeed(1)
	end)
end

-- ===== Network =====

-- Per-character grace window after spawn to ignore accidental client spam/state carry
local GRACE_SEC = 1.0

local function onCharacterAdded(char: Model)
	local st: CharState = byChar[char] or { holding = false } :: any
	byChar[char] = st
	st.ignoreUntil = time() + GRACE_SEC
	-- Ensure we are not "blocking" by default
	setBlocking(char, false)
	stopTrack(char)
end

local function cleanupCharacter(char: Model)
	-- Deterministic cleanup to pair with strong-key table
	stopTrack(char)
	byChar[char] = nil
end

-- Hook Player.CharacterAdded/Removing to manage lifecycle
Players.PlayerAdded:Connect(function(plr: Player)
	plr.CharacterAdded:Connect(onCharacterAdded)
	plr.CharacterRemoving:Connect(function(c)
		cleanupCharacter(c)
	end)
	if plr.Character then
		onCharacterAdded(plr.Character)
	end
end)

local function onBlock(plr: Player, holding: boolean)
	local char = plr.Character
	if not (char and char.Parent) then
		return
	end

	local st: CharState = byChar[char] or { holding = false } :: any
	byChar[char] = st

	-- Spawn grace: ignore any attempt to start block during the first second
	if holding and st.ignoreUntil and time() < st.ignoreUntil then
		return
	end

	-- If starting a block but cannot (not equipped / blade off), hard-clear and bail
	if holding and not canBlock(char) then
		setBlocking(char, false)
		stopTrack(char)
		st.holding = false
		return
	end

	-- No-op if the requested state matches current
	if st.holding == holding then
		return
	end

	-- Canonical state (mutual exclusivity handled by StateService)
	setBlocking(char, holding)
	st.holding = holding

	-- Optional broadcast for other systems - NEW API
	Net.FireAllClients("Saber_BroadcastState", plr.UserId, holding)

	if holding then
		playBlock(char) -- ONLY plays the WeaponServices.AnimationService block anim
	else
		stopTrack(char)
	end
end

-- ===== Service =====

local BlockService = {}

function BlockService:Init()
	-- NEW API: Register event handler
	Net.OnServerEvent("Saber_Block", onBlock)
end

function BlockService:Start() end

return BlockService
