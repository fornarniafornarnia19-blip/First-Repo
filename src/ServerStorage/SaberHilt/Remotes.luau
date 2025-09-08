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
	Toggle = ensure("SaberToggle", "RemoteEvent") :: RemoteEvent,
	Confirm = ensure("SaberConfirm", "RemoteEvent") :: RemoteEvent,
	NoTool = (function()
		local inst = RS:FindFirstChild("ServerSaber_NoTool")
		if inst and inst:IsA("BindableEvent") then
			return inst
		end
		local be = Instance.new("BindableEvent")
		be.Name = "ServerSaber_NoTool"
		be.Parent = RS
		return be
	end)() :: BindableEvent,
}
