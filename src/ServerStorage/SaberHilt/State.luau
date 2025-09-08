--!strict
local State = {}

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

function State.get(character: Model, name: string): boolean
	return getBool(character, name).Value
end

function State.set(character: Model, name: string, v: boolean)
	local bv = getBool(character, name)
	if bv.Value ~= v then
		bv.Value = v
	end
end

function State.setIgnited(character: Model, v: boolean)
	State.set(character, "Ignited", v)
end
function State.setBladeOn(character: Model, v: boolean)
	State.set(character, "BladeOn", v)
end
function State.isIgnited(character: Model): boolean
	return State.get(character, "Ignited")
end
function State.isBladeOn(character: Model): boolean
	return State.get(character, "BladeOn")
end

return State
