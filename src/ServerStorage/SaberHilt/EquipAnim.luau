--!strict
local ServerStorage = game:GetService("ServerStorage")

local Remotes = require(script.Parent:WaitForChild("Remotes"))
local State = require(script.Parent:WaitForChild("State"))
local NoTool = require(script.Parent:WaitForChild("NoTool"))
local Rig = require(script.Parent:WaitForChild("Rig"))

-- Anim config
local AnimModule = ServerStorage:WaitForChild("SaberAnimConfigs") :: ModuleScript
local AnimCfg = require(AnimModule) :: any
local _Ignite: Animation, _Retract: Animation?, EquipAnimation: Animation = AnimCfg.buildAnimations()
local MARK_SWAP_TO_HAND: string = AnimCfg.Markers.SwapToHand
local MARK_SWAP_TO_HIP: string = AnimCfg.Markers.SwapToHip

-- weak map with optional tracks
local currentTrackByChar: { [Model]: AnimationTrack? } = setmetatable({}, { __mode = "k" }) :: any

local EquipAnim = {}

function EquipAnim.isPlaying(character: Model): boolean
	return currentTrackByChar[character] ~= nil
end

function EquipAnim.stop(character: Model)
	local t = currentTrackByChar[character]
	if t then
		pcall(function()
			(t :: AnimationTrack):Stop()
		end)
		pcall(function()
			(t :: AnimationTrack):Destroy()
		end)
	end
	currentTrackByChar[character] = nil
end

-- mode: "SwapToHand" | "SwapToHip"
function EquipAnim.play(character: Model, mode: string, player: Player)
	local hum = character:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end

	local animatorMaybe: Animator? = hum:FindFirstChildOfClass("Animator")
	if not animatorMaybe then
		local newAnimator = Instance.new("Animator")
		newAnimator.Parent = hum
		animatorMaybe = newAnimator
	end
	local animator: Animator = animatorMaybe :: Animator

	EquipAnim.stop(character)

	local track = animator:LoadAnimation(EquipAnimation)
	track.Priority = Enum.AnimationPriority.Action
	track.Looped = false
	currentTrackByChar[character] = track

	local targetMarker = (mode == "SwapToHip") and MARK_SWAP_TO_HIP or MARK_SWAP_TO_HAND
	local conns: { RBXScriptConnection } = {}
	local applied = false

	local function applyFinal()
		if applied then
			return
		end
		applied = true
		if mode == "SwapToHand" then
			Rig.destroyHip(character)
			Rig.ensureHand(character)
			State.setIgnited(character, false)
		else
			Rig.destroyHand(character)
			Rig.ensureHip(character)
			NoTool.setDisignited(character)
		end
	end

	table.insert(
		conns,
		track:GetMarkerReachedSignal(targetMarker):Connect(function()
			applyFinal()
		end)
	)

	table.insert(
		conns,
		track.Stopped:Connect(function()
			-- enforce final state even if the marker never fired
			applyFinal()
			for _, c in ipairs(conns) do
				pcall(function()
					c:Disconnect()
				end)
			end
			if currentTrackByChar[character] == track then
				currentTrackByChar[character] = nil
			end
			pcall(function()
				track:Destroy()
			end)
			Remotes.Confirm:FireClient(player)
		end)
	)

	track:Play()
end

return EquipAnim
