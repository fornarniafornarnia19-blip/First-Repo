--!strict
-- StarterPlayerScripts/Controllers/VFXController.client.luau
local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

-- NetUtil wrapper - FIXED PATH
local Net = require(RS:WaitForChild("Shared"):WaitForChild("NetUtil"))

type BroadcastFn = (uid: number, equipped: boolean, ignited: boolean) -> ()

local VFXController = {}
local started = false

-- ===== Small helpers =====
local function cosmeticsFolder(c: Model): Instance
	return c:FindFirstChild("Cosmetics") or c:FindFirstChild("cosmetics") or c
end

local function findHand(c: Model): Model?
	local cos = cosmeticsFolder(c)
	local m = cos:FindFirstChild("HandSaber") or c:FindFirstChild("HandSaber", true)
	return (m and m:IsA("Model")) and m or nil
end

local function findHip(c: Model): Model?
	local cos = cosmeticsFolder(c)
	local m = cos:FindFirstChild("HipHilt") or c:FindFirstChild("HipHilt", true)
	return (m and m:IsA("Model")) and m or nil
end

local function setBladeVisible(m: Model?, on: boolean)
	if not m then
		return
	end
	local b = m:FindFirstChild("Blade", true)
	if b and b:IsA("BasePart") then
		b.Transparency = on and 0 or 1
		b.CanCollide = false
	end
end

-- Best-effort show (handles late-spawn parts)
local function showWithRetry(character: Model, equipped: boolean, ignited: boolean)
	local model = equipped and findHand(character) or findHip(character)
	if model then
		setBladeVisible(model, ignited)
	else
		-- part not streamed yet: try again shortly
		task.delay(0.1, function()
			local m = equipped and findHand(character) or findHip(character)
			setBladeVisible(m, ignited)
		end)
	end
end

-- ===== Public API =====
function VFXController:Init()
	-- nothing else to init; remotes are bound in Start
end

function VFXController:Start()
	if started then
		return
	end
	started = true

	-- NEW API: Server -> client broadcast: flip cosmetic blade visibility for that player
	Net.OnClientEvent("Saber_BroadcastState", function(uid: number, equipped: boolean, ignited: boolean)
		local plr = Players:GetPlayerByUserId(uid)
		local char = plr and plr.Character
		if not char then
			return
		end
		showWithRetry(char, equipped, ignited)
	end)

	-- Keep local player up to date after respawn
	LocalPlayer.CharacterAdded:Connect(function(char)
		-- No direct state here; the server will broadcast on equip/ignite.
		-- This just ensures late parts will show when the broadcast lands.
		task.defer(function()
			-- noop; placeholder in case you want to pre-hide both blades on spawn
			setBladeVisible(findHand(char), false)
			setBladeVisible(findHip(char), false)
		end)
	end)
end

-- Call these from your combat/input code:
function VFXController:SetSwinging(isSwinging: boolean)
	-- NEW API: Replicates to server so TrailVFXService can enable/disable Trail on the server.
	Net.FireServer("Saber_Swing", isSwinging == true)
end

return VFXController
