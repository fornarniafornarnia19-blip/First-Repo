--!strict
-- RS/Shared/NetDefs.luau
return {
	Events = {
		-- Client -> Server: Block hold state
		Saber_Block = {
			args = { "boolean" }, -- holding
			serverRate = 30,
		},

		-- Server -> All Clients: Broadcast state changes
		Saber_BroadcastState = {
			args = { "int", "boolean", "boolean" }, -- userId, equipped/holding, ignited
			serverRate = 30,
		},

		-- Client -> Server: Toggle equip/holster
		Saber_ToggleEquip = {
			args = {},
			serverRate = 5,
		},

		-- Client -> Server: Toggle ignite/retract
		Saber_ToggleIgnite = {
			args = {},
			serverRate = 5,
		},

		-- Server -> Client: Tell client to enter/exit aim mode
		Saber_AimMode = {
			args = { "boolean" }, -- wantOn
			serverRate = 10,
		},

		-- Client -> Server: Swing direction
		Saber_Swing = {
			args = { { "enum", { "Overhead", "Left", "Right", "UpLeft", "UpRight", "DownLeft", "DownRight" } } },
			serverRate = 50,
		},
	},

	Functions = {
		-- Client requests initial state from server
		Saber_RequestInitialState = {
			args = {},
		},
	},
}
