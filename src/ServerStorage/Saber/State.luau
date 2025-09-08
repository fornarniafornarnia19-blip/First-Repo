--!strict
type Reason = "ignite" | "retract" | "holster" | "spawn" | "death"

local State = {}

local lastReasonByChar: { [Model]: Reason } = setmetatable({}, { __mode = "k" }) :: any

function State.getFolder(character: Model): Folder
	local f = character:FindFirstChild("States")
	if f and f:IsA("Folder") then
		return f
	end
	local nf = Instance.new("Folder")
	nf.Name = "States"
	nf.Parent = character
	return nf
end

local function getBool(character: Model, name: string): BoolValue
	local f = State.getFolder(character)
	local v = f:FindFirstChild(name)
	if v and v:IsA("BoolValue") then
		return v
	end
	local nv = Instance.new("BoolValue")
	nv.Name = name
	nv.Value = false
	nv.Parent = f
	return nv
end

function State.getBladeOn(character: Model): boolean
	return getBool(character, "BladeOn").Value
end

function State.setBladeOn(character: Model, v: boolean)
	local bv = getBool(character, "BladeOn")
	if bv.Value ~= v then
		bv.Value = v
	end
end

function State.setLastReason(character: Model, r: Reason)
	lastReasonByChar[character] = r
end

function State.getLastReason(character: Model): Reason
	return lastReasonByChar[character] or "spawn"
end

return State
