-- Path of Building
--
-- MCP (Model Context Protocol) server entry point.
-- Lets an AI assistant such as Claude drive Path of Building headless: load builds, change
-- passives/items/gems/config and read PoB's calculated stats. See docs/mcp.md.
--
-- Usage (any working directory): luajit path/to/src/PoBMCP.lua
--
local ffi = require("ffi")

-- PoB loads everything relative to src/, so move there first
local scriptDir = (arg and arg[0] or ""):match("^(.*)[/\\]")
if scriptDir and scriptDir ~= "" and scriptDir ~= "." then
	local ok, err = pcall(function()
		if ffi.os == "Windows" then
			ffi.cdef("int SetCurrentDirectoryA(const char *path);")
			assert(ffi.C.SetCurrentDirectoryA(scriptDir) ~= 0)
		else
			ffi.cdef("int chdir(const char *path);")
			assert(ffi.C.chdir(scriptDir) == 0)
		end
	end)
	if not ok then
		io.stderr:write("Could not change directory to "..scriptDir..": "..tostring(err).."\n")
		os.exit(1)
	end
end

package.path = "../runtime/lua/?.lua;../runtime/lua/?/init.lua;lua/?.lua;lua/?/init.lua;"..package.path
if ffi.os == "Windows" then
	package.cpath = "../runtime/?.dll;"..package.cpath
end

local Headless = dofile("Agent/Headless.lua")
local MCPServer = dofile("Agent/MCPServer.lua")

local version
local manifest = io.open("../manifest.xml", "r") or io.open("manifest.xml", "r")
if manifest then
	version = manifest:read("*a"):match('<Version number="([^"]+)"')
	manifest:close()
end
MCPServer.version = version

-- Keep stdout for the protocol only; PoB's console output goes to stderr
local protocolOut = io.stdout
io.output(io.stderr)

if arg and arg[1] == "--selftest" then
	-- Quick check that PoB boots and calculates: luajit src/PoBMCP.lua --selftest
	Headless.Boot()
	local API = LoadModule("Agent/BuildAPI")
	local res = API.Call("new_build", { class = "Witch", level = 90 })
	API.Call("set_skill_group", { gems = { "Arc", "Spell Echo" }, main = true })
	local code = API.Call("save_build", { }).code
	io.stderr:write(string.format("Path of Building %s headless OK: level %d %s, %d life, build code %d chars\n",
		version or "dev", res.summary.level, res.summary.class, res.stats.life, code and #code or 0))
	os.exit(code and 0 or 1)
end

local server = MCPServer.New({ out = protocolOut, boot = Headless.Boot })
server:Run(io.stdin)
