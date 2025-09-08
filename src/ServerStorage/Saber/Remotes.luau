--!strict
local RS = game:GetService("ReplicatedStorage")

local function ensure<T>(name: string, className: string): T
	local inst = RS:FindFirstChild(name)
	if inst and inst.ClassName == className then
		return inst :: any
	end
	local new = Instance.new(className)
	new.Name = name
	new.Parent = RS
	return new :: any
end

return {
	Ignite = ensure("SaberIgnite", "RemoteEvent") :: RemoteEvent,
}
