--!strict
local Remotes = require(script.Parent:WaitForChild("Remotes"))
local State = require(script.Parent:WaitForChild("State"))

local NoTool = {}

-- Force OFF across systems and notify others.
function NoTool.setDisignited(character: Model)
	State.setIgnited(character, false)
	State.setBladeOn(character, false)
	Remotes.NoTool:Fire(character)
end

return NoTool
