--!strict
-- Handles Trail creation + swing binding (server-side).
-- Decoupled so VFXService stays lean.

-- ===== Types (duplicated minimal set to avoid circular deps) =====
export type BladeNames = {
	TrailName: string?,
}
export type BladeAppearance = { GlowColor: Color3, GlowWidth: number }
export type Timings = {
	TrailLifetime: number?, -- default 0.12
	TrailMinLength: number?, -- default 0.1
}
export type StateHooks = {
	isSwinging: ((character: Model) -> boolean)?,
	getStateFolder: ((character: Model) -> Folder)?,
}

local TrailVFXService = {}

-- Hooks + per-character connection store
local _hooks: StateHooks = {}
local _swingConns: { [Model]: RBXScriptConnection } = setmetatable({}, { __mode = "k" }) :: any

function TrailVFXService.setStateHooks(h: StateHooks)
	_hooks = h or {}
end

-- ===== Internals =====
local function _getStatesFolder(character: Model): Folder?
	if _hooks.getStateFolder then
		local ok, f = pcall(function()
			return _hooks.getStateFolder and _hooks.getStateFolder(character) or nil
		end)
		if ok and f and f:IsA("Folder") then
			return f
		end
	end
	local f = character:FindFirstChild("States")
	return (f and f:IsA("Folder")) and f or nil
end

local function _isSwinging(character: Model): boolean
	if _hooks.isSwinging then
		local ok, v = pcall(function()
			return _hooks.isSwinging and _hooks.isSwinging(character) or false
		end)
		if ok and typeof(v) == "boolean" then
			return v
		end
	end
	local f = _getStatesFolder(character)
	if not f then
		return false
	end
	local b = f:FindFirstChild("Swinging")
	return (b and b:IsA("BoolValue") and (b :: BoolValue).Value) == true
end

local function _ns(keys: { NumberSequenceKeypoint }): NumberSequence
	return NumberSequence.new(keys)
end

local function _ensureTrail(
	handle: BasePart,
	socket: Attachment,
	tip: Attachment,
	names: BladeNames,
	app: BladeAppearance,
	t: Timings
): Trail?
	local ok, trailOrErr = pcall(function()
		local trailName = names.TrailName or "BladeTrail"
		local existing = handle:FindFirstChild(trailName)
		local tr: Trail
		if existing and existing:IsA("Trail") then
			tr = existing
		else
			tr = Instance.new("Trail")
			tr.Name = trailName
			tr.Parent = handle
		end

		tr.Attachment0 = socket
		tr.Attachment1 = tip
		tr.Color = ColorSequence.new(app.GlowColor)

		local baseWidth = math.max(0.1, app.GlowWidth * 0.65)
		tr.Transparency = _ns({
			NumberSequenceKeypoint.new(0, 0.2),
			NumberSequenceKeypoint.new(1, 1.0),
		})
		tr.WidthScale = _ns({
			NumberSequenceKeypoint.new(0, baseWidth),
			NumberSequenceKeypoint.new(1, math.max(0.05, baseWidth * 0.6)),
		})

		tr.Lifetime = t.TrailLifetime or 0.12
		tr.MinLength = t.TrailMinLength or 0.1
		tr.LightEmission = 1
		tr.Enabled = false
		return tr
	end)

	if not ok then
		warn("[TrailVFXService] Trail creation skipped: ", trailOrErr)
		return nil
	end
	return trailOrErr :: Trail
end

local function _bindSwingToggle(character: Model, trail: Trail?)
	if not trail then
		return
	end

	-- Disconnect previous
	local prev = _swingConns[character]
	if prev then
		pcall(function()
			prev:Disconnect()
		end)
		_swingConns[character] = nil
	end

	-- Apply now
	trail.Enabled = _isSwinging(character)

	-- Subscribe to BoolValue if present
	local f = _getStatesFolder(character)
	if not f then
		return
	end
	local b = f:FindFirstChild("Swinging")
	if not (b and b:IsA("BoolValue")) then
		return
	end

	_swingConns[character] = (b :: BoolValue).Changed:Connect(function()
		trail.Enabled = (b :: BoolValue).Value == true
	end)
end

-- ===== Public API =====

-- Create/ensure the Trail and bind it to the character’s Swinging state.
function TrailVFXService.ensureAndBind(
	handle: BasePart,
	socket: Attachment,
	tip: Attachment,
	names: BladeNames,
	app: BladeAppearance,
	t: Timings,
	character: Model
): Trail?
	local tr = _ensureTrail(handle, socket, tip, names, app, t)
	_bindSwingToggle(character, tr)
	return tr
end

-- Remove the per-character listener (call when tearing down blade).
function TrailVFXService.drop(character: Model)
	local prev = _swingConns[character]
	if prev then
		pcall(function()
			prev:Disconnect()
		end)
		_swingConns[character] = nil
	end
end

-- Optional: remove the actual Trail instance off the handle.
function TrailVFXService.destroyTrail(handle: BasePart, trailName: string?): boolean
	local name = trailName or "BladeTrail"
	local obj = handle:FindFirstChild(name)
	if obj and obj:IsA("Trail") then
		obj:Destroy()
		return true
	end
	return false
end

return TrailVFXService
