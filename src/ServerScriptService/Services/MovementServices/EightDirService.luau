-- EightDirService (server)
-- Disables default Animate on spawn. Leave movement math/logic to the client controller.

local Players = game:GetService("Players")

local EightDirService = {}

local function killDefaultAnimate(character)
	local animate = character:FindFirstChild("Animate")
	if animate and animate:IsA("LocalScript") then
		-- Disable; don’t destroy, keeps it easy to re-enable if needed.
		animate.Disabled = true
	end
end

function EightDirService.init()
	-- Backfill existing players
	for _, plr in ipairs(Players:GetPlayers()) do
		plr.CharacterAdded:Connect(function(char)
			-- Give rig a moment to populate
			task.defer(function()
				killDefaultAnimate(char)
			end)
		end)
		if plr.Character then
			task.defer(function()
				killDefaultAnimate(plr.Character)
			end)
		end
	end

	Players.PlayerAdded:Connect(function(plr)
		plr.CharacterAdded:Connect(function(char)
			task.defer(function()
				killDefaultAnimate(char)
			end)
		end)
	end)
end

return EightDirService
