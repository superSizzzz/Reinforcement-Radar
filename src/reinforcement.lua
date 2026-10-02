-- Enemy reinforcement cooldown reader.
--
-- The offsets and the state machine below are the ones validated by
-- `mods/hd2_local/automaton_reinforcement_cd` v0.1.2 on this exact game build,
-- cross-checked against its own log:
--
--   raw_remaining=164.014862  rate=0.963457  seconds=171
--   ceil(164.014862 / 0.963457) = ceil(170.2) = 171
--
-- Nothing here is guessed. What is new is the diagnostic depth: each step of
-- the resolution chain is recorded, so a failure says which link broke instead
-- of collapsing into one generic status.
--
-- Game build 25480438 / EXE 1.8.46015.0.

local bit = require('bit')

local PROFILE = {
    version = '0.1.0-local',
    steam_build = 25480438,
    game_dll = {
        timestamp = 1790161983,     -- PE TimeDateStamp of game.dll
        image_size = 74727424,      -- PE SizeOfImage
    },
    globals = {
        reinforcement = 53636448,   -- 0x3326020, pointer to the reinforcement manager
        pacing = 53634584,          -- 0x3325f18, pointer to the pacing manager
    },
    -- Native code guards: RVA plus the exact bytes expected there. If the game
    -- is updated these change, and the reader refuses to work rather than
    -- reading offsets that no longer mean what they did.
    signatures = {
        {rva = 9392736, hex = '488bc4488958104889681856574154415641574883ec700f2970c833db488bf90f2978b8f30f103de41aad01440f2940a8440f28c14c896808448beb3959540f86f5030000440f2948980f57f6f3440f100d3a25ad01488b055b13a302458bf54d69fe1c0a00004f8d24b64a8bacf780000000399834090000777af3410f108c3f940000000f2fce761a410f28c0f30f598024090000f30f5cc8f3410f118c3f94000000488bcfe8640e0000f3410f10943f940000000f2ff276050f28ceeb070f28c8f30f5dcaf3410f118c3f940000004c8d87d00a0000488b8780000000ba942697eaf30f5ec8f3410f11088b4810e88b446e00418b8c3f8c000000410f28'},
        {rva = 9392003, hex = '488bcbe8e5110000f30f5984b3d00a0000488b742438f30f11841f94000000'},
        {rva = 9395885, hex = '488b8580000000448b70104181feff7f00007462488b0d4004a302488b4140488bb860010000488b4138ff5008488bc8418bd6ffd74885c0743cf30f1085940000000f2fc6763c32c00f287424504c8d5c2460498b5b30498b6b38498b7348450f2843d00f287c2440498be3415f415e415d415c5fc3f30f1085d00a00000f2fc677c4'},
        {rva = 9403926, hex = '498bcfe852e3fffff3410f11879400000041ff8fa0000000'},
        {rva = 9391759, hex = '8b42083b05b4edb802488b1dc11ea3027443448b4b7033d2448b5378440fafd0418d71ff4585c9742c4c8b5b688b7b74908bce468d04124c23c1438b0cc33bcf0f84d80000003bc80f84d8000000ffc2413bd172dcb8ffffffff8bd04869fa1c0a00008bc8488d'},
        {rva = 19864682, hex = '488b1dc7b8170280bb34e32400000f840d010000488b05bb46030283b81cc20a00030f84f900000080bbf0d84600000f84cd000000488d8b68f13e000f29742450c683f2d8460001e859ac5b00'},
        {rva = 19865002, hex = '488b3d87b7170280bf34e32400000f846d010000488b057b45030283b81cc20a00030f845901000080bff0d84600000f842d01000048899c2480000000488d8f68f13e000f29742450c687f2d8460000e8c1ae5b00'},
        {rva = 25872682, hex = '80b99501000000488bf90f853c03000049895b08ba8c1424a6410f2973e8410f297bd8450f2943c8c6819501000001c6819ff2050001c681e801000001'},
        {rva = 25873626, hex = '80b99501000000488bf90f84d002000049895b08ba726e9b88c6819501000000c681e801000000'},
    },
    offsets = {
        manager_entity_map = 0x68,   -- hash map of mission instances
        manager_descriptor = 0x80,   -- mission descriptor pointer
        cooldown_fraction = 0xad0,   -- float, normalized 0..1, synced to clients
        cooldown_seconds_raw = 0x94, -- float, native seconds remaining (authoritative only)
        pending_count = 0xa0,        -- u32, queued reinforcement requests
        pending_item = 0xc4,         -- first queue item
        pending_stride = 0x104,      -- queue item size
        pacing_blockers = 0x934,     -- u32, blocks cooldown decrement
        pacing_rate = 0x924,         -- float, cooldown rate
    },
}

return function(api, log)
    local M = {status = 'UNKNOWN', samples = 0}
    local offsets = PROFILE.offsets

    local function hex(text)
        return (text:gsub('%x%x', function(pair) return string.char(tonumber(pair, 16)) end))
    end

    -- ------------------------------------------------------------------
    -- Module and build verification.
    -- ------------------------------------------------------------------
    function M.verify()
        local game = api.module('game.dll')
        if game == nil then return nil, 'game.dll not loaded' end
        M.game = game

        -- PE sanity: a DOS header, a sane e_lfanew, and the PE signature.
        local mz = api.read(game, 2)
        if mz ~= 'MZ' then return nil, 'game.dll does not start with MZ' end
        local pe = api.u32(game + 60)
        if pe == nil or pe < 64 or pe > 4096 then return nil, 'implausible e_lfanew' end
        if api.read(game + pe, 4) ~= 'PE\0\0' then return nil, 'no PE signature' end

        local timestamp = api.u32(game + pe + 8)
        local image_size = api.u32(game + pe + 80)
        M.game_timestamp, M.game_image_size = timestamp, image_size
        if timestamp ~= PROFILE.game_dll.timestamp or image_size ~= PROFILE.game_dll.image_size then
            return nil, string.format('unsupported game build: timestamp=%s image_size=%s',
                tostring(timestamp), tostring(image_size))
        end

        -- Native code guards. These are what make the fixed offsets safe: if any
        -- patch the offsets referred to has moved, we stop rather than misread.
        --
        -- Every guard is examined rather than stopping at the first failure, so
        -- one report shows the whole picture. They cannot be checked offline:
        -- the code section is packed in game.dll on disk and only expands in
        -- memory, so the file's bytes are not the bytes compared here. A
        -- transcription slip therefore surfaces only at runtime, which is why
        -- this table is generated from the reference rather than typed by hand.
        local failures, passed = {}, 0
        for index, guard in ipairs(PROFILE.signatures) do
            local expected = hex(guard.hex)
            local found = api.read(game + guard.rva, #expected)
            if found == nil then
                failures[#failures + 1] = string.format('#%d rva 0x%x unreadable', index, guard.rva)
            elseif found ~= expected then
                local at = 0
                for position = 1, #expected do
                    if found:byte(position) ~= expected:byte(position) then
                        at = position
                        break
                    end
                end
                local function show(text, from)
                    local slice = text:sub(from, from + 3)
                    return (slice:gsub('.', function(c) return string.format('%02x', c:byte()) end))
                end
                failures[#failures + 1] = string.format(
                    '#%d rva 0x%x differs at byte %d (found %s expected %s)',
                    index, guard.rva, at, show(found, at), show(expected, at))
            else
                passed = passed + 1
            end
        end
        M.signatures_total = #PROFILE.signatures
        M.signatures_checked = passed
        if #failures > 0 then
            return nil, string.format('%d of %d guards failed: %s',
                #failures, #PROFILE.signatures, table.concat(failures, ' | '))
        end
        return game
    end

    -- ------------------------------------------------------------------
    -- Sampling.
    -- ------------------------------------------------------------------
    -- Every step records why it stopped, so a failure is diagnosable from the
    -- log alone without another in-game run.
    local function sample()
        local result = {status = 'UNKNOWN'}
        local game = M.game or M.verify()
        if game == nil then
            result.reason = 'game unavailable'
            return result
        end

        local manager = api.pointer(game + PROFILE.globals.reinforcement)
        if manager == nil then
            result.status, result.reason = 'UNAVAILABLE', 'no reinforcement manager'
            return result
        end
        result.manager = manager

        -- The entity map is the reliable presence gate on both network roles;
        -- the comment in the original notes +0x54 is not.
        local map_header = api.read(manager + offsets.manager_entity_map, 24)
        if map_header == nil then
            result.reason = 'entity map header unreadable'
            return result
        end
        local capacity = api.u32(manager + offsets.manager_entity_map + 8)
        result.map_capacity = capacity
        if capacity == nil or capacity > 16 or (capacity ~= 0 and bit.band(capacity, capacity - 1) ~= 0) then
            result.reason = 'invalid entity map capacity'
            return result
        end
        if capacity == 0 then
            result.status, result.reason = 'UNAVAILABLE', 'outside mission'
            return result
        end

        local descriptor = api.pointer(manager + offsets.manager_descriptor)
        if descriptor == nil then
            -- Outside a mission the manager still exists but carries no
            -- descriptor. That is the normal on-ship state, not a read failure,
            -- and the HUD hides on it.
            result.status, result.reason = 'UNAVAILABLE', 'no active mission'
            return result
        end
        local identity = api.read(descriptor, 24)
        if identity == nil then
            result.reason = 'mission identity unreadable'
            return result
        end
        result.authoritative = bit.band(api.u32(descriptor + 20), 1) == 1

        -- Confirm the mission instance is actually present in the entity map,
        -- so a stale manager is not mistaken for a live mission.
        local id = api.u32(descriptor + 8)
        local empty = api.u32(manager + offsets.manager_entity_map + 12)
        local slots_address = api.u64(manager + offsets.manager_entity_map)
        local slots = slots_address and api.read(slots_address, capacity * 8) or nil
        if slots == nil then
            result.reason = 'entity map slots unreadable'
            return result
        end
        local found = false
        for index = 0, capacity - 1 do
            local base = index * 8
            local key = api.u32(slots_address + base)
            local value = api.u32(slots_address + base + 4)
            if key ~= nil and key ~= empty and key == id and value == 0 then found = true end
        end
        if not found then
            result.status, result.reason = 'UNAVAILABLE', 'mission instance absent'
            return result
        end

        local fraction = api.f32(manager + offsets.cooldown_fraction)
        result.fraction_raw = fraction
        if not api.finite(fraction, 2) or fraction < -0.01 or fraction > 1.01 then
            result.reason = 'invalid synced cooldown fraction'
            return result
        end
        result.fraction = math.max(0, math.min(1, fraction))

        if not result.authoritative then
            -- +0xad0 is a normalized ratio, not seconds. Never relabel it as time.
            result.status = fraction > 0 and 'COOLDOWN' or 'UNKNOWN'
            result.reason = 'client synchronized ratio; availability unverified'
            return result
        end

        local raw = api.f32(manager + offsets.cooldown_seconds_raw)
        result.raw_remaining = raw
        if not api.finite(raw, 86400) or raw < -1 then
            result.reason = 'invalid native cooldown'
            return result
        end
        result.raw_remaining = math.max(0, raw)

        local pending = api.u32(manager + offsets.pending_count)
        result.pending = pending
        if pending == nil or pending > 8 then
            result.reason = 'invalid reinforcement queue'
            return result
        end
        local ordinary = false
        for index = 0, pending - 1 do
            if api.u32(manager + offsets.pending_item + index * offsets.pending_stride) == 0 then
                ordinary = true
            end
        end

        local pacing = api.pointer(game + PROFILE.globals.pacing)
        if pacing == nil then
            result.reason = 'pacing manager unavailable'
            return result
        end
        result.pacing = pacing
        local blockers = api.u32(pacing + offsets.pacing_blockers)
        local rate = api.f32(pacing + offsets.pacing_rate)
        result.blockers, result.rate = blockers, rate
        if blockers == nil or blockers > 4096 or not api.finite(rate, 100) or rate < 0 then
            result.reason = 'invalid pacing state'
            return result
        end

        if ordinary then
            result.status = 'PENDING'
            result.reason = 'native ordinary reinforcement request queued'
        elseif blockers > 0 or rate == 0 then
            result.status = 'PAUSED'
            result.reason = 'native cooldown decrement suspended'
        elseif raw > 0 then
            result.status = 'COOLDOWN'
            result.seconds = math.ceil(raw / rate)
        else
            result.status, result.seconds = 'READY', 0
            result.reason = 'shared cooldown clear; local request gates still apply'
        end
        return result
    end

    -- Public sample with the whole chain isolated, so a fault in the reader can
    -- never reach the game loop.
    function M.sample()
        local ok, value = pcall(sample)
        if not ok then return {status = 'UNKNOWN', reason = tostring(value)} end
        M.samples = M.samples + 1
        M.last = value
        return value
    end

    return M
end
