--!strict
local Players = game:GetService("Players")

local DriverService = {}
DriverService.__index = DriverService

-- === Config ===
local DRIVER_PART_NAME = "PelvisDriver"
local DRIVER_JOINT_NAME = "PelvisDriver"

local PART_SIZE = Vector3.new(2, 0.4, 1)
local PART_TRANSPARENCY = 0 -- requested
local PART_COLOR = Color3.fromRGB(255, 0, 0)
local PART_MATERIAL = Enum.Material.Neon
local Y_OFFSET_ABOVE_HRP = 4.0 -- studs above HRP (visual only)

-- Build or return existing driver joint/part for this character
local function ensureDriver(character: Model): (Motor6D?, BasePart?)
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return nil, nil
	end

	-- Already present?
	local existing = hrp:FindFirstChild(DRIVER_JOINT_NAME)
	if existing and existing:IsA("Motor6D") then
		local ex = existing :: Motor6D
		return ex, ex.Part1
	end

	-- Make the part
	local part = Instance.new("Part")
	part.Name = DRIVER_PART_NAME
	part.Size = PART_SIZE
	part.Transparency = PART_TRANSPARENCY
	part.Color = PART_COLOR
	part.Material = PART_MATERIAL
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = false
	part.Anchored = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = character

	-- Park it above HRP initially (visual; driver math reads only rotation)
	part.CFrame = hrp.CFrame * CFrame.new(0, Y_OFFSET_ABOVE_HRP, 0)

	-- Parallel Motor6D off HRP (NOT in spine chain)
	local joint = Instance.new("Motor6D")
	joint.Name = DRIVER_JOINT_NAME
	joint.Part0 = hrp
	joint.Part1 = part
	-- Keep rest offsets simple/identity so imported translation doesn't stack
	joint.C0 = CFrame.new(0, Y_OFFSET_ABOVE_HRP, 0)
	joint.C1 = CFrame.new()
	joint.Parent = hrp

	return joint, part
end

function DriverService:Init(_services: { [string]: any }?)
	-- nothing to wire yet
end

function DriverService:Start()
	-- Hook existing players
	for _, plr in ipairs(Players:GetPlayers()) do
		plr.CharacterAdded:Connect(function(char: Model)
			char:WaitForChild("HumanoidRootPart", 10)
			ensureDriver(char)
		end)
		if plr.Character then
			task.defer(function()
				plr.Character:WaitForChild("HumanoidRootPart", 10)
				ensureDriver(plr.Character)
			end)
		end
	end

	-- New players
	Players.PlayerAdded:Connect(function(plr: Player)
		plr.CharacterAdded:Connect(function(char: Model)
			char:WaitForChild("HumanoidRootPart", 10)
			ensureDriver(char)
		end)
	end)
end

return setmetatable({}, DriverService)
