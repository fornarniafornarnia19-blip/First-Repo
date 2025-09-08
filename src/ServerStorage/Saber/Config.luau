--!strict
-- ServerStorage/SaberHilt/Config.luau  (only wraps animation config now)

local ServerStorage = game:GetService("ServerStorage")

-- Your existing animation config module
local AnimModule = ServerStorage:WaitForChild("SaberAnimConfigs") :: ModuleScript
local AnimCfg = require(AnimModule) :: any

-- Build the Animation objects
local IgniteAnim: Animation, RetractAnim: Animation?, _ = AnimCfg.buildAnimations()

-- Marker names (fallbacks kept sane)
local MARK_IGNITE: string = (AnimCfg.Markers and AnimCfg.Markers.Ignite) or "Ignite"
local MARK_RETRACT: string = (AnimCfg.Markers and (AnimCfg.Markers.Retract or AnimCfg.Markers.Ignite)) or "Ignite"

-- Optional timing from AnimCfg if you expose it there; defaults are safe.
local A: any = AnimCfg.Animation or AnimCfg.Timing or {}

return {
	Anim = {
		IgniteAnim = IgniteAnim,
		RetractAnim = RetractAnim :: Animation?,

		MarkerIgnite = MARK_IGNITE,
		MarkerRetract = MARK_RETRACT,

		IgniteSpeed = A.IgniteSpeed, -- nil = use duration or 1
		IgniteDuration = A.IgniteDuration or 0.40, -- seconds
		RetractSpeed = A.RetractSpeed,
		RetractDuration = A.RetractDuration or 0.40,

		-- Optional extras if you want to configure these in AnimCfg:
		FadeIn = A.FadeIn, -- used by track:Play(FadeIn, ...)
		FuseRatio = A.FuseRatio, -- if you keep the safety fuse
		FuseMin = A.FuseMin,
		FuseMax = A.FuseMax,
	},
	-- No Blade section here anymore; Visuals owns blade config.
}
