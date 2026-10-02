-- Independent Stingray screen GUI for the reinforcement cooldown.
--
-- Differences from the reference implementation:
--   1. it does not hang off the minimap, so the panel stays visible with the
--      map closed -- which is when a player wants the number
--   2. it shows only what matters: READY, or the bare countdown. A
--      reinforcement already under way shows nothing rather than a stale figure
--   3. no backdrop: the label sits directly on the world
--
-- Coordinate note: the Stingray screen GUI measures y from the BOTTOM of the
-- screen upward. Established from a live screenshot -- an anchor expressed as a
-- fraction from the top rendered near the bottom until the value was flipped.
-- The x axis is unaffected and measured from the left.
--
-- Every draw is pcall-wrapped: a GUI fault hides the panel and is recorded, and
-- can never reach the game loop.

local LAYOUT = {
    right_margin = 0.012,
    -- Fraction of screen height measured DOWN from the top edge: roughly the
    -- right-hand side of the screen, a little above centre.
    below_objectives = 0.42,
    width = 172,
    height = 40,
    text_inset_x = 10,
    text_inset_y = 7,
    text_size = 26,
    reference_height = 1080,
}

-- Plenty of time is green; under two minutes turns orange; under one minute
-- turns red. READY is green.
local GREEN = {90, 220, 155}
local ORANGE = {255, 180, 70}
local RED = {235, 90, 80}

-- The one font this panel uses. It is the font every other HD2 Lua mod in this
-- workspace uses, so it is known to load.
--
-- There is deliberately NO font probing here. An earlier version tried a list
-- of candidate font names by creating throwaway text objects off-screen; that
-- crashed the game. Probing belongs in a diagnostic build run once on demand,
-- never in code that executes on every launch.
local FONT = 'core/performance_hud/debug'

return function(stingray)
    local H = {status = 'idle', visible = false}
    local gui, bound_world, text_id, last_key, layout_reported

    local function worlds_now()
        local ok, list = pcall(stingray.Application.worlds)
        if not ok then return nil end
        return list
    end

    local function present(list, value)
        if type(list) ~= 'table' then return false end
        for _, entry in ipairs(list) do
            if entry == value then return true end
        end
        return false
    end

    local function dispose()
        local list = worlds_now()
        if gui ~= nil and list ~= nil and present(list, bound_world) then
            pcall(stingray.World.destroy_gui, bound_world, gui)
        end
        gui, bound_world, text_id, last_key = nil, nil, nil, nil
    end

    local function mission_world()
        local list = worlds_now()
        if list == nil then return nil end
        local ok, main = pcall(stingray.Application.main_world)
        if not ok then return nil end
        if not present(list, main) then return nil end
        for _, entry in ipairs(list) do
            if entry ~= main then return entry end
        end
        return nil
    end

    -- Returns the label and its colour, or nil to hide the panel entirely.
    --
    -- PENDING and PAUSED both mean a reinforcement is already under way, and a
    -- countdown at that moment would be misleading. UNKNOWN and UNAVAILABLE
    -- mean the value cannot be trusted, so they hide rather than show a number
    -- a player might act on.
    local function presentation(snapshot)
        local status = snapshot.status
        if status == 'READY' then
            return 'READY', GREEN
        end
        if status == 'COOLDOWN' then
            local seconds = snapshot.seconds or 0
            if seconds < 0 then seconds = 0 end
            local colour
            if seconds > 120 then colour = GREEN
            elseif seconds >= 60 then colour = ORANGE
            else colour = RED end
            return string.format('%02d:%02d', math.floor(seconds / 60), seconds % 60), colour
        end
        return nil, nil
    end

    local function hide()
        if H.visible and gui ~= nil and stingray.Gui ~= nil
            and stingray.Gui.set_visible ~= nil then
            pcall(stingray.Gui.set_visible, gui, false)
        end
        H.visible = false
    end

    local function run(snapshot)
        if type(stingray) ~= 'table' or stingray.Gui == nil or stingray.World == nil
            or stingray.Application == nil then
            H.status = 'stingray UI unavailable'
            hide()
            return
        end

        local text, colour = presentation(snapshot)
        if text == nil then
            hide()
            H.status = 'hidden: ' .. tostring(snapshot.status)
            return
        end

        local target = mission_world()
        if target == nil then
            if gui ~= nil then dispose() end
            H.status = 'waiting for mission'
            hide()
            return
        end

        if bound_world ~= target or gui == nil then
            dispose()
            gui = stingray.World.create_screen_gui(target, 'scale', 1, 1)
            assert(gui ~= nil, 'screen GUI creation failed')
            bound_world = target
            last_key = nil
        end

        local ok, screen_w, screen_h = pcall(stingray.Gui.resolution)
        if not ok or screen_w == nil or screen_h == nil
            or screen_w <= 0 or screen_h <= 0 then
            hide()
            H.status = 'resolution unavailable'
            return
        end

        local scale = screen_h / LAYOUT.reference_height
        local panel_w = LAYOUT.width * scale
        local panel_h = LAYOUT.height * scale
        local x = screen_w - panel_w - screen_w * LAYOUT.right_margin
        -- y runs from the bottom, so a top-relative anchor flips, and the panel
        -- height is subtracted because y addresses the panel's lower edge.
        local y = screen_h * (1 - LAYOUT.below_objectives) - panel_h

        if x < 0 or y < 0 or x + panel_w > screen_w or y + panel_h > screen_h then
            hide()
            H.status = 'no room at this resolution'
            return
        end

        local key = string.format('%s|%d|%d|%.4f|%.4f', text, screen_w, screen_h, x, y)
        if key == last_key then
            H.status = 'visible (unchanged)'
            if not H.visible and stingray.Gui.set_visible ~= nil then
                pcall(stingray.Gui.set_visible, gui, true)
            end
            H.visible = true
            return
        end

        if not layout_reported then
            layout_reported = true
            H.layout = string.format('screen=%dx%d scale=%.3f panel=%.0fx%.0f at %.0f,%.0f',
                screen_w, screen_h, scale, panel_w, panel_h, x, y)
        end

        if text_id ~= nil then pcall(stingray.Gui.destroy_text, gui, text_id); text_id = nil end

        -- No backdrop: the label is drawn straight onto the world.
        text_id = stingray.Gui.text(gui, text, FONT,
            LAYOUT.text_size * scale, FONT,
            stingray.Vector3(x + LAYOUT.text_inset_x * scale, y + LAYOUT.text_inset_y * scale, 3),
            stingray.Color(255, colour[1], colour[2], colour[3]))
        assert(text_id ~= nil, 'text creation failed')

        if stingray.Gui.set_visible ~= nil then pcall(stingray.Gui.set_visible, gui, true) end
        last_key = key
        H.visible, H.status = true, 'visible'
    end

    function H.draw(snapshot)
        local ok, err = pcall(run, snapshot)
        if not ok then
            hide()
            H.status = 'draw error: ' .. tostring(err)
        end
        return H.visible == true
    end

    function H.close()
        pcall(dispose)
        H.status = 'closed'
    end

    return H
end
