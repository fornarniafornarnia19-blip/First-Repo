--!strict
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")

local SET = "Saber"

-- Net - FIXED PATH
local Net = require(RS:WaitForChild("Shared"):WaitForChild("NetUtil"))

-- ========= Path-agnostic service resolver (under SSS/Services) =========
local ServicesRoot = SSS:WaitForChild("Services")

local function findModule(root: Instance, name: string): ModuleScript
	-- direct child (supports Folder/init)
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
	error(("[SwingService] Service module '%s' not found under %s"):format(name, root:GetFullName()))
end

local function requireService(name: string): any
	return require(findModule(ServicesRoot, name))
end
-- ======================================================================

-- Services (agnostic to folder structure)
local Rig: any = requireService("RigService")
local State: any = requireService("StateService")
local Anim: any = requireService("AnimationService")

-- ===== Debug =====
local DEBUG_LOG = false
local function dprint(...: any)
	if DEBUG_LOG then
		print("[Swing]", ...)
	end
end

-- ===== Timing =====
local COOLDOWN = 0.32 -- server gate between allowed swings
local DEFAULT_SWING_DURATION = 0.75 -- conservative fallback; set >= actual swing anim length

-- Per-player gates
local nextOk: { [number]: number } = {} -- userId -> next allowed time (cooldown)
local swingLockUntil: { [number]: number } = {} -- userId -> time until which we ignore ALL swing inputs

-- ===== Helpers =====
local function getSwingDuration(dir: string): number
	-- Prefer data from AnimationService if available
	if Anim.getSwingDuration then
		local ok, dur = pcall(function()
			local v = Anim.getSwingDuration(SET, dir)
			if typeof(v) == "number" then
				return v
			end
			return Anim.getSwingDuration(dir)
		end)
		if ok and typeof(dur) == "number" and dur > 0 then
			return dur
		end
	end
	return DEFAULT_SWING_DURATION
end

-- Fallback dir validator if AnimationService.isValidSwingDir isn't present
local _fallbackValid = {
	Overhead = true,
	Left = true,
	Right = true,
	UpLeft = true,
	UpRight = true,
	DownLeft = true,
	DownRight = true,
}
local function isValidDir(dir: string): boolean
	if Anim.isValidSwingDir then
		return Anim.isValidSwingDir(dir)
	end
	return _fallbackValid[dir] == true
end

-- Equipped/hand-out?
local function isHandOut(char: Model): boolean
	if Rig.isEquipped and Rig.isEquipped(SET, char) then
		return true
	end
	-- soft fallback: look for HandSaber in Cosmetics
	local cos = char:FindFirstChild("Cosmetics") or char
	local m = (cos and (cos:FindFirstChild("HandSaber") or cos:FindFirstChild("Hand Saber")))
		or char:FindFirstChild("HandSaber", true)
		or char:FindFirstChild("Hand Saber", true)
	return m ~= nil
end

-- Canonical Swinging state so other systems can respect it
local function setSwinging(char: Model, value: boolean)
	local folder = State.getFolder and State.getFolder(char)
	if folder then
		local b = folder:FindFirstChild("Swinging")
		if not b then
			b = Instance.new("BoolValue")
			b.Name = "Swinging"
			b.Parent = folder
		end
		(b :: BoolValue).Value = value
	end
	if State.setSwinging then
		State.setSwinging(char, value) -- StateService should enforce mutual exclusion with Blocking
	end
end

-- For convenience if other code requires it:
local function isSwinging(char: Model): boolean
	local plr = Players:GetPlayerFromCharacter(char)
	if not plr then
		return false
	end
	return (swingLockUntil[plr.UserId] or 0) > os.clock()
end

-- Play the swing (server-side so everyone sees it)
local function playSwing(char: Model, dir: string)
	if Anim.playSwing then
		Anim.playSwing(SET, char, dir)
		dprint("Anim.playSwing", dir)
		return
	end

	-- Fallback (shouldn't hit now that AnimationService owns swings)
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end
	local animator = hum:FindFirstChildOfClass("Animator") or Instance.new("Animator")
	if not animator.Parent then
		animator.Parent = hum
	end
end

-- ===== Remote handler =====
local function onSwing(plr: Player, dir: string)
	-- Basic validation
	if typeof(dir) ~= "string" or not isValidDir(dir) then
		return
	end

	local char = plr.Character
	if not (char and char.Parent) then
		return
	end

	-- Must be equipped + ignited
	if not isHandOut(char) then
		dprint("blocked: not equipped")
		return
	end
	if not (State.getBladeOn and State.getBladeOn(char)) then
		dprint("blocked: blade off")
		return
	end

	-- Respect canonical states: Block OR existing Swing prevents starting a new swing
	if State.isBlocking and State.isBlocking(char) then
		dprint("blocked: currently blocking")
		return
	end
	if State.isSwinging and State.isSwinging(char) then
		dprint("blocked: already swinging")
		return
	end

	local userId = plr.UserId
	local now = os.clock()

	-- If currently locked, ignore (prevents same-frame double-starts)
	if (swingLockUntil[userId] or 0) > now then
		dprint("blocked: in-swing")
		return
	end
	-- If cooling down, ignore
	if (nextOk[userId] or 0) > now then
		dprint("blocked: cooldown")
		return
	end

	-- === Atomic lock claim ===
	swingLockUntil[userId] = math.huge

	-- Determine duration and finalize windows
	local dur = getSwingDuration(dir)
	local lockEnd = now + dur
	swingLockUntil[userId] = lockEnd

	-- Expose canonical Swinging (StateService should clear Blocking due to mutual exclusivity)
	setSwinging(char, true)

	-- Next allowed time is the later of cooldown or swing end (+1-frame buffer)
	nextOk[userId] = math.max(now + COOLDOWN, lockEnd + 1 / 60)

	dprint("swing OK", plr.Name, dir, "dur=", dur)
	playSwing(char, dir)

	-- Clear Swinging when the swing truly ends
	task.delay(dur, function()
		-- Only clear if we're still referring to THIS swing's end (no overlap)
		if (swingLockUntil[userId] or 0) <= os.clock() then
			setSwinging(char, false)
		end
	end)
end

-- ===== Service =====
local SwingService = {}

function SwingService:Init()
	-- NEW API: Use Net.OnServerEvent instead of Ev_Swing:OnServer
	Net.OnServerEvent("Saber_Swing", onSwing)
end

function SwingService:Start() end

-- Optional: let other services query it directly
function SwingService:IsSwinging(char: Model): boolean
	return isSwinging(char)
end

return SwingService
