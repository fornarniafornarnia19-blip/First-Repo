--!strict
-- ServerScriptService/Services/AvatarService.luau
-- Enforces classic R15 scale for all players.

local Players = game:GetService("Players")

-- === Config (classic defaults) ===
local SCALE = {
	BodyHeightScale = 1,
	BodyWidthScale = 1,
	BodyDepthScale = 1,
	HeadScale = 1,
	BodyTypeScale = 0,
	BodyProportionScale = 0,
}

local AvatarService = {}

-- Apply scale via HumanoidDescription (authoritative & safe)
local function applyDescription(hum: Humanoid)
	local desc: HumanoidDescription
	local ok, current = pcall(function()
		return hum:GetAppliedDescription()
	end)
	if ok and current then
		desc = current
	else
		desc = Instance.new("HumanoidDescription")
	end

	desc.HeightScale = SCALE.BodyHeightScale
	desc.WidthScale = SCALE.BodyWidthScale
	desc.DepthScale = SCALE.BodyDepthScale
	desc.HeadScale = SCALE.HeadScale
	desc.BodyTypeScale = SCALE.BodyTypeScale
	desc.ProportionScale = SCALE.BodyProportionScale

	pcall(function()
		hum:ApplyDescription(desc)
	end)
end

-- Pin the NumberValue scale objects under the Humanoid to the configured values
local function pinScaleNumberValues(hum: Humanoid)
	local targets: { string } = {
		"BodyHeightScale",
		"BodyWidthScale",
		"BodyDepthScale",
		"HeadScale",
		"BodyTypeScale",
		"BodyProportionScale",
	}

	-- helper to enforce one value and hook its Changed event
	local function enforce(name: string)
		local obj = hum:FindFirstChild(name)
		if not obj then
			return
		end
		if obj:IsA("NumberValue") then
			if obj.Value ~= (SCALE :: any)[name] then
				obj.Value = (SCALE :: any)[name]
			end
			obj.Changed:Connect(function()
				if obj.Value ~= (SCALE :: any)[name] then
					obj.Value = (SCALE :: any)[name]
				end
			end)
		end
	end

	for _, n in ipairs(targets) do
		enforce(n)
	end

	-- Also watch for late-created NumberValues and clamp them
	hum.ChildAdded:Connect(function(child)
		if child:IsA("NumberValue") and (SCALE :: any)[child.Name] ~= nil then
			local target = (SCALE :: any)[child.Name]
			if child.Value ~= target then
				child.Value = target
			end
			child.Changed:Connect(function()
				if child.Value ~= target then
					child.Value = target
				end
			end)
		end
	end)
end

local function enforceForCharacter(char: Model)
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end

	-- First pass: apply description (handles packages/Rthro/etc)
	applyDescription(hum)

	-- Second pass: pin live NumberValues so runtime changes are reverted
	pinScaleNumberValues(hum)
end

local function onPlayer(plr: Player)
	-- Handle already-spawned
	if plr.Character then
		enforceForCharacter(plr.Character)
	end

	-- Every respawn
	plr.CharacterAppearanceLoaded:Connect(function(char)
		enforceForCharacter(char)
	end)
end

function AvatarService:Init()
	-- no-op
end

function AvatarService:Start()
	-- Existing players (e.g., play solo in Studio)
	for _, p in ipairs(Players:GetPlayers()) do
		onPlayer(p)
	end
	Players.PlayerAdded:Connect(onPlayer)
end

return AvatarService
