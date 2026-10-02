-- Sandbox harness for the diagnostic build.
--
-- The diagnostic is what runs when the reader cannot find game.dll, so it must
-- not itself depend on a successful lookup. This proves it runs to completion,
-- reports every step, and touches nothing but reads.

local ROOT = [[D:\coding\HD2Mods\ReinforcementRadar\]]
local real = _G

-- ---- fake process memory: one readable page at game.dll -------------------
local PAGE = 0x1000
local MEM = {}
local game_base = 0x140000000
local exe_base = 0x7ff700000000

local function ensure(address)
    local base = address - address % PAGE
    local block = MEM[base]
    if block == nil then
        local offset = address % PAGE
        block = {head = string.rep('\0', offset), tail = string.rep('\0', PAGE - offset)}
        MEM[base] = block
    end
    return block
end
local function write(address, text)
    local base = address - address % PAGE
    local block = ensure(address)
    local bytes = block.head .. block.tail
    local offset = address - base
    bytes = bytes:sub(1, offset) .. text .. bytes:sub(offset + #text + 1)
    block.head = bytes:sub(1, PAGE)
    block.tail = bytes:sub(PAGE + 1)
end
local function region(address, size)
    local base = address - address % PAGE
    local block = MEM[base]
    if block == nil then return nil end
    local bytes = block.head .. block.tail
    local offset = address - base
    if offset + size > #bytes then return nil end
    return bytes:sub(offset + 1, offset + size)
end

write(game_base, 'MZ')
write(exe_base, 'MZ')
write(game_base + 0x110, 'PE\0\0')

-- ---- control: make the lookup behave a chosen way -------------------------
-- 'ok'      -> returns a number, like a well-behaved cdata
-- 'table'   -> returns a table, which tonumber() refuses
-- 'nil'     -> returns nothing, the failure seen on the live run
local MODE = os.getenv('DIAG_MODE') or 'ok'

local reads, writes_attempted = 0, 0
local scala = {}
local function box(ctype)
    if scala[ctype] == nil then
        local entry = {value = 0, is_scalar = true, ctype = ctype}
        setmetatable(entry, {
            __index = function(self, k) if k == 0 then return self.value end end,
            __newindex = function(self, k, v) if k == 0 then self.value = v end end,
        })
        scala[ctype] = entry
    end
    return scala[ctype]
end

local fake_kernel = {}
function fake_kernel.GetModuleHandleA(name)
    if MODE == 'nil' then return nil end
    if MODE == 'table' then return {p = name == 'game.dll' and game_base or exe_base} end
    if name == nil then return exe_base end
    if name == 'game.dll' then return game_base end
    return nil
end
function fake_kernel.GetModuleHandleW(name) return nil end
function fake_kernel.GetLastError() return 127 end
function fake_kernel.GetCurrentProcess() return 0 end
function fake_kernel.GetTickCount64() return 7000000 end
function fake_kernel.ReadProcessMemory(process, address, target, size, count)
    local slice = region(address, size)
    if slice == nil then return 0 end
    reads = reads + 1
    if type(target) == 'table' and target.__array then
        target.data = slice
        if type(count) == 'table' then count.value = size end
        return 1
    end
    return 0
end

local ffi = {}
function ffi.abi() return true end
function ffi.cdef() end
function ffi.load() return fake_kernel end
function ffi.cast(t, v)
    -- Real semantics: cast('uintptr_t', ptr) yields an integer cdata that
    -- tonumber() accepts. Returning a table here would make the diagnostic
    -- report a conversion failure that does not exist in the game.
    if type(v) == 'table' then return v.p or v.value or 0 end
    return tonumber(v) or 0
end
function ffi.new(ctype, first)
    if ctype:sub(1, 6) == 'uint8_' and ctype:find('%?') then
        return {__array = true, size = first or 0, data = string.rep('\0', first or 0)}
    end
    if ctype:sub(1, 8) == 'uint16_t' and ctype:find('%?') then
        return {__array = true, width = 2, size = first or 0, data = string.rep('\0', first or 0)}
    end
    local entry = box(ctype)
    if first ~= nil then entry.value = first end
    return entry
end
function ffi.string(v, n)
    if type(v) == 'table' and v.__array then return v.data:sub(1, n or v.size) end
    return ''
end
function ffi.copy(target, source, size)
    if type(target) ~= 'table' then return end
    local text = type(source) == 'string' and source or ''
    local count = size or #text
    if target.__array then
        target.data = text:sub(1, count)
        return
    end
    if target.is_scalar then
        local ctype = target.ctype or 'uint32_t'
        if ctype:sub(1, 5) == 'float' then
            local b1, b2, b3, b4 = text:byte(1, 4)
            local bits = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
            local sign = 1
            if bits >= 2147483648 then sign, bits = -1, bits - 2147483648 end
            local exponent = math.floor(bits / 8388608)
            local mantissa = bits % 8388608
            target.value = sign * ((exponent == 0) and (mantissa * 2 ^ -149)
                or ((1 + mantissa / 8388608) * 2 ^ (exponent - 127)))
        else
            local value = 0
            for index = count, 1, -1 do value = value * 256 + text:byte(index) end
            target.value = value
        end
    end
end

local sandbox = {}
setmetatable(sandbox, {__index = real})
sandbox._G = sandbox
sandbox.update = function(dt, extra) return 'frame-ok', extra end
sandbox.shutdown = function() return 'shutdown-ok' end
local real_require = real.require
sandbox.require = function(name)
    if name == 'ffi' then return ffi end
    if name == 'bit' then return real_require('bit') end
    return real_require(name)
end

-- ---- run ----------------------------------------------------------------
local chunk, load_error = loadfile(ROOT .. 'build\\mod.wrapper.lua')
assert(chunk, 'loadfile failed: ' .. tostring(load_error))
setfenv(chunk, sandbox)

print('== mode: ' .. MODE)
local ok, why = pcall(chunk)
print('== wrapper load : ' .. (ok and 'ok' or ('FAILED: ' .. tostring(why))))
if not ok then return end

for _ = 1, 200 do sandbox.update(0.016, 'tick') end
print('== ran 200 frames, diagnostic state = ' .. tostring(sandbox.ReinforcementRadarDiag.state))
print('== memory reads : ' .. reads .. '   (writes attempted: ' .. writes_attempted .. ')')

pcall(sandbox.shutdown)

print('')
for _, path in ipairs({
    (real.os.getenv('LOCALAPPDATA') or '') .. '/CowboyBingus/Helldivers2/Logs/ReinforcementRadarDiag.log',
    'C:/ReinforcementRadarDiag.log',
    ROOT .. 'ReinforcementRadarDiag.log',
    ROOT .. 'scripts/ReinforcementRadarDiag.log',
}) do
    local file = io.open(path, 'r')
    if file then
        local content = file:read('*a')
        file:close()
        local lines = {}
        for text in content:gmatch('[^\n]*') do lines[#lines + 1] = text end
        print('== log: ' .. path .. '  (' .. #lines .. ' lines)')
        for index = 1, math.min(#lines, 60) do print('   | ' .. lines[index]) end
        break
    end
end
