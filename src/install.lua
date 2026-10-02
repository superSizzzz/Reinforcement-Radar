-- Reinforcement Radar entry point, reader stage.
--
-- Phase 1 of the plan: resolve the reinforcement cooldown and write it to a
-- log. No HUD yet -- the point of this stage is to prove the offsets and the
-- resolution chain on a live machine before anything is drawn on screen.
--
-- Wiring follows the pattern already proven in this workspace: a global guard
-- against a second install, the loader's shared log directory, a wrapper around
-- the game frame hook that forwards every return value untouched, and every
-- stage isolated so a fault can never reach the game loop.

return function(create_api, reinforcement, hud, build)
    if rawget(_G, 'ReinforcementRadar') ~= nil then return end
    local state = {
        revision = build.revision,
        status = 'starting',
        frames = 0,
        samples = 0,
        failures = 0,
        writes = 0,
    }
    rawset(_G, 'ReinforcementRadar', state)

    local SAMPLE_INTERVAL = 0.10   -- seconds between samples
    local LOG_INTERVAL = 5.0       -- seconds between log blocks
    local VERIFY_DELAY = 2.0       -- let the engine settle before the first read
    local DRAWS_EVERY = 3          -- refresh the HUD about three times a second

    local api, reader, surface, log_file
    local next_sample, next_log, verified
    local since_draw = 0

    local function write_log(text)
        if log_file == nil then return end
        state.writes = state.writes + 1
        pcall(function()
            log_file:write(tostring(text) .. '\n')
            log_file:flush()
        end)
    end

    local function report(message)
        if state.status == message then return end
        state.status = message
        print('[ReinforcementRadar] ' .. tostring(message))
        write_log('[ReinforcementRadar] ' .. tostring(message))
    end

    -- ------------------------------------------------------------------
    -- Log sink: loader directory first, then fixed fallbacks.
    -- ------------------------------------------------------------------
    local function open_log()
        local loader = rawget(_G, 'CowboyBingusModLoader')
        if type(loader) == 'table' and type(loader.open_log) == 'function' then
            local ok, file = pcall(loader.open_log, 'ReinforcementRadar.log')
            if ok and file ~= nil then
                state.log_via = 'loader'
                return file
            end
        end
        for _, path in ipairs({'C:/ReinforcementRadar.log', 'ReinforcementRadar.log'}) do
            local ok, file = pcall(io.open, path, 'w')
            if ok and file ~= nil then
                state.log_via = path
                return file
            end
        end
        return nil
    end

    -- ------------------------------------------------------------------
    -- One-time setup.
    -- ------------------------------------------------------------------
    local function initialize()
        if api ~= nil then return true end
        local ok, why = pcall(function()
            log_file = open_log()
            write_log('# Reinforcement Radar reader ' .. build.revision)
            write_log('# time ' .. tostring(os.date and os.date('!%Y-%m-%dT%H:%M:%SZ') or '?'))
            api = create_api()
            assert(type(api.module) == 'function', 'reader API incomplete')
            reader = reinforcement(api, function(text) write_log(text) end)
            assert(type(reader.verify) == 'function', 'reader has no verify step')
            surface = hud(rawget(_G, 'stingray'))
            assert(surface ~= nil and type(surface.draw) == 'function', 'HUD unavailable')
        end)
        if not ok then
            state.failures = state.failures + 1
            report('disabled: ' .. tostring(why))
            return false
        end
        return true
    end

    -- ------------------------------------------------------------------
    -- Verification is done once, and its outcome is logged either way. A build
    -- mismatch is not retried: the offsets would be wrong for the whole session.
    -- ------------------------------------------------------------------
    local function verify()
        if verified ~= nil then return verified end
        local ok, game, why = pcall(reader.verify)
        if not ok then
            verified = false
            write_log('# VERIFY ERROR ' .. tostring(game))
            report('verify error: ' .. tostring(game))
            return false
        end
        if game == nil then
            verified = false
            write_log('# VERIFY FAILED: ' .. tostring(why))
            report('unsupported: ' .. tostring(why))
            return false
        end
        verified = true
        write_log('# VERIFY OK')
        write_log('#   game.dll base    = ' .. tostring(game))
        write_log('#   pe timestamp    = ' .. tostring(reader.game_timestamp))
        write_log('#   pe image_size   = ' .. tostring(reader.game_image_size))
        write_log('#   signatures ok   = ' .. tostring(reader.signatures_checked)
            .. ' / ' .. tostring(reader.signatures_total))
        report('verified')
        return true
    end

    -- ------------------------------------------------------------------
    -- Log throttling. Writing every 0.1 s sample would produce ~10 lines per
    -- second and bury the signal. A block is written when the state actually
    -- changes, plus a heartbeat so a long steady cooldown still shows it is
    -- counting down.
    -- ------------------------------------------------------------------
    local LOG_EVERY = 25          -- write at most one block per 25 samples
    local HEARTBEAT = 50          -- forced block every 50 samples (~5 s)
    local since_log, last_status = 0, nil

    local function number(value, places)
        if type(value) ~= 'number' then return tostring(value) end
        if places then return string.format('%.' .. places .. 'f', value) end
        return tostring(value)
    end

    local function log_sample(tag, snapshot)
        write_log('')
        write_log('===== ' .. tag .. ' (sample ' .. state.samples .. ') =====')
        write_log('status=' .. tostring(snapshot.status))
        write_log('reason=' .. tostring(snapshot.reason))
        write_log('authoritative=' .. tostring(snapshot.authoritative))
        if snapshot.seconds ~= nil then
            write_log('seconds=' .. tostring(snapshot.seconds))
        end
        write_log('raw_remaining=' .. number(snapshot.raw_remaining, 6))
        write_log('fraction=' .. number(snapshot.fraction, 6))
        write_log('pending=' .. tostring(snapshot.pending))
        write_log('rate=' .. number(snapshot.rate, 6))
        write_log('blockers=' .. tostring(snapshot.blockers))
        write_log('map_capacity=' .. tostring(snapshot.map_capacity))
        write_log('manager=' .. tostring(snapshot.manager))
        write_log('pacing=' .. tostring(snapshot.pacing))
        if snapshot.seconds ~= nil and snapshot.rate and snapshot.raw_remaining then
            write_log(string.format('derived=ceil(%.6f/%.6f)=%d',
                snapshot.raw_remaining, snapshot.rate, snapshot.seconds))
        end
    end

    -- ------------------------------------------------------------------
    -- One sampling pass.
    -- ------------------------------------------------------------------
    local function pass()
        local snapshot = reader.sample()
        state.samples = state.samples + 1
        state.status = snapshot.status
        since_log = since_log + 1

        -- Refresh the HUD a few times a second. The label only changes once per
        -- second, so drawing on every 0.1 s sample would be wasted work.
        if surface ~= nil then
            since_draw = since_draw + 1
            if since_draw >= DRAWS_EVERY then
                since_draw = 0
                pcall(surface.draw, snapshot)
                state.hud = surface.status
                if surface.layout ~= nil and state.hud_layout == nil then
                    state.hud_layout = surface.layout
                    write_log('# HUD layout: ' .. surface.layout)
                end
            end
        end

        -- Always capture a state transition immediately: that is the signal.
        if snapshot.status ~= last_status then
            log_sample('TRANSITION', snapshot)
            last_status, since_log = snapshot.status, 0
            return
        end
        if since_log >= HEARTBEAT or (since_log >= LOG_EVERY and snapshot.seconds ~= nil) then
            log_sample('TICK', snapshot)
            since_log = 0
        end
    end

    -- ------------------------------------------------------------------
    -- Frame driver.
    -- ------------------------------------------------------------------
    local started_at

    local function frame()
        if not initialize() then return end
        state.frames = state.frames + 1
        if started_at == nil then
            started_at = api.time()
            next_sample, next_log = started_at + VERIFY_DELAY, started_at + VERIFY_DELAY
        end
        local now = api.time()
        if now < next_sample then return end

        if not verify() then
            -- Verified false is terminal for this session; keep the hook alive
            -- but stop doing work.
            next_sample = now + 3600
            return
        end

        local ok, why = pcall(pass)
        if not ok then
            state.failures = state.failures + 1
            if state.failures <= 5 then
                write_log('# sample error: ' .. tostring(why))
                report('sample error: ' .. tostring(why))
            end
        end
        next_sample = now + SAMPLE_INTERVAL
        next_log = next_log + LOG_INTERVAL
    end

    local previous = update
    update = function(dt, ...)
        pcall(frame)
        if previous == nil then return ... end
        return previous(dt, ...)
    end
    local previous_shutdown = shutdown
    shutdown = function(...)
        pcall(function()
            if surface ~= nil then pcall(surface.close) end
            write_log('# shutdown after ' .. state.frames .. ' frames, '
                .. state.samples .. ' samples, ' .. state.failures .. ' failures')
            if log_file ~= nil then
                log_file:close()
                log_file = nil
            end
        end)
        if previous_shutdown ~= nil then return previous_shutdown(...) end
    end
end
