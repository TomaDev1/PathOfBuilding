-- Path of Building
--
-- Module: Agent Headless
-- Boots Path of Building without a GUI for use by the agent API (MCP server, tests, scripts).
-- Unlike HeadlessWrapper.lua on its own, this keeps stdout clean (all of PoB's console output
-- is sent to stderr) and provides working Inflate/Deflate through zlib so build codes work.
--
-- Must be run with the working directory set to src/ (PoBMCP.lua takes care of this).
--
local ffi = require("ffi")

local M = { }

-- The real stdout, reserved for protocol output
M.stdout = io.stdout

-- Send everything PoB prints to stderr
local function stderrPrint(...)
	local parts = { }
	for i = 1, select("#", ...) do
		parts[i] = tostring(select(i, ...))
	end
	io.stderr:write(table.concat(parts, "\t"), "\n")
end

local function loadZlib()
	ffi.cdef[[
		unsigned long compressBound(unsigned long sourceLen);
		int compress2(uint8_t *dest, unsigned long *destLen, const uint8_t *source, unsigned long sourceLen, int level);
		int uncompress(uint8_t *dest, unsigned long *destLen, const uint8_t *source, unsigned long sourceLen);
	]]
	local candidates
	if ffi.os == "Windows" then
		candidates = { "../runtime/zlib1.dll", "zlib1", "zlib" }
	elseif ffi.os == "OSX" then
		candidates = { "z", "libz.dylib" }
	else
		candidates = { "z", "libz.so.1" }
	end
	for _, name in ipairs(candidates) do
		local ok, lib = pcall(ffi.load, name)
		if ok then
			return lib
		end
	end
end

function M.InstallZlib()
	if M.zlibInstalled then
		return
	end
	M.zlibInstalled = true
	local zlib = loadZlib()
	if not zlib then
		io.stderr:write("Warning: zlib not found, build codes will not work\n")
		return
	end
	function Deflate(data)
		local bound = zlib.compressBound(#data)
		local buf = ffi.new("uint8_t[?]", bound)
		local len = ffi.new("unsigned long[1]", bound)
		local res = zlib.compress2(buf, len, data, #data, 9)
		if res ~= 0 then
			return nil, "compress2 failed ("..res..")"
		end
		return ffi.string(buf, len[0])
	end
	function Inflate(data)
		if not data or #data == 0 then
			return nil, "No data"
		end
		local size = math.max(#data * 8, 65536)
		for _ = 1, 12 do
			local buf = ffi.new("uint8_t[?]", size)
			local len = ffi.new("unsigned long[1]", size)
			local res = zlib.uncompress(buf, len, data, #data)
			if res == 0 then
				return ffi.string(buf, len[0])
			elseif res ~= -5 then -- Z_BUF_ERROR means the buffer was too small
				return nil, "uncompress failed ("..res..")"
			end
			size = size * 4
		end
		return nil, "Decompressed data too large"
	end
end

-- Boot PoB. Safe to call more than once.
function M.Boot()
	if M.booted then
		return
	end
	print = stderrPrint
	io.output(io.stderr)

	-- HeadlessWrapper waits for a key press if startup fails; don't let it eat protocol input
	local realRead = io.read
	io.read = function() return nil end
	dofile("HeadlessWrapper.lua")
	io.read = realRead

	if __mainObject__.promptMsg then
		error("Path of Building failed to start: "..tostring(__mainObject__.promptMsg))
	end
	-- Running from a source checkout puts PoB in dev mode, which auto-saves the open build to
	-- its file when switching builds. Never do that from an agent.
	__mainObject__.main.disableDevAutoSave = true
	M.InstallZlib()
	M.booted = true
end

return M
