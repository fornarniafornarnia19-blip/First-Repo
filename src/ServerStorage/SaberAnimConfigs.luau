--!strict
-- ServerStorage/SaberAnimConfigs.luau
local ContentProvider = game:GetService("ContentProvider")

export type AnimIds = {
	Ignite: string,
	Retract: string, -- "" => reuse Ignite
	Equip: string,
}

export type Markers = {
	Ignite: string, -- KeyframeMarker to flip blade state
	SwapToHand: string, -- (used by your equip script)
	SwapToHip: string, -- (used by your equip script)
}

export type Module = {
	Ids: AnimIds,
	Markers: Markers,
	Preload: boolean,

	-- Build raw Animation instances
	buildAnimations: () -> (Animation, Animation?, Animation),
	-- Convenience: load tracks on an Animator
	loadAll: (Animator) -> { Ignite: AnimationTrack, Retract: AnimationTrack?, Equip: AnimationTrack },
}

local M: Module = {
	Ids = {
		Ignite = "rbxassetid://70744203501030", -- has KeyframeMarker "Ignite"
		Retract = "rbxassetid://109921934993891", -- reversed export ("" => reuse Ignite)
		Equip = "rbxassetid://122681916196297",
	},

	Markers = {
		Ignite = "Ignite",
		SwapToHand = "SwapToHand",
		SwapToHip = "SwapToHip",
	},

	Preload = true,
} :: any

function M.buildAnimations(): (Animation, Animation?, Animation)
	local ign = Instance.new("Animation")
	ign.AnimationId = M.Ids.Ignite

	local ret: Animation? = nil
	if M.Ids.Retract ~= "" then
		ret = Instance.new("Animation")
		ret.AnimationId = M.Ids.Retract
	end

	local eq = Instance.new("Animation")
	eq.AnimationId = M.Ids.Equip

	if M.Preload then
		pcall(function()
			local assets = { ign, eq }
			if ret then
				table.insert(assets, ret)
			end
			ContentProvider:PreloadAsync(assets)
		end)
	end

	return ign, ret, eq
end

function M.loadAll(animator: Animator)
	local ign, ret, eq = M.buildAnimations()
	local tracks = {
		Ignite = animator:LoadAnimation(ign),
		Retract = ret and animator:LoadAnimation(ret) or nil,
		Equip = animator:LoadAnimation(eq),
	}
	return tracks
end

return M
