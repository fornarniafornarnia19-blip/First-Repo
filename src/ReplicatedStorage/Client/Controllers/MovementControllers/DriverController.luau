--!strict
-- ReplicatedStorage/Client/Controllers/DriverController

-- DriverController
-- Enforces that LowerTorso follows the "Driver" part with highest priority,
-- without disabling the root Motor6D. We solve and write Root.Transform each frame
-- so that the final world CFrame of LowerTorso matches our desired target.
-- This makes drift impossible (driver wins).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

export type Rig = {
	Character: Model,
	Humanoid: Humanoid,
	HRP: BasePart,
	LowerTorso: BasePart,
	Root: Motor6D, -- HRP (Part0) ↔ LowerTorso (Part1)
	Driver: BasePart,
}

local DriverController = {}

-- ===== Config =====
DriverController.Config = {
	LOG = true,
	LOG_PREFIX = "[PelvisFollow:C0]",

	-- Keep Y from LT (true) or copy Y from Driver (false).
	LOCK_XZ_ONLY = true,

	-- Optionally align yaw to the Driver (only if you want heading lock).
	ALIGN_YAW_TO_DRIVER = false,

	-- Tiny tolerance for saying "already aligned".
	ALIGN_EPS = 1e-5,
}

-- ===== Internal =====
local LP = Players.LocalPlayer
local _rig: Rig? = nil
local _conns: { RBXScriptConnection } = {}

local function LOG(s: string)
	if DriverController.Config.LOG then
		print(s)
	end
end

local function clearConnections()
	for _, c in ipairs(_conns) do
		c:Disconnect()
	end
	table.clear(_conns)
end

local function findRootMotor(hrp: BasePart, lt: BasePart): Motor6D?
	for _, ch in ipairs(hrp:GetChildren()) do
		if ch:IsA("Motor6D") and ch.Part0 == hrp and ch.Part1 == lt then
			return ch
		end
	end
	return nil
end

local function buildRig(char: Model): Rig?
	local hum = char:FindFirstChildOfClass("Humanoid") :: Humanoid?
	local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local lt = char:FindFirstChild("LowerTorso") :: BasePart?
	if not (hum and hrp and lt) then
		return nil
	end

	local root = findRootMotor(hrp, lt)
	if not root then
		return nil
	end

	-- "Driver" can be a sibling under character or under HRP; support both.
	local driver = (char:FindFirstChild("Driver") :: BasePart?) or (hrp:FindFirstChild("Driver") :: BasePart?)
	if not driver then
		return nil
	end

	return {
		Character = char,
		Humanoid = hum,
		HRP = hrp,
		LowerTorso = lt,
		Root = root,
		Driver = driver,
	}
end

-- Helpers
local function vec2(x: number, z: number): string
	return ("(%.3f,%.3f)"):format(x, z)
end

local function planarYaw(cf: CFrame): CFrame
	-- remove pitch/roll, keep yaw only
	local _, y, _ = cf:ToOrientation()
	return CFrame.fromOrientation(0, y, 0)
end

-- Compute current error in HRP space (Driver - LT) on X/Z.
local function errorXZ(r: Rig)
	local hrpCF = r.HRP.CFrame
	local ltRel = hrpCF:PointToObjectSpace(r.LowerTorso.Position)
	local drvRel = hrpCF:PointToObjectSpace(r.Driver.Position)
	local ex = drvRel.X - ltRel.X
	local ez = drvRel.Z - ltRel.Z
	local aligned = math.abs(ex) <= DriverController.Config.ALIGN_EPS
		and math.abs(ez) <= DriverController.Config.ALIGN_EPS
	return ex, ez, aligned, drvRel, ltRel
end

-- We want: Part1_world = HRP * C0 * Transform * C1^{-1}
-- Solve Transform that yields our desired Part1_world while keeping C0/C1 unchanged:
--   Transform = HRP^{-1} * desiredPart1 * C1 * C0^{-1}
local function solveTransformForDesiredLT(r: Rig, desiredLTWorld: CFrame): CFrame
	return r.HRP.CFrame:Inverse() * desiredLTWorld * r.Root.C1 * r.Root.C0:Inverse()
end

local function desiredLowerTorsoWorldCF(r: Rig): CFrame
	local driverCF = r.Driver.CFrame
	local ltCF = r.LowerTorso.CFrame

	local pos: Vector3
	if DriverController.Config.LOCK_XZ_ONLY then
		pos = Vector3.new(driverCF.Position.X, ltCF.Position.Y, driverCF.Position.Z)
	else
		pos = driverCF.Position
	end

	local rot: CFrame
	if DriverController.Config.ALIGN_YAW_TO_DRIVER then
		rot = planarYaw(driverCF)
	else
		-- preserve LT rotation
		rot = ltCF - ltCF.Position
	end

	return CFrame.new(pos) * rot
end

local function applySolve(tag: string)
	local r = _rig
	if not r then
		return
	end
	if r.Humanoid.Health <= 0 then
		return
	end

	-- Compute error for logging/short-circuit
	local ex, ez, aligned, drvRel, ltRel = errorXZ(r)
	local desiredLT = desiredLowerTorsoWorldCF(r)

	-- If already aligned (within eps), zero the transform so we don't fight animations unnecessarily.
	if aligned then
		-- Only clear if non-identity to avoid redundant writes
		if r.Root.Transform ~= CFrame.new() then
			r.Root.Transform = CFrame.new()
		end
		LOG(
			("%s drvXZ=%s ltXZ=%s err=%s aligned=true lock=%s A|t|=0.000 solved=OK:true outXZ=%s  (%s)"):format(
				DriverController.Config.LOG_PREFIX,
				vec2(drvRel.X, drvRel.Z),
				vec2(ltRel.X, ltRel.Z),
				vec2(ex, ez),
				vec2(0, 0),
				vec2(0, 0),
				tag
			)
		)
		return
	end

	-- Solve exact Transform that forces LT to the desired world CFrame.
	local newTransform = solveTransformForDesiredLT(r, desiredLT)
	r.Root.Transform = newTransform

	-- For continuity with your logs, report the amount of transform we just applied in X/Z space.
	-- (Project HRP * C0 * Transform * C1^{-1} position deltas back into HRP space.)
	local forcedLT = r.HRP.CFrame * r.Root.C0 * r.Root.Transform * r.Root.C1:Inverse()
	local forcedRel = r.HRP.CFrame:PointToObjectSpace(forcedLT.Position)
	local outDx = forcedRel.X - ltRel.X
	local outDz = forcedRel.Z - ltRel.Z

	LOG(
		("%s drvXZ=%s ltXZ=%s err=%s aligned=false lock=%s A|t|=0.000 solved=OK:false outXZ=%s  (%s)"):format(
			DriverController.Config.LOG_PREFIX,
			vec2(drvRel.X, drvRel.Z),
			vec2(ltRel.X, ltRel.Z),
			vec2(ex, ez),
			vec2(0, 0),
			vec2(outDx, outDz),
			tag
		)
	)
end

local function bind()
	-- Heartbeat: physics complete; ensure transform persists
	table.insert(
		_conns,
		RunService.Heartbeat:Connect(function()
			applySolve("Heartbeat")
		end)
	)

	-- RenderStep: apply as LATE as possible so we win over Animator writes.
	if RunService:IsClient() then
		table.insert(
			_conns,
			RunService:BindToRenderStep("DriverController_PelvisFollow_LAST", Enum.RenderPriority.Last.Value, function()
				applySolve("RenderStep")
			end)
		)
	end
end

local function unbind()
	for i = #_conns, 1, -1 do
		_conns[i]:Disconnect()
		table.remove(_conns, i)
	end
	if RunService:IsClient() then
		pcall(function()
			RunService:UnbindFromRenderStep("DriverController_PelvisFollow_LAST")
		end)
	end
end

local function onCharacter(char: Model)
	unbind()
	_rig = nil

	local rig = buildRig(char)
	if rig then
		_rig = rig
		bind()
	else
		-- If pieces aren’t ready yet, retry next tick
		task.defer(function()
			local rig2 = buildRig(char)
			if rig2 then
				_rig = rig2
				bind()
			end
		end)
	end
end

-- ========= Boot API =========
function DriverController:Init()
	local char = LP.Character or LP.CharacterAdded:Wait()
	onCharacter(char)

	table.insert(_conns, LP.CharacterAdded:Connect(onCharacter))
	table.insert(
		_conns,
		LP.CharacterRemoving:Connect(function()
			unbind()
			_rig = nil
		end)
	)
end

function DriverController:Start()
	-- No-op; all work is driven by Heartbeat/RenderStep.
end

return DriverController
