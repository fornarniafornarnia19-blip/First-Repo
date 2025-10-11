--!strict
export type Reason = "ignite" | "retract" | "holster" | "spawn" | "death"

local StateService = {}
local lastReasonByChar: { [Model]: Reason } = setmetatable({}, { __mode = "k" }) :: any

-- Internals
local function ensureFolder(character: Model): Folder
	local f = character:FindFirstChild("States")
	if f and f:IsA("Folder") then
		return f
	end
	local nf = Instance.new("Folder")
	nf.Name = "States"
	nf.Parent = character
	return nf
end

local function ensureBool(character: Model, name: string): BoolValue
	local f = ensureFolder(character)
	local v = f:FindFirstChild(name)
	if v and v:IsA("BoolValue") then
		return v
	end
	local nv = Instance.new("BoolValue")
	nv.Name, nv.Value, nv.Parent = name, false, f
	return nv
end

local function getBool(character: Model, name: string): boolean
	return ensureBool(character, name).Value
end

local function setBool(character: Model, name: string, value: boolean)
	local b = ensureBool(character, name)
	if b.Value ~= value then
		b.Value = value
	end
end

-- Public base API
function StateService.getFolder(c: Model): Folder
	return ensureFolder(c)
end

function StateService.get(c: Model, n: string): boolean
	return getBool(c, n)
end

function StateService.set(c: Model, n: string, v: boolean)
	setBool(c, n, v)
end

-- Saber on/off
function StateService.setIgnited(c: Model, v: boolean)
	setBool(c, "Ignited", v)
end
function StateService.isIgnited(c: Model): boolean
	return getBool(c, "Ignited")
end
function StateService.setBladeOn(c: Model, v: boolean)
	setBool(c, "BladeOn", v)
end
function StateService.isBladeOn(c: Model): boolean
	return getBool(c, "BladeOn")
end
function StateService.getBladeOn(c: Model): boolean
	return StateService.isBladeOn(c)
end

-- Last reason
function StateService.setLastReason(c: Model, r: Reason)
	lastReasonByChar[c] = r
end
function StateService.getLastReason(c: Model): Reason
	return lastReasonByChar[c] or "spawn"
end
function StateService.setDisignited(c: Model)
	StateService.setIgnited(c, false)
	StateService.setBladeOn(c, false)
end

-- ===== NEW: SlowWalk (active while holding Shift) =====
function StateService.setSlowWalk(c: Model, v: boolean)
	setBool(c, "SlowWalk", v)
end
function StateService.isSlowWalk(c: Model): boolean
	return getBool(c, "SlowWalk")
end
function StateService.getSlowWalk(c: Model): boolean
	return StateService.isSlowWalk(c)
end

-- ===== Mutually-exclusive action states =====
-- Swinging and Blocking cannot be true at the same time.
local function setExclusive(c: Model, a: "Swinging" | "Blocking", v: boolean)
	if a == "Swinging" then
		if v then
			setBool(c, "Swinging", true)
			setBool(c, "Blocking", false)
		else
			setBool(c, "Swinging", false)
		end
	else -- "Blocking"
		if v then
			setBool(c, "Blocking", true)
			setBool(c, "Swinging", false)
		else
			setBool(c, "Blocking", false)
		end
	end
end

-- Swinging
function StateService.setSwinging(c: Model, v: boolean)
	setExclusive(c, "Swinging", v)
end
function StateService.isSwinging(c: Model): boolean
	return getBool(c, "Swinging")
end

-- Blocking
function StateService.setBlocking(c: Model, v: boolean)
	setExclusive(c, "Blocking", v)
end
function StateService.isBlocking(c: Model): boolean
	return getBool(c, "Blocking")
end

return StateService
