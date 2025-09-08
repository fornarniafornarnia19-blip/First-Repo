--!strict
type Reason = "ignite" | "retract" | "holster" | "spawn" | "death"

local Config = require(script.Parent:WaitForChild("Config"))
local State = require(script.Parent:WaitForChild("State"))
local Visuals = require(script.Parent:WaitForChild("Visuals"))

local A = Config.Anim

-- per-character animation state (weak keys)
local igniteTrackByChar: { [Model]: AnimationTrack } = {}
setmetatable(igniteTrackByChar, { __mode = "k" })

local animTokenByChar: { [Model]: number } = {}
setmetatable(animTokenByChar, { __mode = "k" })

local AnimToggle = {}

function AnimToggle.stopIgniteAnim(character: Model)
	animTokenByChar[character] = (animTokenByChar[character] or 0) + 1
	local prev = igniteTrackByChar[character]
	if prev then
		igniteTrackByChar[character] = nil
		pcall(function()
			prev:Stop()
		end)
		pcall(function()
			prev:Destroy()
		end)
	end
end

function AnimToggle.playIgniteAndToggle(character: Model, wantOn: boolean)
	local hum = character:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end

	-- Animator: make non-nil for the typechecker
	local animatorMaybe = hum:FindFirstChildOfClass("Animator") :: Animator?
	if not animatorMaybe then
		local newAnimator = Instance.new("Animator")
		newAnimator.Parent = hum
		animatorMaybe = newAnimator
	end
	local animator: Animator = animatorMaybe :: Animator

	AnimToggle.stopIgniteAnim(character)

	local myToken = (animTokenByChar[character] or 0) + 1
	animTokenByChar[character] = myToken

	local anim: Animation = wantOn and A.IgniteAnim or (A.RetractAnim or A.IgniteAnim) :: Animation
	local speed: number = wantOn and (A.IgniteSpeed or 1) or (A.RetractSpeed or 1)
	local targetDur: number? = wantOn and A.IgniteDuration or A.RetractDuration
	local markerName: string = wantOn and A.MarkerIgnite or A.MarkerRetract

	local track = animator:LoadAnimation(anim)
	track.Priority = Enum.AnimationPriority.Action
	track.Looped = false
	igniteTrackByChar[character] = track

	local toggled = false
	local sawMarker = false
	local conns: { RBXScriptConnection } = {}

	local function doToggleOnce()
		if toggled or animTokenByChar[character] ~= myToken then
			return
		end
		toggled = true
		State.setBladeOn(character, wantOn)
		local reason: Reason = if wantOn then "ignite" else "retract"
		State.setLastReason(character, reason)
		Visuals.apply(character)
	end

	-- 1) Animation Event (preferred)
	table.insert(
		conns,
		track:GetMarkerReachedSignal(markerName):Connect(function()
			if animTokenByChar[character] ~= myToken then
				return
			end
			sawMarker = true
			doToggleOnce()
		end)
	)

	-- 2) Named keyframe fallback
	table.insert(
		conns,
		track.KeyframeReached:Connect(function(name)
			if animTokenByChar[character] ~= myToken then
				return
			end
			if name == markerName then
				sawMarker = true
				doToggleOnce()
			end
		end)
	)

	-- Cleanup / finalization
	table.insert(
		conns,
		track.Stopped:Connect(function()
			if animTokenByChar[character] ~= myToken then
				return
			end
			for _, c in ipairs(conns) do
				pcall(function()
					c:Disconnect()
				end)
			end
			if igniteTrackByChar[character] == track then
				igniteTrackByChar[character] = nil
			end
			if not toggled then
				doToggleOnce()
			end
			pcall(function()
				track:Destroy()
			end)
		end)
	)

	-- Start immediately; correct speed when Length is known.
	track:Play(0.07, 1.0, speed)

	if targetDur and targetDur > 0 then
		local function applyDur(): boolean
			if track.Length and track.Length > 0 then
				track:AdjustSpeed(track.Length / targetDur)
				return true
			end
			return false
		end
		if not applyDur() then
			local lenConn: RBXScriptConnection?
			lenConn = track:GetPropertyChangedSignal("Length"):Connect(function()
				if applyDur() and lenConn then
					lenConn:Disconnect()
				end
			end)
		end
	end

	-- Safety fuse: don't undercut legit events.
	local fuseDelay = math.clamp((targetDur and targetDur * 0.65) or 0.5, 0.25, 1.2)
	task.delay(fuseDelay, function()
		if animTokenByChar[character] ~= myToken then
			return
		end
		if not toggled and not sawMarker then
			doToggleOnce()
		end
	end)
end

return AnimToggle
