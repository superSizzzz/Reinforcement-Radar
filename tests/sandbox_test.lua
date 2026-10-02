-- Sandbox harness for Reinforcement Radar.
--
-- Runs the REAL wrapper (read_api, reinforcement, install) against a fake
-- process memory laid out the way the reader expects: a PE header, the native
-- signature bytes, the two global pointers, and a reinforcement manager whose
-- fields carry a known cooldown.
--
-- The signature bytes are extracted from src/reinforcement.lua rather than
-- invented, so verify() is exercising the same comparison the game will.
--
-- Nothing here proves the offsets match the real game -- only a live run can do
-- that. What it proves is that the resolution chain, the state machine, the
-- logging throttle and the frame hook behave, so a live run tests the offsets
-- instead of the plumbing.

local ROOT = [[D:\coding\HD2Mods\ReinforcementRadar\]]
local real = _G

-- ======================================================================
-- 0. Pull the real signature bytes and PE values out of the source.
-- ======================================================================
local source = io.open(ROOT .. 'src/reinforcement.lua'):read('*a')
local signatures = {}
for rva, hex in source:gmatch('{rva%s*=%s*(%d+),%s*hex%s*=%s*\'(%x+)\'}') do
    signatures[#signatures + 1] = {rva = tonumber(rva), hex = hex}
end
local pe_timestamp = tonumber(source:match('timestamp%s*=%s*(%d+)'))
local pe_image_size = tonumber(source:match('image_size%s*=%s*(%d+)'))
assert(#signatures >= 1, 'no signatures extracted from the source')
print(string.format('== extracted %d signatures, PE timestamp=%d image_size=%d',
    #signatures, pe_timestamp, pe_image_size))

local function unhex(text)
    return (text:gsub('%x%x', function(pair) return string.char(tonumber(pair, 16)) end))
end

-- ======================================================================
-- 1. Fake process memory: pages of bytes, keyed by page base.
-- ======================================================================
local PAGE = 0x1000
local MEM = {}
local game_base = 0x140000000
local exe_base = 0x7ff700000000

local function page_base(address) return address - address % PAGE end

local function ensure(address)
    local base = page_base(address)
    local block = MEM[base]
    if block == nil then
        local offset = address % PAGE
        block = {head = string.rep('\0', offset), tail = string.rep('\0', PAGE - offset)}
        MEM[base] = block
    end
    return block
end

local function region(address, size)
    local base = page_base(address)
    local block = MEM[base]
    if block == nil then return nil end
    local bytes = block.head .. block.tail
    local offset = address - base
    if offset + size > #bytes then return nil end
    return bytes:sub(offset + 1, offset + size)
end

local function write(address, text)
    local base = page_base(address)
    local block = ensure(address)
    local bytes = block.head .. block.tail
    local offset = address - base
    if offset + #text > #bytes then return false end
    bytes = bytes:sub(1, offset) .. text .. bytes:sub(offset + #text + 1)
    block.head = bytes:sub(1, PAGE)
    block.tail = bytes:sub(PAGE + 1)
    return true
end

local function u32le(value)
    return string.char(value % 256, math.floor(value / 256) % 256,
        math.floor(value / 65536) % 256, math.floor(value / 16777216) % 256)
end

local function u64le(value)
    return u32le(value % 4294967296) .. u32le(math.floor(value / 4294967296))
end

-- IEEE-754 single precision, encoded by hand: no ffi is available here yet.
local function f32le(value)
    if value == 0 then return string.rep('\0', 4) end
    local sign = 0
    if value < 0 then sign, value = 1, -value end
    local exponent = 127
    while value >= 2 do value, exponent = value / 2, exponent + 1 end
    while value < 1 do value, exponent = value * 2, exponent - 1 end
    local mantissa = math.floor((value - 1) * 8388608 + 0.5)
    return u32le(sign * 2147483648 + exponent * 8388608 + mantissa)
end

local function write_u32(address, value) write(address, u32le(value)) end
local function write_f32(address, value) write(address, f32le(value)) end
local function write_ptr(address, value) write(address, u64le(value)) end

-- ---- PE header ----------------------------------------------------------
local pe_offset = 0x110
write(game_base, 'MZ')
write_u32(game_base + 60, pe_offset)
write(game_base + pe_offset, 'PE\0\0')
write_u32(game_base + pe_offset + 8, pe_timestamp)
write_u32(game_base + pe_offset + 24 + 56, pe_image_size)

-- ---- native guards ------------------------------------------------------
for _, guard in ipairs(signatures) do
    local bytes = unhex(guard.hex)
    if not write(game_base + guard.rva, bytes) then
        print(string.format('   WARNING: guard rva 0x%x did not fit a page', guard.rva))
    end
end

-- ---- manager structures -------------------------------------------------
local manager = 0x20000000
local pacing = 0x30000000
local map_slots = 0x40000000
local descriptor = 0x50000000
local MISSION_ID = 4242

write_ptr(game_base + 53636448, manager)
write_ptr(game_base + 53634584, pacing)

-- entity map header is 24 bytes: [slots_ptr][capacity][empty_key]
write_u32(manager + 0x68, map_slots)
write_u32(manager + 0x68 + 8, 1)
write_u32(manager + 0x68 + 12, 0xffffffff)
write_u32(map_slots, MISSION_ID)
write_u32(map_slots + 4, 0)

write_u32(descriptor + 8, MISSION_ID)
write_u32(descriptor + 20, 1)          -- bit 0 set -> authoritative
write_ptr(manager + 0x80, descriptor)

-- The scenario that was observed live: 164.01 s native, rate 0.9635 -> 171 s
local scenario = {raw = 164.014862, fraction = 0.911190, rate = 0.963457, pending = 0, blockers = 0}
local function apply_scenario()
    write_f32(manager + 0xad0, scenario.fraction)
    write_f32(manager + 0x94, scenario.raw)
    write_u32(manager + 0xa0, scenario.pending)
    write_f32(pacing + 0x924, scenario.rate)
    write_u32(pacing + 0x934, scenario.blockers)
end
apply_scenario()

-- ======================================================================
-- 2. Fake ffi, enough for read_api.
-- ======================================================================
local Pointers = {}
Pointers.__index = Pointers
Pointers.__add = function(p, o) return setmetatable({p = p.p + o}, Pointers) end
Pointers.__sub = function(p, o) return setmetatable({p = p.p - o}, Pointers) end
-- Real cdata pointers answer tonumber(); the fake has to as well, or read_api's
-- address handling silently degrades to nil.
Pointers.__tonumber = function(p) return p.p end
local function new_pointer(address) return setmetatable({p = address}, Pointers) end

local scalars = {}
local function box(ctype)
    if scalars[ctype] == nil then
        local entry = {value = 0, is_scalar = true, ctype = ctype}
        setmetatable(entry, {
            __index = function(self, key) if key == 0 then return self.value end end,
            __newindex = function(self, key, value) if key == 0 then self.value = value end end,
        })
        scalars[ctype] = entry
    end
    return scalars[ctype]
end

local reads_ok, reads_refused = 0, 0
local clock_ms = 7000000

local fake_kernel = {}
-- Addresses come back as plain numbers. Real cdata answers tonumber(), but a
-- Lua table cannot (LuaJIT ignores __tonumber), and read_api normalises the
-- handle through tonumber -- so a table here would silently null the address.
function fake_kernel.GetModuleHandleA(name)
    if name == nil then return exe_base end
    if name == 'game.dll' then return game_base end
    return nil
end
function fake_kernel.GetCurrentProcess() return 0 end
function fake_kernel.GetTickCount64() return clock_ms end
function fake_kernel.ReadProcessMemory(process, address, target, size, count)
    local base = type(address) == 'table' and address.p or address
    local slice = region(base, size)
    if slice == nil then
        reads_refused = reads_refused + 1
        return 0
    end
    reads_ok = reads_ok + 1
    if type(target) == 'table' and target.__array then
        target.data = slice
        if type(count) == 'table' then count.value = size end
        return 1
    end
    return 0
end

local fake_ffi = {}
function fake_ffi.abi() return true end
function fake_ffi.cdef() return nil end
function fake_ffi.load() return fake_kernel end
function fake_ffi.cast(ctype, value)
    -- Real semantics: cast('uintptr_t', ptr) produces an integer cdata that
    -- tonumber() accepts. The fake returns a plain number for the same reason.
    -- An earlier version returned a table here, which tonumber() refuses --
    -- that test-side flaw is what pushed a working reader into a broken
    -- pcall(tonumber, handle) and made module lookup fail on the live game.
    if type(value) == 'table' then return value.p or 0 end
    return tonumber(value) or 0
end
function fake_ffi.new(ctype, first)
    if ctype:sub(1, 6) == 'uint8_' and ctype:find('%?') then
        return {__array = true, size = first or 0, data = string.rep('\0', first or 0)}
    end
    local entry = box(ctype)
    if first ~= nil then entry.value = first end
    return entry
end
function fake_ffi.string(value, size)
    if type(value) == 'table' and value.__array then return value.data:sub(1, size or value.size) end
    return ''
end
function fake_ffi.copy(target, source, size)
    if type(target) ~= 'table' then return end
    local text = type(source) == 'string' and source or ''
    local count = size or #text
    text = text:sub(1, count)
    if target.__array then
        target.data = text
        if #target.data < count then target.data = target.data .. string.rep('\0', count - #target.data) end
        return
    end
    if not target.is_scalar then return end
    -- The copy target carries a ctype. A float box must be filled by IEEE-754
    -- decoding, not by integer accumulation -- treating the bytes as an integer
    -- silently returns the bit pattern instead of the value. LuaJIT is Lua 5.1,
    -- so string.unpack does not exist; decode by hand.
    local ctype = target.ctype or 'uint32_t'
    if ctype:sub(1, 5) == 'float' then
        local b1, b2, b3, b4 = text:byte(1, 4)
        local bits = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
        local sign = 1
        if bits >= 2147483648 then sign, bits = -1, bits - 2147483648 end
        local exponent = math.floor(bits / 8388608)
        local mantissa = bits % 8388608
        local value
        if exponent == 0 then
            value = mantissa * 2 ^ -149
        elseif exponent == 255 then
            value = mantissa == 0 and math.huge or (0 / 0)
        else
            value = (1 + mantissa / 8388608) * 2 ^ (exponent - 127)
        end
        target.value = sign * value
    else
        local value = 0
        for index = count, 1, -1 do value = value * 256 + text:byte(index) end
        target.value = value
    end
end

-- ======================================================================
-- 3. Fake game environment.
-- ======================================================================
local sandbox = {}
setmetatable(sandbox, {__index = real})
sandbox._G = sandbox
-- ---- fake Stingray UI ---------------------------------------------------
-- Records what the HUD actually draws, so the panel's text, colour and
-- placement can be asserted without a screen.
local UI = {texts = {}, rects = {}, visible = nil, gui = nil, gui_count = 0, destroyed = 0, world = nil}
local MAIN_WORLD, MISSION_WORLD = 'world-main', 'world-mission'

sandbox.stingray = {
    Application = {
        worlds = function() return {MAIN_WORLD, MISSION_WORLD} end,
        main_world = function() return MAIN_WORLD end,
        -- The real engine answers this the same way; modelling it lets the font
        -- probe be exercised instead of always reporting nothing.
        can_get = function(kind, name)
            if kind == 'font' and name == 'core/performance_hud/debug' then return true end
            return false
        end,
    },
    World = {
        create_screen_gui = function(world)
            UI.gui_count = UI.gui_count + 1
            UI.gui, UI.world = 'gui-' .. UI.gui_count, world
            return UI.gui
        end,
        destroy_gui = function(world, gui)
            if UI.gui == gui then UI.gui = nil end
            UI.destroyed = UI.destroyed + 1
        end,
    },
    Gui = {
        resolution = function() return 2560, 1440 end,
        rect = function(gui, position, size, colour)
            UI.rects[#UI.rects + 1] = {position = position, size = size, colour = colour}
            return #UI.rects
        end,
        text = function(gui, text, font, size, font2, position, colour)
            -- A negative position marks a font-availability probe rather than a
            -- panel draw: only the known font is modelled as usable, and the
            -- probe's throwaway object must not pollute the draw record.
            if position ~= nil and position.x < 0 then
                if font == 'core/performance_hud/debug' then return 'probe-ok' end
                return nil
            end
            UI.texts[#UI.texts + 1] = {text = text, size = size, position = position, colour = colour}
            return #UI.texts
        end,
        set_visible = function(gui, shown) UI.visible = shown end,
        destroy_text = function() end,
        destroy_rect = function() end,
    },
    Vector3 = function(x, y, z) return {x = x, y = y, z = z} end,
    Vector2 = function(x, y) return {x = x, y = y} end,
    Color = function(a, r, g, b) return {a = a, r = r, g = g, b = b} end,
}

sandbox.update = function(dt, extra) return 'frame-ok', extra end
sandbox.shutdown = function() return 'shutdown-ok' end

local real_require = real.require
sandbox.require = function(name)
    if name == 'ffi' then return fake_ffi end
    if name == 'bit' then return real_require('bit') end
    return real_require(name)
end

-- ======================================================================
-- 4. Run the real wrapper.
-- ======================================================================
local chunk, load_error = loadfile(ROOT .. 'build\\mod.wrapper.lua')
assert(chunk, 'loadfile failed: ' .. tostring(load_error))
setfenv(chunk, sandbox)

local ok, why = pcall(chunk)
print('== wrapper load     : ' .. (ok and 'ok' or ('FAILED: ' .. tostring(why))))
if not ok then return end
print('== guard installed  : ' .. tostring(sandbox.ReinforcementRadar ~= nil))

-- The reader samples on GetTickCount64 seconds, so the fake clock has to
-- advance with the frames. Advancing it once per drive() call starved the
-- sampler and the HUD never reached its refresh interval.
local function drive(seconds)
    for _ = 1, math.floor(seconds * 60) do
        clock_ms = clock_ms + 1000 / 60
        sandbox.update(0.016, 'tick')
    end
end

-- The reader samples on GetTickCount64 seconds, so advance the fake clock
-- alongside the frames or no second sample ever fires.
drive(3)
print('== after 3s         : samples=' .. tostring(sandbox.ReinforcementRadar.samples))

scenario.raw, scenario.fraction = 100.0, 0.55
apply_scenario()
drive(6)
print('== after countdown  : samples=' .. tostring(sandbox.ReinforcementRadar.samples)
    .. ' status=' .. tostring(sandbox.ReinforcementRadar.status))

scenario.raw, scenario.fraction = 0.0, 0.0
apply_scenario()
drive(6)
print('== after READY      : status=' .. tostring(sandbox.ReinforcementRadar.status))

-- Under a minute should render red rather than green. The threshold is a plain
-- comparison, but the colour path is worth exercising explicitly.
scenario.raw, scenario.fraction = 50.0, 0.28
apply_scenario()
drive(6)
print('== after urgent     : status=' .. tostring(sandbox.ReinforcementRadar.status))

scenario.pending = 1
apply_scenario()
write_u32(manager + 0xc4, 0)
drive(6)
print('== after PENDING    : status=' .. tostring(sandbox.ReinforcementRadar.status))

local state = sandbox.ReinforcementRadar
print('== final            : frames=' .. tostring(state.frames)
    .. ' samples=' .. tostring(state.samples)
    .. ' failures=' .. tostring(state.failures)
    .. ' writes=' .. tostring(state.writes)
    .. ' log_via=' .. tostring(state.log_via))
print('== memory reads     : ok=' .. reads_ok .. ' refused=' .. reads_refused)

-- ======================================================================
-- 4b. HUD assertions.
-- ======================================================================
print('')
print('== HUD ==')
print('   gui created   : ' .. UI.gui_count .. '  (destroyed ' .. UI.destroyed .. ')')
print('   gui bound to  : ' .. tostring(UI.world) .. '  (mission world = ' .. MISSION_WORLD .. ')')
print('   visible       : ' .. tostring(UI.visible))
print('   rects drawn   : ' .. #UI.rects)
print('   texts drawn   : ' .. #UI.texts)

local last_text = UI.texts[#UI.texts]
if last_text ~= nil then
    print('   last label    : "' .. last_text.text .. '"')
    print('   label colour  : a=' .. last_text.colour.a
        .. ' r=' .. last_text.colour.r .. ' g=' .. last_text.colour.g .. ' b=' .. last_text.colour.b)
end
local last_rect = UI.rects[#UI.rects]
if last_rect ~= nil and last_text ~= nil then
    print(string.format('   panel rect    : pos=%.0f,%.0f size=%.0fx%.0f',
        last_rect.position.x, last_rect.position.y, last_rect.size.x, last_rect.size.y))
    print(string.format('   label inside  : %s', tostring(
        last_text.position.x >= last_rect.position.x
        and last_text.position.x <= last_rect.position.x + last_rect.size.x
        and last_text.position.y >= last_rect.position.y
        and last_text.position.y <= last_rect.position.y + last_rect.size.y)))
    -- Right-hand placement: the panel should end near the right edge.
    local right_gap = 2560 - (last_rect.position.x + last_rect.size.x)
    print(string.format('   right gap     : %.0f px (expect small, ~1%% of width)', right_gap))
end

-- Each drawn label with the colour it used, so the threshold colouring can be
-- checked without a screen. Expected: 171 s green, 104 s grey, READY green,
-- and PENDING hides the panel entirely.
local seen = {}
for _, entry in ipairs(UI.texts) do
    if not seen[entry.text] then
        seen[entry.text] = true
        print(string.format('      %-9s rgb(%3d,%3d,%3d)', '"' .. entry.text .. '"',
            entry.colour.r, entry.colour.g, entry.colour.b))
    end
end
print('   panel visible : ' .. tostring(UI.visible)
    .. '   (last state was PENDING, which should hide it)')

pcall(sandbox.shutdown)
print('== shutdown         : ok')

-- ======================================================================
-- 5. Report the log.
-- ======================================================================
print('')
for _, path in ipairs({
    ROOT .. 'ReinforcementRadar.log',
    ROOT .. 'scripts/ReinforcementRadar.log',
    (real.os.getenv('LOCALAPPDATA') or '') .. '/CowboyBingus/Helldivers2/Logs/ReinforcementRadar.log',
    'C:/ReinforcementRadar.log',
}) do
    local file = io.open(path, 'r')
    if file then
        local content = file:read('*a')
        file:close()
        local lines = {}
        for text in content:gmatch('[^\n]*') do lines[#lines + 1] = text end
        print('== log: ' .. path .. '  (' .. #lines .. ' lines)')
        for index = 1, math.min(#lines, 80) do print('   | ' .. lines[index]) end
        if #lines > 80 then print('   ... ' .. (#lines - 80) .. ' more lines') end
        break
    end
end
