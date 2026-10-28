-- Path of Building
--
-- Module: Agent MCP Server
-- A Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0) exposing BuildAPI tools.
-- PoB is booted lazily on the first tool call so the client handshake is instant.
--
local dkjson = require("dkjson")
local t_insert = table.insert

local M = { }

local SERVER_NAME = "path-of-building"
local SUPPORTED_VERSIONS = { ["2025-06-18"] = true, ["2025-03-26"] = true, ["2024-11-05"] = true }
local DEFAULT_VERSION = "2025-06-18"

M.instructions = [[
Path of Building (PoE 1) running headless: every number comes from PoB's own calculation engine.

Typical flow:
1. load_build (file path, XML or PoB code) or new_build.
2. get_summary / get_stats to see the build. Check get_config first: enemy type (Pinnacle/Uber), charges, flasks and conditional buffs can inflate numbers.
3. Change things with edit_tree, equip_item, set_skill_group, set_gem, set_main_skill, set_config. Each returns the stat changes.
4. Use what_if to compare options without keeping them, rank_passives for value per point, ablation to find what really scales the build, check_ssf_rules for SSF realism.
5. loadouts / compare_loadouts for progression tiers; save_build to write a .xml or get a share code.

Headline stats: dps (FullDPS if any group is included in Full DPS, else CombinedDPS), ehp (TotalEHP), maxHit per damage type and minMaxHit (the one-shot threshold).
Item text uses the in-game Ctrl+C format or PoB's item text. Lines PoB can't parse are reported as unsupportedMods and do nothing.

When game knowledge is missing, look it up rather than guessing: poewiki.net (mechanics), poedb.tw (mined mods, bases, gems, uniques), craftofexile.com (mod pools, weights, crafting), poe.ninja (meta builds, economy).
]]

local function encode(value)
	return dkjson.encode(value, { exception = function(reason, val)
		if type(val) == "number" then
			return '"'..tostring(val)..'"'
		end
		return '"<'..tostring(reason)..'>"'
	end })
end

-- Mark a table so dkjson encodes it as an object even when empty
local function object(t)
	return setmetatable(t or { }, { __jsontype = "object" })
end

-- Empty Lua tables are ambiguous; make schema "properties" objects explicit
local function fixSchema(schema)
	if type(schema) ~= "table" then
		return schema
	end
	if schema.properties then
		object(schema.properties)
		for _, prop in pairs(schema.properties) do
			fixSchema(prop)
		end
	end
	if schema.items then
		fixSchema(schema.items)
	end
	return schema
end

function M.New(opts)
	local self = setmetatable({ }, { __index = M })
	self.out = opts.out
	self.boot = opts.boot
	self.api = nil
	return self
end

function M:Send(msg)
	self.out:write(encode(msg), "\n")
	self.out:flush()
end

function M:GetAPI()
	if not self.api then
		self.boot()
		self.api = LoadModule("Agent/BuildAPI")
	end
	return self.api
end

local function errorResponse(id, code, message)
	return { jsonrpc = "2.0", id = id, error = { code = code, message = message } }
end

function M:HandleToolCall(params)
	local api = self:GetAPI()
	local name = params.name
	if not api.tools[name] then
		return nil, -32602, "Unknown tool: "..tostring(name)
	end
	local args = params.arguments
	if type(args) ~= "table" then
		args = { }
	end
	local ok, result = xpcall(function()
		return api.Call(name, args)
	end, function(err)
		if type(err) == "string" then
			if os.getenv("POB_MCP_DEBUG") then
				io.stderr:write(debug.traceback(err, 2), "\n")
			end
			-- Drop the "file:line:" prefix of errors raised by the API for readability
			return (err:gsub("^[^:\n]*%.lua:%d+: ", ""))
		end
		return tostring(err)
	end)
	if ok then
		return { content = { { type = "text", text = encode(result) } } }
	end
	return { content = { { type = "text", text = "Error: "..tostring(result) } }, isError = true }
end

function M:Handle(msg)
	local id, method = msg.id, msg.method
	if method == nil then
		-- A response to something we sent; we never send requests
		return
	end
	local isNotification = id == nil
	if method == "initialize" then
		local requested = msg.params and msg.params.protocolVersion
		return { jsonrpc = "2.0", id = id, result = {
			protocolVersion = SUPPORTED_VERSIONS[requested] and requested or DEFAULT_VERSION,
			capabilities = { tools = object({ listChanged = false }) },
			serverInfo = { name = SERVER_NAME, version = M.version or "dev" },
			instructions = M.instructions,
		} }
	elseif method == "ping" then
		return { jsonrpc = "2.0", id = id, result = object() }
	elseif method == "tools/list" then
		local tools = { }
		for _, def in ipairs(self:GetAPI().ListTools()) do
			t_insert(tools, { name = def.name, description = def.description, inputSchema = fixSchema(def.inputSchema) })
		end
		return { jsonrpc = "2.0", id = id, result = { tools = tools } }
	elseif method == "tools/call" then
		local result, code, message = self:HandleToolCall(msg.params or { })
		if not result then
			return errorResponse(id, code, message)
		end
		return { jsonrpc = "2.0", id = id, result = result }
	elseif method == "resources/list" then
		return { jsonrpc = "2.0", id = id, result = { resources = { } } }
	elseif method == "prompts/list" then
		return { jsonrpc = "2.0", id = id, result = { prompts = { } } }
	elseif isNotification then
		-- notifications/initialized, notifications/cancelled, etc.
		return
	end
	return errorResponse(id, -32601, "Method not found: "..tostring(method))
end

function M:HandleLine(line)
	line = line:gsub("\r$", "")
	if not line:match("%S") then
		return
	end
	local msg, _, err = dkjson.decode(line)
	if type(msg) ~= "table" then
		self:Send(errorResponse(dkjson.null, -32700, "Parse error: "..tostring(err)))
		return
	end
	local batch = msg[1] ~= nil and msg or { msg }
	for _, m in ipairs(batch) do
		local ok, response = pcall(self.Handle, self, m)
		if not ok then
			response = errorResponse(m.id, -32603, tostring(response))
		end
		if response and m.id ~= nil then
			self:Send(response)
		end
	end
end

function M:Run(input)
	for line in input:lines() do
		self:HandleLine(line)
	end
end

return M
