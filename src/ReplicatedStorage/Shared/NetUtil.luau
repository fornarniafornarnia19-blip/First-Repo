--!strict
-- NetUtil: processes RS.Shared.Net.NetDefs, creates remotes on server, and exposes tiny helpers.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local NetFolderName = "_NetRemotes"

type Validator = (any) -> (boolean, string?)

local Net = {}
Net.__index = Net

-- ===== Validators =====
local function v_string(maxLen: number?): Validator
	return function(v)
		if typeof(v) ~= "string" then
			return false, "expected string"
		end
		if maxLen and #v > maxLen then
			return false, "too long"
		end
		return true
	end
end

local function v_number(min: number?, max: number?): Validator
	return function(v)
		if typeof(v) ~= "number" then
			return false, "expected number"
		end
		if min and v < min then
			return false, "too small"
		end
		if max and v > max then
			return false, "too large"
		end
		return true
	end
end

local function v_int(min: number?, max: number?): Validator
	local base = v_number(min, max)
	return function(v)
		local ok, why = base(v)
		if not ok then
			return ok, why
		end
		if v % 1 ~= 0 then
			return false, "expected integer"
		end
		return true
	end
end

local function v_bool(): Validator
	return function(v)
		return typeof(v) == "boolean", "expected boolean"
	end
end

local function v_vector3(): Validator
	return function(v)
		return typeof(v) == "Vector3", "expected Vector3"
	end
end

local function v_cframe(): Validator
	return function(v)
		return typeof(v) == "CFrame", "expected CFrame"
	end
end

local function v_enum(set: { any }): Validator
	local map: { [any]: boolean } = {}
	for _, val in ipairs(set) do
		map[val] = true
	end
	return function(v)
		if map[v] then
			return true
		end
		return false, "invalid enum"
	end
end

local function v_array(ofValidator: Validator, maxLen: number?): Validator
	return function(v)
		if typeof(v) ~= "table" then
			return false, "expected array"
		end
		local n = #v
		if maxLen and n > maxLen then
			return false, "array too long"
		end
		for i = 1, n do
			local ok, why = ofValidator(v[i])
			if not ok then
				return false, ("array[%d] %s"):format(i, why or "invalid")
			end
		end
		return true
	end
end

local function v_tuple(list: { Validator }): Validator
	return function(v)
		if typeof(v) ~= "table" then
			return false, "expected tuple table"
		end
		for i, vf in ipairs(list) do
			local ok, why = vf(v[i])
			if not ok then
				return false, ("tuple[%d] %s"):format(i, why or "invalid")
			end
		end
		return true
	end
end

local function v_object(spec: { [string]: Validator }): Validator
	local req: { [string]: Validator } = {}
	local opt: { [string]: Validator } = {}
	for k, val in pairs(spec) do
		if string.sub(k, -1) == "?" then
			opt[string.sub(k, 1, -2)] = val
		else
			req[k] = val
		end
	end
	return function(v)
		if typeof(v) ~= "table" then
			return false, "expected object"
		end
		for k, vf in pairs(req) do
			local ok, why = vf(v[k])
			if not ok then
				return false, ("field '%s' %s"):format(k, why or "invalid")
			end
		end
		for k, vf in pairs(opt) do
			if v[k] ~= nil then
				local ok, why = vf(v[k])
				if not ok then
					return false, ("field '%s' %s"):format(k, why or "invalid")
				end
			end
		end
		return true
	end
end

-- ===== Spec parser =====
local function parseScalar(token: string): Validator
	token = string.lower(token)
	if token == "string" then
		return v_string()
	elseif string.find(token, "string<=") == 1 then
		local n = tonumber(string.match(token, "string<=([%d]+)"))
		return v_string(n)
	elseif token == "number" or token == "num" then
		return v_number()
	elseif string.find(token, "number%[") == 1 or string.find(token, "num%[") == 1 then
		local a, b = string.match(token, "%a+%[([%-%d%.]+),([%-%d%.]+)%]")
		return v_number(tonumber(a), tonumber(b))
	elseif token == "int" or token == "integer" then
		return v_int()
	elseif string.find(token, "int%[") == 1 then
		local a, b = string.match(token, "int%[([%-%d%.]+),([%-%d%.]+)%]")
		return v_int(tonumber(a), tonumber(b))
	elseif token == "boolean" or token == "bool" then
		return v_bool()
	elseif token == "vector3" or token == "v3" then
		return v_vector3()
	elseif token == "cframe" then
		return v_cframe()
	end
	return function(_)
		return false, "unknown type: " .. token
	end
end

local function parseSpec(spec: any): Validator
	local ty = typeof(spec)
	if ty == "function" then
		return spec :: Validator
	elseif ty == "string" then
		return parseScalar(spec)
	elseif ty == "table" then
		local tag = spec[1]
		if tag == "array" then
			return v_array(parseSpec(spec[2]), spec[3])
		elseif tag == "tuple" then
			local list: { Validator } = {}
			for i = 2, #spec do
				list[#list + 1] = parseSpec(spec[i])
			end
			return v_tuple(list)
		elseif tag == "enum" then
			return v_enum(spec[2])
		elseif tag == "object" then
			local fields: { [string]: Validator } = {}
			for k, v in pairs(spec[2]) do
				fields[k] = parseSpec(v)
			end
			return v_object(fields)
		end
	end
	return function(_)
		return false, "invalid spec"
	end
end

local function compileArgs(def: { args: { any }? }): { Validator }
	local validators: { Validator } = {}
	for i, s in ipairs(def.args or {}) do
		validators[i] = parseSpec(s)
	end
	return validators
end

-- ===== Token-bucket limiter (server) =====
local function makeLimiter(maxPerSecond: number): (Player?) -> boolean
	local bucket = setmetatable({}, { __mode = "k" })
	local last = time()
	return function(player: Player?)
		local now = time()
		local dt = now - last
		last = now
		for _, st in pairs(bucket) do
			st.tokens = math.min(maxPerSecond, st.tokens + dt * maxPerSecond)
		end
		if not player then
			return true
		end
		local st = bucket[player]
		if not st then
			st = { tokens = maxPerSecond }
			bucket[player] = st
		end
		if st.tokens >= 1 then
			st.tokens -= 1
			return true
		end
		return false
	end
end

-- ===== Internals =====
local function ensureFolder(): Folder
	local f = ReplicatedStorage:FindFirstChild(NetFolderName)
	if not f then
		f = Instance.new("Folder")
		f.Name = NetFolderName
		f.Parent = ReplicatedStorage
	end
	return f :: Folder
end

local function validateArgs(vlist: { Validator }, received: { any }): boolean
	if #received < #vlist then
		return false
	end
	for i, vf in ipairs(vlist) do
		local ok = vf(received[i])
		if not ok then
			return false
		end
	end
	return true
end

local state = {
	defs = nil :: any,
	folder = nil :: Folder?,
	events = {} :: { [string]: RemoteEvent },
	functions = {} :: { [string]: RemoteFunction },
	eventValidators = {} :: { [string]: { Validator } },
	funcValidators = {} :: { [string]: { Validator } },
	limits = {} :: { [string]: (Player?) -> boolean },
	handlers = {
		events = {} :: { [string]: (Player, ...any) -> () },
		functions = {} :: { [string]: (Player, ...any) -> any },
	},
}

local function getDefs(): any
	if state.defs then
		return state.defs
	end
	local ok, defsOrErr = pcall(function()
		return require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("NetDefs")) -- Removed :WaitForChild("Net")
	end)
	if not ok then
		error("[NetUtil] Failed to require NetDefs: " .. tostring(defsOrErr))
	end
	state.defs = defsOrErr
	return state.defs
end

-- ===== Server surface =====
function Net.ServerCreateAll(): ()
	assert(RunService:IsServer(), "ServerCreateAll must run on the server")
	local defs = getDefs()
	state.folder = ensureFolder()

	-- Events
	for name, d in pairs(defs.Events or {}) do
		local re = Instance.new("RemoteEvent")
		re.Name = name
		re.Parent = state.folder
		state.events[name] = re
		state.eventValidators[name] = compileArgs(d)
		state.limits[name] = makeLimiter(d.serverRate or 30)

		re.OnServerEvent:Connect(function(player: Player, ...)
			local args = table.pack(...)
			if not state.limits[name](player) then
				return
			end
			if not validateArgs(state.eventValidators[name], args) then
				return
			end
			local handler = state.handlers.events[name]
			if handler then
				local ok, err = pcall(handler, player, table.unpack(args, 1, args.n))
				if not ok then
					warn(("[NetUtil] event '%s' error: %s"):format(name, tostring(err)))
				end
			end
		end)
	end

	-- Functions
	for name, d in pairs(defs.Functions or {}) do
		local rf = Instance.new("RemoteFunction")
		rf.Name = name
		rf.Parent = state.folder
		state.functions[name] = rf
		state.funcValidators[name] = compileArgs(d)

		rf.OnServerInvoke = function(player: Player, ...)
			local args = table.pack(...)
			if not validateArgs(state.funcValidators[name], args) then
				return nil
			end
			local handler = state.handlers.functions[name]
			if not handler then
				return nil
			end
			local ok, res = pcall(handler, player, table.unpack(args, 1, args.n))
			if not ok then
				warn(("[NetUtil] function '%s' error: %s"):format(name, tostring(res)))
				return nil
			end
			return res
		end
	end
end

function Net.OnServerEvent(name: string, fn: (Player, ...any) -> ()): ()
	assert(RunService:IsServer(), "OnServerEvent is server-only")
	state.handlers.events[name] = fn
end

function Net.OnServerFunction(name: string, fn: (Player, ...any) -> any): ()
	assert(RunService:IsServer(), "OnServerFunction is server-only")
	state.handlers.functions[name] = fn
end

function Net.FireClient(player: Player, name: string, ...): ()
	assert(RunService:IsServer(), "FireClient is server-only")
	local re = state.events[name]
	if re then
		re:FireClient(player, ...)
	end
end

function Net.FireAllClients(name: string, ...): ()
	assert(RunService:IsServer(), "FireAllClients is server-only")
	local re = state.events[name]
	if re then
		re:FireAllClients(...)
	end
end

-- ===== Client surface =====
function Net.GetEvent(name: string): RemoteEvent
	local f = ensureFolder()
	return f:WaitForChild(name) :: RemoteEvent
end

function Net.GetFunction(name: string): RemoteFunction
	local f = ensureFolder()
	return f:WaitForChild(name) :: RemoteFunction
end

function Net.OnClientEvent(name: string, fn: (...any) -> ()): ()
	assert(RunService:IsClient(), "OnClientEvent is client-only")
	Net.GetEvent(name).OnClientEvent:Connect(fn)
end

function Net.FireServer(name: string, ...): ()
	assert(RunService:IsClient(), "FireServer is client-only")
	Net.GetEvent(name):FireServer(...)
end

function Net.InvokeServer(name: string, ...): any
	assert(RunService:IsClient(), "InvokeServer is client-only")
	return Net.GetFunction(name):InvokeServer(...)
end

-- expose limiter if you want custom endpoints to reuse it
Net.MakeLimiter = makeLimiter

return Net
