-- Diagnostic probe: find where the game module lookup fails.
--
-- The reader reported "game.dll not loaded" on a live run while the same code
-- passed in the sandbox, so the difference is in the real ffi behaviour. Every
-- step of the lookup is recorded here, including the raw types, because the
-- failure mode is silent: `pcall(tonumber, handle)` collapses any anomaly into
-- a single nil.
--
-- Read-only. Nothing here writes to the process.

return function(api, log)
    local M = {state = 'waiting', frames = 0}

    local function line(text) pcall(log, tostring(text)) end
    local function heading(text) line(''); line('===== ' .. tostring(text) .. ' =====') end

    local function kind(value)
        local t = type(value)
        if t == 'table' then return 'table' end
        if t == 'cdata' then return 'cdata' end
        return t
    end

    -- Report an address-shaped value as both kinds, so a silent conversion
    -- failure is visible instead of collapsing to "nil".
    local function describe(value)
        if value == nil then return 'nil' end
        local numeric = select(2, pcall(tonumber, value))
        return string.format('%s (tonumber=%s)', kind(value), tostring(numeric))
    end

    local function run()
        local ffi = require('ffi')
        heading('FFI BASELINE')
        line('  ffi.abi(64bit)  = ' .. tostring(ffi.abi('64bit')))
        line('  ffi.abi(win)    = ' .. tostring(ffi.abi('win')))

        local ok, kernel = pcall(ffi.load, 'kernel32')
        line('  ffi.load(k32)   = ' .. (ok and kind(kernel) or ('ERROR ' .. tostring(kernel))))
        if not ok or kernel == nil then
            line('  >>> cannot continue without kernel32')
            return
        end

        -- Re-declare locally: the reader's cdef may not have applied.
        local cdef_ok, cdef_err = pcall(ffi.cdef, [[
            void *GetModuleHandleA(const char *name);
            void *GetModuleHandleW(const uint16_t *name);
            uint32_t GetLastError(void);
        ]])
        line('  local cdef      = ' .. (cdef_ok and 'ok' or ('ERROR ' .. tostring(cdef_err))))
        line('  GetModuleHandleA= ' .. kind(kernel.GetModuleHandleA))
        line('  GetModuleHandleW= ' .. kind(kernel.GetModuleHandleW))

        heading('MODULE LOOKUP')
        -- The main executable first: if this fails too, the call itself is broken.
        local exe_ok, exe = pcall(kernel.GetModuleHandleA, nil)
        line('  A(nil)          = ' .. (exe_ok and describe(exe) or ('ERROR ' .. tostring(exe))))

        for _, name in ipairs({'game.dll', 'Game.dll', 'GAME.DLL'}) do
            local call_ok, handle = pcall(kernel.GetModuleHandleA, name)
            line(string.format('  A(%-10s)  = %s', name,
                call_ok and describe(handle) or ('ERROR ' .. tostring(handle))))
            if call_ok and handle ~= nil then
                -- This is exactly what the reader does with it.
                local conv_ok, address = pcall(tonumber, handle)
                line(string.format('       reader path: pcall(tonumber) ok=%s value=%s',
                    tostring(conv_ok), tostring(address)))
            end
        end

        local err = select(2, pcall(kernel.GetLastError))
        line('  GetLastError    = ' .. tostring(err))

        heading('WIDE NAME ATTEMPT')
        -- Some loaders register under a wide string only; try that route too.
        local wide = {}
        for character in ('game.dll'):gmatch('.') do wide[#wide + 1] = character:byte() end
        wide[#wide + 1] = 0
        local wide_ok, wide_handle = pcall(function()
            local buffer = ffi.new('uint16_t[?]', #wide)
            for index = 1, #wide do buffer[index - 1] = wide[index] end
            return kernel.GetModuleHandleW(buffer)
        end)
        line('  W(game.dll)     = ' .. (wide_ok and describe(wide_handle) or ('ERROR ' .. tostring(wide_handle))))

        heading('READER API CHECK')
        -- The module lookup depends on converting an opaque void* to a number.
        -- tonumber() refuses a pointer cdata; only the uintptr_t cast works.
        -- Both routes are reported so a regression here is caught immediately.
        local raw_handle = select(2, pcall(kernel.GetModuleHandleA, 'game.dll'))
        line('  raw handle            = ' .. describe(raw_handle))
        line('  tonumber(handle)      = ' .. tostring(select(2, pcall(tonumber, raw_handle))))
        local cast_ok, cast_value = pcall(function()
            return tonumber(ffi.cast('uintptr_t', raw_handle))
        end)
        line('  tonumber(cast uptr)   = ' ..
            (cast_ok and tostring(cast_value) or ('ERROR ' .. tostring(cast_value))))

        local game = api.module('game.dll')
        line('  api.module(game.dll)  = ' .. tostring(game))
        line('  api.module(nil)       = ' .. tostring(api.module(nil)))
        line('  api.u32 type          = ' .. kind(api.u32))
        local exe_base = api.module(nil)
        if exe_base ~= nil then
            local mz = api.read(exe_base, 2)
            line('  read(exe, 2)          = ' .. tostring(mz))
        end

        heading('ENVIRONMENT')
        local loader = rawget(_G, 'CowboyBingusModLoader')
        line('  loader present  = ' .. tostring(type(loader) == 'table'))
        line('  loader.api      = ' .. tostring(type(loader) == 'table' and rawget(loader, 'api') or nil))
        line('  stingray        = ' .. kind(rawget(_G, 'stingray')))
        line('  jit.version     = ' .. tostring(rawget(_G, 'jit') and rawget(_G, 'jit').version))
    end

    function M.frame(dt)
        M.frames = M.frames + 1
        if M.frames < 150 then return end
        if M.state ~= 'waiting' then return end
        M.state = 'done'
        local ok, why = pcall(run)
        if not ok then line('# probe error: ' .. tostring(why)) end
        heading('DIAGNOSTIC COMPLETE')
        line('END OF DIAGNOSTIC')
    end

    function M.finish()
        pcall(function()
            line('')
            line('# diagnostic finished after ' .. M.frames .. ' frames')
        end)
    end

    return M
end
