local Run = game:GetService("RunService")
local Players = game:GetService("Players")
local LP = Players.LocalPlayer

local HAND_MODEL = "HandSaber"
local BEAM_NAMES = { "BladeCore", "BladeGlow" }

-- texture scroll (0 = no movement)
local SCROLL = 0 -- studs/sec

-- % wobble around the beam's own width (not hardcoded)
local WOBBLE = {
	BladeCore = { pct1 = 0.05, f1 = 60, pct2 = 0.025, f2 = 93 }, -- ±5% + ±2.5%
	BladeGlow = { pct1 = 0.03, f1 = 40 }, -- ±3%
}

local prevCF: CFrame? = nil
-- weak map: Beam -> baseline width
local baseWidth: { [Beam]: number } = {}
setmetatable(baseWidth, { __mode = "k" })

local function getBeams(char: Model)
	local hand = char and char:FindFirstChild(HAND_MODEL, true)
	local handle = hand and (hand.PrimaryPart or hand:FindFirstChild("Handle", true))
	if not (handle and handle:IsA("BasePart")) then
		return nil, {}
	end
	local beams = {}
	for _, n in ipairs(BEAM_NAMES) do
		local b = handle:FindFirstChild(n)
		if b and b:IsA("Beam") and b.Enabled then
			table.insert(beams, b)
		end
	end
	return handle, beams
end

Run.RenderStepped:Connect(function(dt)
	local char = LP.Character
	if not char then
		prevCF = nil
		return
	end

	local handle, beams = getBeams(char)
	if not handle or #beams == 0 then
		prevCF = nil
		return
	end

	local t = os.clock()

	for _, b in ipairs(beams) do
		-- capture this beam's baseline once (from server or initial value)
		if baseWidth[b] == nil then
			baseWidth[b] = b.Width0
		end
		local base = baseWidth[b]

		-- relative wobble by name
		local cfg = WOBBLE[b.Name]
		if cfg then
			local w = base
			if cfg.pct1 and cfg.f1 then
				w += base * cfg.pct1 * math.sin(t * cfg.f1)
			end
			if cfg.pct2 and cfg.f2 then
				w += base * cfg.pct2 * math.sin(t * cfg.f2)
			end
			b.Width0, b.Width1 = w, w
		end

		-- texture motion
		if b.Texture ~= "" then
			b.TextureSpeed = SCROLL
		end
	end

	prevCF = handle.CFrame
end)
