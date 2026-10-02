-- Diagnostic entry point.
--
-- Same wiring as the reader, but it runs the diagnostic probe instead of the
-- cooldown reader, so a module-lookup failure can be traced step by step.

return function(create_api, diag, build)
    if rawget(_G, 'ReinforcementRadarDiag') ~= nil then return end
    local state = {revision = build.revision, status = 'starting', frames = 0, writes = 0}
    rawset(_G, 'ReinforcementRadarDiag', state)

    local api, runner, log_file

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
        print('[ReinforcementRadarDiag] ' .. tostring(message))
        write_log('[ReinforcementRadarDiag] ' .. tostring(message))
    end

    local function open_log()
        local loader = rawget(_G, 'CowboyBingusModLoader')
        if type(loader) == 'table' and type(loader.open_log) == 'function' then
            local ok, file = pcall(loader.open_log, 'ReinforcementRadarDiag.log')
            if ok and file ~= nil then return file end
        end
        local ok, file = pcall(io.open, 'C:/ReinforcementRadarDiag.log', 'w')
        if ok and file ~= nil then return file end
        ok, file = pcall(io.open, 'ReinforcementRadarDiag.log', 'w')
        if ok and file ~= nil then return file end
        return nil
    end

    local function initialize()
        if runner ~= nil then return true end
        local ok, why = pcall(function()
            log_file = open_log()
            write_log('# Reinforcement Radar diagnostic ' .. build.revision)
            write_log('# time ' .. tostring(os.date and os.date('!%Y-%m-%dT%H:%M:%SZ') or '?'))
            api = create_api()
            runner = diag(api, function(text) write_log(text) end)
        end)
        if not ok then
            report('disabled: ' .. tostring(why))
            return false
        end
        report('ready')
        return true
    end

    local function frame()
        if not initialize() then return end
        state.frames = state.frames + 1
        local ok, why = pcall(runner.frame, 0.016)
        if not ok then report('frame error: ' .. tostring(why)) end
        if runner.state ~= nil then state.status = runner.state end
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
            if runner ~= nil then runner.finish() end
            write_log('# shutdown after ' .. state.frames .. ' frames')
            if log_file ~= nil then
                log_file:close()
                log_file = nil
            end
        end)
        if previous_shutdown ~= nil then return previous_shutdown(...) end
    end
end
