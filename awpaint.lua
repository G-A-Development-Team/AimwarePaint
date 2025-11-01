-- uitest.lua - Windowed Paint-like UI using provided API
-- Features: Multiple draggable windows (Canvas, Tools, Colors, History), Brush/Line/Eraser
--           Color palette, Brush size, Undo/Redo, Clear, Clipping to canvas, Background grid

-- Fonts
local title_font = draw.CreateFont("Bahnschrift", 18, 700, true, true)
local ui_font    = draw.CreateFont("Bahnschrift", 14, 400, false, true)
local small_font = draw.CreateFont("Bahnschrift", 12, 400, false, true)

-- Mouse button codes (typical)
local MOUSE_LEFT, MOUSE_RIGHT = 1, 2

-- Global drawing state (shared across windows)
local strokes, redo_stack = {}, {}
local current_tool = "brush" -- brush | line | eraser | rect | circle
local brush_color = {r=0, g=0, b=0, a=255}
local brush_size = 8
local shape_filled = false
local is_drawing = false
local start_x, start_y, prev_x, prev_y = 0, 0, 0, 0

-- Utilities
local function clamp(v, a, b) if v < a then return a elseif v > b then return b else return v end end
local function in_rect(mx, my, x1, y1, w, h) return mx >= x1 and my >= y1 and mx <= x1 + w and my <= y1 + h end
local function dist(ax, ay, bx, by) local dx, dy = bx-ax, by-ay return math.sqrt(dx*dx + dy*dy) end

local function draw_text_centered(x, y, w, h, text, r, g, b, a)
    draw.Color(r or 230, g or 230, b or 230, a or 255)
    draw.SetFont(ui_font)
    local tw, th = draw.GetTextSize(text)
    draw.Text(x + math.floor((w - tw)/2), y + math.floor((h - th)/2), text)
end

local _btn_anim = {}
local function _lerp(a, b, t) return a + (b - a) * t end
local function button(x, y, w, h, label, active)
    local key = label .. ":" .. x .. ":" .. y
    local anim = _btn_anim[key] or {hover=0, press=0}

    local mx, my = input.GetMousePos()
    local hovered = in_rect(mx, my, x, y, w, h)
    local pressed = hovered and input.IsButtonDown(MOUSE_LEFT)
    local clicked = hovered and input.IsButtonPressed(MOUSE_LEFT)

    -- Animate hover and press values toward targets
    anim.hover = _lerp(anim.hover, hovered and 1 or 0, 0.2)
    anim.press = _lerp(anim.press, pressed and 1 or 0, 0.35)
    _btn_anim[key] = anim

    -- Base
    draw.Color(30, 32, 37, 230)
    draw.RoundedRect(x, y, x + w, y + h, 6, 1, 1, 1, 1)

    -- Hover glow
    if anim.hover > 0.01 then
        local a = math.floor(40 + 80 * anim.hover)
        draw.Color(100, 140, 255, a)
        draw.RoundedRect(x+1, y+1, x + w - 1, y + h - 1, 6, 1, 1, 1, 1)
    end

    -- Press darken/shine
    if anim.press > 0.01 then
        local a = math.floor(60 + 140 * anim.press)
        draw.Color(0, 0, 0, a)
        draw.RoundedRect(x+1, y+1, x + w - 1, y + h - 1, 6, 1, 1, 1, 1)
    end

    -- Border
    local br = active and 120 or 70
    local bg = active and 180 or 80
    local bb = active and 255 or 110
    -- brighten on hover
    br = br + math.floor(60 * anim.hover)
    bg = bg + math.floor(60 * anim.hover)
    bb = bb + math.floor(60 * anim.hover)
    draw.Color(br, bg, bb, 255)
    draw.OutlinedRect(x, y, x + w, y + h)

    -- Text (slight move on press)
    local tx = x
    local ty = y + math.floor(2 * anim.press)
    draw_text_centered(tx, ty, w, h, label)

    return clicked, hovered
end

local function swatch(x, y, size, col, selected)
    draw.Color(col.r, col.g, col.b, 255)
    draw.FilledRect(x, y, x + size, y + size)
    draw.Color(30, 30, 30, 255)
    draw.OutlinedRect(x, y, x + size, y + size)
    if selected then
        draw.Color(255, 255, 255, 255)
        draw.OutlinedRect(x-1, y-1, x + size+1, y + size+1)
    end
    local mx, my = input.GetMousePos()
    local clicked = in_rect(mx, my, x, y, size, size) and input.IsButtonPressed(MOUSE_LEFT)
    return clicked
end

-- Background time and parameters (placed early to be available everywhere)
local bg_time = 0
local bg_speed = 0.03
local bg_mouse_influence = 1.0
local lines = {}
for i=1, 24 do
    lines[i] = {
        x = math.random(), y = math.random(),
        dx = (math.random() * 2 - 1) * 0.05,
        dy = (math.random() * 2 - 1) * 0.05,
        len = math.random(40, 120) / 100
    }
end

-- Ensure rainbow is off by default across reloads
_G.__rainbowify = _G.__rainbowify or false

-- Rainbow helpers
local function rainbow_color(t, alpha)
    local r = math.floor(128 + 127 * math.sin(t))
    local g = math.floor(128 + 127 * math.sin(t + 2.094))
    local b = math.floor(128 + 127 * math.sin(t + 4.188))
    return r, g, b, alpha or 255
end

local function rc(r, g, b, a)
    if _G.__rainbowify then
        local rr, gg, bb, aa = rainbow_color(bg_time * 2.0, a or 255)
        return rr, gg, bb, aa
    end
    return r, g, b, a or 255
end

-- Cursor resize indicator helper
local function draw_resize_cursor_hint(mx, my, grips)
    if not grips then return end
    local size = 10
    draw.Color(120,160,255,220)
    if (grips.left or grips.right) and not (grips.top or grips.bottom) then
        -- Horizontal resize: ↔
        draw.FilledRect(mx - size, my - 1, mx + size, my + 1)
        draw.FilledRect(mx - size, my - 3, mx - size + 3, my + 3)
        draw.FilledRect(mx + size - 3, my - 3, mx + size, my + 3)
    elseif (grips.top or grips.bottom) and not (grips.left or grips.right) then
        -- Vertical resize: ↕
        draw.FilledRect(mx - 1, my - size, mx + 1, my + size)
        draw.FilledRect(mx - 3, my - size, mx + 3, my - size + 3)
        draw.FilledRect(mx - 3, my + size - 3, mx + 3, my + size)
    else
        -- Diagonal: draw an X shape
        for i = -1,1 do
            draw.Line(mx - size, my - size + i, mx + size, my + size + i)
            draw.Line(mx - size, my + size + i, mx + size, my - size + i)
        end
    end
end

-- Stroke rendering
local function draw_circle(x, y, radius)
    draw.FilledCircle(x, y, radius)
end

local function draw_segment(ax, ay, bx, by, radius)
    local length = math.max(1, dist(ax, ay, bx, by))
    local step = math.max(1, math.floor(radius * 0.75))
    local steps = math.floor(length / step)
    for i = 0, steps do
        local t = (steps == 0) and 1 or (i / steps)
        local x = math.floor(ax + (bx - ax) * t + 0.5)
        local y = math.floor(ay + (by - ay) * t + 0.5)
        draw_circle(x, y, radius)
    end
end

local function render_stroke(s, ox, oy)
    ox = ox or 0; oy = oy or 0
    local col = s.color
    if _G.__rainbowify then
        local t = bg_time
        col = { r = math.floor(128 + 127*math.sin(t*2.0)), g = math.floor(128 + 127*math.sin(t*2.0 + 2.094)), b = math.floor(128 + 127*math.sin(t*2.0 + 4.188)), a = col.a or 255 }
    end
    draw.Color(col.r, col.g, col.b, col.a or 255)
    if s.tool == "line" then
        draw_segment(s.x1 + ox, s.y1 + oy, s.x2 + ox, s.y2 + oy, s.size)
        draw_circle(s.x1 + ox, s.y1 + oy, s.size)
        draw_circle(s.x2 + ox, s.y2 + oy, s.size)
    elseif s.tool == "rect" then
        local x1, y1 = s.x1 + ox, s.y1 + oy
        local x2, y2 = s.x2 + ox, s.y2 + oy
        local left, right = math.min(x1,x2), math.max(x1,x2)
        local top, bottom = math.min(y1,y2), math.max(y1,y2)
        if s.filled then
            draw.FilledRect(left, top, right, bottom)
        else
            draw.OutlinedRect(left, top, right, bottom)
        end
    elseif s.tool == "circle" then
        local cx, cy = s.cx + ox, s.cy + oy
        local r = s.r
        if s.filled then
            draw.FilledCircle(cx, cy, r)
        else
            -- approximate outline by stamping small segments
            local steps = math.max(12, math.floor(2 * math.pi * r / 6))
            local prevx, prevy
            for i=0, steps do
                local a = (i/steps) * (2*math.pi)
                local x = cx + math.cos(a) * r
                local y = cy + math.sin(a) * r
                if prevx then draw.Line(prevx, prevy, x, y) end
                prevx, prevy = x, y
            end
        end
    else
        local pts = s.points
        for i = 2, #pts do
            local a, b = pts[i-1], pts[i]
            draw_segment(a.x + ox, a.y + oy, b.x + ox, b.y + oy, s.size)
        end
        if #pts == 1 then draw_circle(pts[1].x + ox, pts[1].y + oy, s.size) end
    end
end

local function begin_stroke(tool, color, size)
    return { tool = tool, color = {r=color.r, g=color.g, b=color.b, a=color.a or 255}, size = size, points = {} }
end

local function add_point_to_stroke(s, x, y, last_x, last_y)
    local need = (#s.points == 0) or (dist(last_x, last_y, x, y) >= math.max(1, s.size * 0.5))
    if need then table.insert(s.points, {x=x, y=y}) end
end

-- Background grid for definition

local function draw_hexagon(cx, cy, r)
    local pts = {}
    for i=0,5 do
        local a = (math.pi/3) * i
        pts[#pts+1] = {x = cx + r * math.cos(a), y = cy + r * math.sin(a)}
    end
    for i=1,6 do
        local a = pts[i]
        local b = pts[(i % 6) + 1]
        draw.Line(math.floor(a.x), math.floor(a.y), math.floor(b.x), math.floor(b.y))
    end
end

local function draw_background()
    local sw, sh = draw.GetScreenSize()
    local mx, my = input.GetMousePos()
    local cx = sw * 0.5
    local cy = sh * 0.5
    local dx = (mx - cx) / math.max(1, sw)
    local dy = (my - cy) / math.max(1, sh)
    bg_time = bg_time + bg_speed + (math.sqrt(dx*dx + dy*dy) * 0.02 * bg_mouse_influence)

    -- Deep space background
    draw.Color(rc(18, 20, 26, 255))
    draw.FilledRect(0, 0, sw, sh)

    -- Animated hex grid
    local hex_r = 24
    local step_x = hex_r * 1.5
    local step_y = hex_r * math.sqrt(3) / 2
    draw.Color(rc(32, 36, 44, 200))
    for y= -hex_r, sh + hex_r, step_y do
        local row = math.floor(y / step_y)
        for x= -hex_r, sw + hex_r, step_x do
            local ox = ((row % 2) == 0) and 0 or hex_r * 0.75
            local jitter = math.sin((x + y) * 0.01 + bg_time) * 1.5
            draw_hexagon(x + ox, y + jitter, hex_r)
        end
    end

    -- Drifting lines layer
    draw.Color(rc(60, 100, 180, 120))
    for _, l in ipairs(lines) do
        local px = l.x * sw
        local py = l.y * sh
        local ex = px + (math.sin(bg_time * 1.5 + l.x * 5) + dx * 6) * l.len * 80
        local ey = py + (math.cos(bg_time * 1.2 + l.y * 5) + dy * 6) * l.len * 80
        draw.Line(math.floor(px), math.floor(py), math.floor(ex), math.floor(ey))
        -- advance (mouse influence nudges velocity)
        l.dx = l.dx + dx * 0.001
        l.dy = l.dy + dy * 0.001
        l.x = (l.x + l.dx * 0.01) % 1
        l.y = (l.y + l.dy * 0.01) % 1
    end
end

-- Window system
local windows = {}
local z_order = {}    -- stores indices into windows in front-to-back order
local active_drag = {idx=nil, offset_x=0, offset_y=0}
local active_resize = {idx=nil, left=false, right=false, top=false, bottom=false, start_mx=0, start_my=0, start_x=0, start_y=0, start_w=0, start_h=0}
local TITLE_H = 30
local RESIZE_BORDER = 6
local MIN_W, MIN_H = 180, 120

local function bring_to_front(idx)
    -- Move idx to end of z_order
    local pos
    for i, v in ipairs(z_order) do if v == idx then pos = i break end end
    if pos then table.remove(z_order, pos) end
    table.insert(z_order, idx)
end

local function begin_window(win, focused, grips)
    local x, y, w, h = win.x, win.y, win.w, win.h
    -- Shadow
    draw.Color(20, 20, 25, 200)
    draw.ShadowRect(x, y, x + w, y + h, 24)

    -- Focus highlight (accent outline) if focused
    if focused then
        draw.Color(rc(100, 140, 255, 180))
        draw.OutlinedRect(x - 1, y - 1, x + w + 1, y + h + 1)
        draw.Color(rc(100, 140, 255, 60))
        draw.OutlinedRect(x - 2, y - 2, x + w + 2, y + h + 2)
    end

    -- Body
    draw.Color(32, 34, 40, 230)
    draw.RoundedRect(x, y, x + w, y + h, 6, 1, 1, 1, 1)
    draw.Color(60, 63, 72, 255)
    draw.OutlinedRect(x, y, x + w, y + h)
    -- Title bar
    if focused then
        draw.Color(66, 99, 205, 255)
    else
        draw.Color(44, 47, 55, 255)
    end
    draw.RoundedRect(x, y, x + w, y + TITLE_H, 6, 1, 1, 0, 0)
    draw.SetFont(title_font)
    if focused then
        draw.Color(240, 245, 255, 255)
    else
        if _G.__rainbowify then
            local r,g,b,a = rainbow_color(bg_time*2.0, 255)
            draw.Color(r,g,b,a)
        else
            draw.Color(225, 228, 235, 255)
        end
    end
    local tw, th = draw.GetTextSize(win.title)
    draw.Text(x + 10, y + math.floor((TITLE_H - th)/2), win.title)

    -- Resize grips/hints when hovering edges/corners
    if grips then
        local accent = {r=120,g=160,b=255,a=180}
        local soft   = {r=120,g=160,b=255,a=60}
        local function line_col(c)
            draw.Color(rc(c.r,c.g,c.b,c.a))
        end
        -- Edge highlights
        if grips.top then line_col(soft); draw.FilledRect(x+8, y, x + w-8, y+2) end
        if grips.bottom then line_col(soft); draw.FilledRect(x+8, y + h - 2, x + w - 8, y + h) end
        if grips.left then line_col(soft); draw.FilledRect(x, y+8, x+2, y + h - 8) end
        if grips.right then line_col(soft); draw.FilledRect(x + w - 2, y+8, x + w, y + h - 8) end
        -- Corner handles (small squares)
        local s = 8
        if grips.top and grips.left then line_col(accent); draw.FilledRect(x-1, y-1, x-1 + s, y-1 + s) end
        if grips.top and grips.right then line_col(accent); draw.FilledRect(x + w - s + 1, y-1, x + w + 1, y - 1 + s) end
        if grips.bottom and grips.left then line_col(accent); draw.FilledRect(x-1, y + h - s + 1, x - 1 + s, y + h + 1) end
        if grips.bottom and grips.right then line_col(accent); draw.FilledRect(x + w - s + 1, y + h - s + 1, x + w + 1, y + h + 1) end
    end
end

local function end_window(win)
    -- nothing for now
end

local function window_client_rect(win)
    return win.x + 8, win.y + TITLE_H + 8, win.w - 16, win.h - TITLE_H - 16
end

-- Palette
local palette = {
    {r=255,g=255,b=255}, {r=0,g=0,b=0}, {r=255,g=0,b=0}, {r=0,g=255,b=0}, {r=0,g=0,b=255},
    {r=255,g=255,b=0}, {r=255,g=0,b=255}, {r=0,g=255,b=255}, {r=128,g=128,b=128}, {r=255,g=128,b=0},
}

-- Create windows
local function init_windows()
    windows = {
        { title = "Canvas", x = 260, y = 90,  w = 900, h = 600, kind = "canvas" },
        { title = "Tools",  x = 20,  y = 90,  w = 220, h = 180, kind = "tools" },
        { title = "Colors", x = 20,  y = 290, w = 220, h = 160, kind = "colors" },
        { title = "History",x = 20,  y = 460, w = 220, h = 180, kind = "history" },
        { title = "Script Controls", x = 0, y = 0, w = 260, h = 200, kind = "controls" },
        { title = "Background Settings", x = 0, y = 0, w = 300, h = 160, kind = "bgsettings" },
    }
    -- Place the controls and bg settings windows bottom-right with dynamic sizing
    local sw, sh = draw.GetScreenSize()
    local ctrl = windows[#windows-1]
    local bgw = windows[#windows]

    -- Desired positions
    ctrl.x = math.max(20, sw - ctrl.w - 20)
    ctrl.y = math.max(20, sh - ctrl.h - 20)
    bgw.x  = math.max(20, sw - bgw.w - 20)
    bgw.y  = math.max(20, ctrl.y - bgw.h - 10)

    -- Clamp within screen
    ctrl.x = math.max(20, math.min(ctrl.x, sw - ctrl.w - 20))
    ctrl.y = math.max(20, math.min(ctrl.y, sh - ctrl.h - 20))
    bgw.x  = math.max(20, math.min(bgw.x,  sw - bgw.w - 20))
    bgw.y  = math.max(20, bgw.y)

    -- If bg settings overlaps top margin, push controls up if possible
    if bgw.y < 20 then
        bgw.y = 20
        ctrl.y = math.max(20, math.min(sh - ctrl.h - 20, bgw.y + bgw.h + 10))
    end

    -- Final guard in case screen is too small
    ctrl.y = math.max(20, math.min(ctrl.y, sh - ctrl.h - 20))
    bgw.y  = math.max(20, math.min(bgw.y,  sh - bgw.h - 20))

    -- Ensure left column windows don't overlap initially
    local tools = windows[2]
    local colors = windows[3]
    local history = windows[4]
    tools.h = math.max(tools.h, 350)
    colors.y = tools.y + tools.h + 14
    history.y = colors.y + colors.h + 14

    -- Restore previous stable z-order: draw left column, then controls, bgsettings, then canvas last
    z_order = {2,3,4,5,6,1}

    -- Optionally add a new Artwork window placeholder (created when first used)
    _G.__art_window_added = _G.__art_window_added or false
end

-- Input handling for dragging and focus
local function handle_window_dragging_and_resizing()
    local mx, my = input.GetMousePos()

    -- Focus management: bring clicked window (anywhere inside) to front
    if input.IsButtonPressed(MOUSE_LEFT) then
        for i = #z_order, 1, -1 do
            local idx = z_order[i]; local w = windows[idx]
            if in_rect(mx, my, w.x, w.y, w.w, w.h) then
                bring_to_front(idx)
                break
            end
        end
    end

    -- On press: prefer starting resize if near edges/corners; otherwise allow dragging via title bar
    if input.IsButtonPressed(MOUSE_LEFT) then
        -- Check topmost window under mouse
        for i = #z_order, 1, -1 do
            local idx = z_order[i]; local w = windows[idx]
            if in_rect(mx, my, w.x, w.y, w.w, w.h) then
                local near_left   = mx >= w.x and mx <= w.x + RESIZE_BORDER
                local near_right  = mx >= w.x + w.w - RESIZE_BORDER and mx <= w.x + w.w
                local near_top    = my >= w.y and my <= w.y + RESIZE_BORDER
                local near_bottom = my >= w.y + w.h - RESIZE_BORDER and my <= w.y + w.h
                if near_left or near_right or near_top or near_bottom then
                    -- Start resize and do NOT also start drag
                    active_resize.idx = idx
                    active_resize.left = near_left; active_resize.right = near_right
                    active_resize.top = near_top; active_resize.bottom = near_bottom
                    active_resize.start_mx, active_resize.start_my = mx, my
                    active_resize.start_x, active_resize.start_y = w.x, w.y
                    active_resize.start_w, active_resize.start_h = w.w, w.h
                    break
                end
                -- Not resizing: allow drag only if inside title bar AND not in top resize zone
                if in_rect(mx, my, w.x, w.y, w.w, TITLE_H) and not near_top then
                    active_drag.idx = idx
                    active_drag.offset_x = mx - w.x
                    active_drag.offset_y = my - w.y
                end
                break
            end
        end
    end

    -- Start resize if pressed near edges/corners of top-most window
    if input.IsButtonPressed(MOUSE_LEFT) then
        for i = #z_order, 1, -1 do
            local idx = z_order[i]; local w = windows[idx]
            if in_rect(mx, my, w.x, w.y, w.w, w.h) then
                local left   = mx >= w.x and mx <= w.x + RESIZE_BORDER
                local right  = mx >= w.x + w.w - RESIZE_BORDER and mx <= w.x + w.w
                local top    = my >= w.y and my <= w.y + RESIZE_BORDER
                local bottom = my >= w.y + w.h - RESIZE_BORDER and my <= w.y + w.h
                if left or right or top or bottom then
                    active_resize.idx = idx
                    active_resize.left = left; active_resize.right = right
                    active_resize.top = top; active_resize.bottom = bottom
                    active_resize.start_mx, active_resize.start_my = mx, my
                    active_resize.start_x, active_resize.start_y = w.x, w.y
                    active_resize.start_w, active_resize.start_h = w.w, w.h
                    break
                end
                break
            end
        end
    end

    -- Continue dragging or resizing
    if input.IsButtonDown(MOUSE_LEFT) then
        if active_drag.idx then
            local w = windows[active_drag.idx]
            local sw, sh = draw.GetScreenSize()
            w.x = clamp(mx - active_drag.offset_x, 0, sw - math.max(MIN_W, w.w))
            w.y = clamp(my - active_drag.offset_y, 0, sh - math.max(MIN_H, w.h))
        elseif active_resize.idx then
            local w = windows[active_resize.idx]
            local dx = mx - active_resize.start_mx
            local dy = my - active_resize.start_my
            local new_x, new_y = w.x, w.y
            local new_w, new_h = active_resize.start_w, active_resize.start_h
            if active_resize.left then
                new_x = active_resize.start_x + dx
                new_w = active_resize.start_w - dx
            elseif active_resize.right then
                new_w = active_resize.start_w + dx
            end
            if active_resize.top then
                new_y = active_resize.start_y + dy
                new_h = active_resize.start_h - dy
            elseif active_resize.bottom then
                new_h = active_resize.start_h + dy
            end
            -- Enforce minimum, and clamp to screen bounds
            local sw, sh = draw.GetScreenSize()
            new_w = math.max(MIN_W, new_w)
            new_h = math.max(MIN_H, new_h)
            new_x = clamp(new_x, 0, sw - new_w)
            new_y = clamp(new_y, 0, sh - new_h)
            -- Apply
            w.x, w.y, w.w, w.h = new_x, new_y, new_w, new_h
        end
    end

    -- End drag/resize
    if input.IsButtonReleased and input.IsButtonReleased(MOUSE_LEFT) then
        active_drag.idx = nil
        active_resize.idx = nil
        active_resize.left = false; active_resize.right = false; active_resize.top = false; active_resize.bottom = false
    end
end

-- Layout measurement helpers for dynamic sizing
local function measure_tools_height(w)
    local _, _, cw, _ = window_client_rect(w)
    local by = 0
    local bh = 28
    -- Buttons: Brush, Line, Eraser, Rect, Circle (5)
    by = by + 5*bh + 4*8 + 4 -- gaps and slight padding
    -- Size row
    by = by + 24 + 12
    -- Filled toggle
    by = by + 24 + 8
    -- Top padding
    by = by + 8
    -- Bottom padding
    by = by + 8
    return by
end

local function measure_colors_height(w)
    local x, y, cw, _ = window_client_rect(w)
    local size = 22
    local gap = 6
    local cols = math.max(1, math.floor(cw / (size + gap)))
    local rows = math.ceil(#palette / cols)
    local by = 0
    -- Title
    by = by + 20
    -- Grid
    if rows > 0 then
        by = by + rows * (size + gap) - gap
    end
    -- Padding
    by = by + 16
    return by
end

local function measure_history_height(w)
    local by = 0
    local bh = 26
    -- Buttons: Undo, Redo, Clear
    by = by + 3*bh + 2*8
    -- Info line
    by = by + 28
    -- Padding
    by = by + 16
    return by
end

local function measure_controls_height(w)
    local by = 0
    -- Title + spacing
    by = by + 20
    -- Four buttons (Toggle UI, Rainbowify, Reset Layout, Unload) with gaps
    by = by + 26 + 8 + 26 + 8 + 26 + 8 + 26
    -- Padding
    by = by + 16
    return by
end

local function autosize_window(w)
    local desired_client_h = nil
    if w.kind == "tools" then
        desired_client_h = measure_tools_height(w)
    elseif w.kind == "colors" then
        desired_client_h = measure_colors_height(w)
    elseif w.kind == "history" then
        desired_client_h = measure_history_height(w)
    elseif w.kind == "controls" then
        desired_client_h = measure_controls_height(w)
    end
    if desired_client_h then
        local padding = 16
        local desired_total_h = TITLE_H + padding + desired_client_h
        if w.h < desired_total_h then
            local sw, sh = draw.GetScreenSize()
            w.h = math.min(sh - 40, math.max(MIN_H, desired_total_h))
        end
    end
end

-- Render content per window kind
local function render_tools(win)
    local x, y, w, h = window_client_rect(win)
    draw.SetFont(ui_font)

    local by, bh = y, 28
    local clicked
    clicked = button(x, by, w, bh, "Brush", current_tool == "brush"); if clicked then current_tool = "brush" end; by = by + bh + 8
    clicked = button(x, by, w, bh, "Line",  current_tool == "line");  if clicked then current_tool = "line" end;   by = by + bh + 8
    clicked = button(x, by, w, bh, "Eraser",current_tool == "eraser");if clicked then current_tool = "eraser" end; by = by + bh + 8
    clicked = button(x, by, w, bh, "Rect",  current_tool == "rect");  if clicked then current_tool = "rect" end;   by = by + bh + 8
    clicked = button(x, by, w, bh, "Circle",current_tool == "circle");if clicked then current_tool = "circle" end; by = by + bh + 12

    draw.Color(200, 200, 210, 255); draw.Text(x, by, "Size: " .. tostring(brush_size))
    local plus = button(x + w - 56, by - 4, 24, 24, "+", false)
    local minus = button(x + w - 28, by - 4, 24, 24, "-", false)
    if plus then brush_size = clamp(brush_size + 1, 1, 96) end
    if minus then brush_size = clamp(brush_size - 1, 1, 96) end

    by = by + 24 + 12
    -- Shape filled toggle
    local filled_label = shape_filled and "Filled: ON" or "Filled: OFF"
    if button(x, by, w, 24, filled_label, shape_filled) then shape_filled = not shape_filled end
end

local function render_colors(win)
    local x, y, w, h = window_client_rect(win)
    draw.SetFont(ui_font)
    draw.Color(200,200,210,255)
    draw.Text(x, y, "Palette:")
    local by = y + 20
    local size = 22
    local gap = 6
    local sx, sy = x, by
    local cols_per_row = math.max(1, math.floor((w) / (size + gap)))
    for i, col in ipairs(palette) do
        local sel = (brush_color.r == col.r and brush_color.g == col.g and brush_color.b == col.b)
        if swatch(sx, sy, size, col, sel) then
            brush_color = {r=col.r, g=col.g, b=col.b, a=255}
        end
        sx = sx + size + gap
        if (i % cols_per_row) == 0 then sx = x; sy = sy + size + gap end
    end
end

local function render_history(win)
    local x, y, w, h = window_client_rect(win)
    draw.SetFont(ui_font)
    local by, bh = y, 26
    if button(x, by, w, bh, "Undo", false) then if #strokes > 0 then table.insert(redo_stack, table.remove(strokes)) end end
    by = by + bh + 8
    if button(x, by, w, bh, "Redo", false) then if #redo_stack > 0 then table.insert(strokes, table.remove(redo_stack)) end end
    by = by + bh + 8
    if button(x, by, w, bh, "Clear", false) then strokes = {}; redo_stack = {} end

    -- Optional: show count
    draw.Color(200,200,210,255)
    draw.Text(x, by + bh + 10, string.format("Strokes: %d, Redo: %d", #strokes, #redo_stack))
end

local function render_canvas(win)
    local cx, cy, cw, ch = window_client_rect(win)

    -- Canvas background
    draw.Color(245, 245, 245, 255)
    draw.FilledRect(cx, cy, cx + cw, cy + ch)
    -- Subtle grid in canvas
    draw.Color(230, 230, 230, 255)
    local cell = 32
    for x = cx, cx+cw, cell do draw.FilledRect(x, cy, x+1, cy+ch) end
    for y = cy, cy+ch, cell do draw.FilledRect(cx, y, cx+cw, y+1) end
    draw.Color(180, 180, 190, 255)
    draw.OutlinedRect(cx, cy, cx + cw, cy + ch)

    local mx, my = input.GetMousePos()
    local hover_canvas = in_rect(mx, my, cx, cy, cw, ch)

    -- Mouse wheel for brush size
    local wheel = input.GetMouseWheelDelta and input.GetMouseWheelDelta() or 0
    if hover_canvas and wheel ~= 0 then brush_size = clamp(brush_size + (wheel > 0 and 1 or -1), 1, 96) end

    -- Begin drawing
    if hover_canvas and input.IsButtonPressed(MOUSE_LEFT) then
        redo_stack = {}
        is_drawing = true
        start_x, start_y = clamp(mx, cx, cx+cw) - cx, clamp(my, cy, cy+ch) - cy
        prev_x, prev_y = start_x, start_y
        if current_tool == "line" then
            -- defer commit until release
        elseif current_tool == "rect" or current_tool == "circle" then
            -- preview only; commit on release
        else
            local color = (current_tool == "eraser") and {r=245, g=245, b=245, a=255} or brush_color
            local s = begin_stroke("brush", color, brush_size)
            table.insert(s.points, {x=start_x, y=start_y})
            table.insert(strokes, s)
        end
    end

    -- Update drawing
    if is_drawing and input.IsButtonDown(MOUSE_LEFT) then
        local x = clamp(mx, cx, cx+cw) - cx; local y = clamp(my, cy, cy+ch) - cy
        if current_tool == "line" or current_tool == "rect" or current_tool == "circle" then
            -- preview only, commit on release
        else
            local s = strokes[#strokes]
            if s then
                add_point_to_stroke(s, x, y, prev_x, prev_y)
                prev_x, prev_y = x, y
            end
        end
    end

    -- End drawing
    if is_drawing and input.IsButtonReleased and input.IsButtonReleased(MOUSE_LEFT) then
        local x = clamp(mx, cx, cx+cw) - cx; local y = clamp(my, cy, cy+ch) - cy
        if current_tool == "line" then
            local color = brush_color
            local s = { tool = "line", x1 = start_x, y1 = start_y, x2 = x, y2 = y, size = brush_size, color = {r=color.r,g=color.g,b=color.b,a=color.a or 255} }
            table.insert(strokes, s)
        elseif current_tool == "rect" then
            local color = brush_color
            local s = { tool = "rect", x1 = start_x, y1 = start_y, x2 = x, y2 = y, filled = shape_filled, color = {r=color.r,g=color.g,b=color.b,a=color.a or 255} }
            table.insert(strokes, s)
        elseif current_tool == "circle" then
            local color = brush_color
            local r = math.floor(math.sqrt((x - start_x)^2 + (y - start_y)^2))
            local s = { tool = "circle", cx = start_x, cy = start_y, r = r, filled = shape_filled, color = {r=color.r,g=color.g,b=color.b,a=color.a or 255} }
            table.insert(strokes, s)
        elseif current_tool == "text" then
            -- Already added at click; nothing to do here
        end
        is_drawing = false
    end

    -- Clip and render strokes into canvas
    draw.SetScissorRect(cx, cy, cw, ch)
    for _, s in ipairs(strokes) do render_stroke(s, cx, cy) end

    -- Live preview for line/shape
    if is_drawing and (current_tool == "line" or current_tool == "rect" or current_tool == "circle") then
        draw.Color(brush_color.r, brush_color.g, brush_color.b, 200)
        local px, py = clamp(mx, cx, cx+cw), clamp(my, cy, cy+ch)
        if current_tool == "line" then
            draw_segment(start_x + cx, start_y + cy, px, py, brush_size)
            draw_circle(start_x + cx, start_y + cy, brush_size)
            draw_circle(px, py, brush_size)
        elseif current_tool == "rect" then
            local left, right = math.min(start_x + cx, px), math.max(start_x + cx, px)
            local top, bottom = math.min(start_y + cy, py), math.max(start_y + cy, py)
            if shape_filled then draw.FilledRect(left, top, right, bottom) else draw.OutlinedRect(left, top, right, bottom) end
        elseif current_tool == "circle" then
            local r = math.floor(math.sqrt((px - (start_x + cx))^2 + (py - (start_y + cy))^2))
            if shape_filled then draw.FilledCircle(start_x + cx, start_y + cy, r) else
                local steps = math.max(12, math.floor(2 * math.pi * r / 6))
                local prevx, prevy
                for i=0, steps do
                    local a = (i/steps) * (2*math.pi)
                    local xx = (start_x + cx) + math.cos(a) * r
                    local yy = (start_y + cy) + math.sin(a) * r
                    if prevx then draw.Line(prevx, prevy, xx, yy) end
                    prevx, prevy = xx, yy
                end
            end
        end
    end

    -- Reset scissor to full screen
    local sw2, sh2 = draw.GetScreenSize()
    draw.SetScissorRect(0, 0, sw2, sh2)

    -- Footer info (clamped inside window)
    draw.SetFont(small_font)
    draw.Color(120, 125, 135, 255)
    local info = string.format("Tool: %s | Size: %d | Color: #%02X%02X%02X | Left-drag to draw | Scroll size", current_tool, brush_size, brush_color.r, brush_color.g, brush_color.b)
    local tw, th = draw.GetTextSize(info)
    local max_w = cw - 8
    if tw > max_w then
        -- truncate and add ellipsis
        local txt = info
        while #txt > 3 do
            txt = string.sub(txt, 1, #txt - 4) .. "..."
            local ttw, _ = draw.GetTextSize(txt)
            if ttw <= max_w then info = txt; break end
        end
    end
    draw.Text(cx + 4, cy + ch - th - 4, info)
end

-- Toggle state with a hotkey (Numpad '*': VK_MULTIPLY = 106)
local ui_open = true
local HOTKEY_TOGGLE = 106

-- Main Draw loop
callbacks.Register("Draw", function()
    if #windows == 0 then init_windows() end

    -- Safety: ensure scissor is reset each frame before any drawing
    do local sw0, sh0 = draw.GetScreenSize(); draw.SetScissorRect(0, 0, sw0, sh0) end

    -- Handle toggle
    if input.IsButtonPressed(HOTKEY_TOGGLE) then
        ui_open = not ui_open
    end

    if not ui_open then
        -- When closed, do not render the paint UI
        return
    end

    -- Background
    draw_background()

    -- Handle dragging/focus before drawing windows so movement is snappy
    handle_window_dragging_and_resizing()

    -- Render windows in z-order
    local mx, my = input.GetMousePos()
    local any_grips = nil
    for n, idx in ipairs(z_order) do
        local w = windows[idx]
        autosize_window(w)
        local focused = (n == #z_order)
        -- Compute hover grips for resize hints
        local grips = nil
        if in_rect(mx, my, w.x, w.y, w.w, w.h) then
            local left   = mx >= w.x and mx <= w.x + RESIZE_BORDER
            local right  = mx >= w.x + w.w - RESIZE_BORDER and mx <= w.x + w.w
            local top    = my >= w.y and my <= w.y + RESIZE_BORDER
            local bottom = my >= w.y + w.h - RESIZE_BORDER and my <= w.y + w.h
            if left or right or top or bottom then
                grips = {left=left, right=right, top=top, bottom=bottom}
                any_grips = grips
            end
        end
        begin_window(w, focused, grips)
        if w.kind == "tools"   then render_tools(w)
        elseif w.kind == "colors" then render_colors(w)
        elseif w.kind == "history" then render_history(w)
        elseif w.kind == "canvas"  then render_canvas(w)
        elseif w.kind == "controls" then
            local x, y, w2, h2 = window_client_rect(w)
            draw.SetFont(ui_font)
            draw.Color(200,200,210,255)
            draw.Text(x, y, "Script Controls:")
            local by, bh = y + 20, 26
            if button(x, by, w2, bh, "Toggle UI (Numpad *)", false) then ui_open = not ui_open end
            by = by + bh + 8
            local rb_label = _G.__rainbowify and "Rainbowify: ON" or "Rainbowify: OFF"
            if button(x, by, w2, bh, rb_label, _G.__rainbowify) then _G.__rainbowify = not _G.__rainbowify end
            by = by + bh + 8
            if button(x, by, w2, bh, "Reset Layout", false) then init_windows() end
            by = by + bh + 8
            if button(x, by, w2, bh, "Unload Script", false) then
                local name = GetScriptName and GetScriptName() or "uitest.lua"
                if UnloadScript then UnloadScript(name) else UnloadScript("workspace/uitest.lua") end
            end
        elseif w.kind == "bgsettings" then
            local x, y, w2, h2 = window_client_rect(w)
            draw.SetFont(ui_font)
            draw.Color(200,200,210,255)
            draw.Text(x, y, "Background Settings:")
            local by = y + 24
            draw.Color(180,180,190,255)
            draw.Text(x, by, string.format("Speed: %.2f", bg_speed))
            local minus = button(x + w2 - 120, by - 6, 26, 24, "-", false)
            local plus  = button(x + w2 - 86,  by - 6, 26, 24, "+", false)
            local reset = button(x + w2 - 52,  by - 6, 48, 24, "Reset", false)
            if minus then bg_speed = math.max(0.0, bg_speed - 0.01) end
            if plus  then bg_speed = math.min(0.2, bg_speed + 0.01) end
            if reset then bg_speed = 0.03 end
            by = by + 32
            draw.Color(180,180,190,255)
            local mi_text = string.format("Mouse Influence: %.2f", bg_mouse_influence)
            if w2 < 240 then mi_text = string.format("Influence: %.2f", bg_mouse_influence) end
            draw.Text(x, by, mi_text)
            local mminus = button(x + w2 - 120, by - 6, 26, 24, "-", false)
            local mplus  = button(x + w2 - 86,  by - 6, 26, 24, "+", false)
            local mreset = button(x + w2 - 52,  by - 6, 48, 24, "Reset", false)
            if mminus then bg_mouse_influence = math.max(0.0, bg_mouse_influence - 0.1) end
            if mplus  then bg_mouse_influence = math.min(3.0, bg_mouse_influence + 0.1) end
            if mreset then bg_mouse_influence = 1.0 end
        end
        end_window(w)
    end

    -- Draw cursor hint on top of everything if hovering a resizable edge/corner
    draw_resize_cursor_hint(mx, my, any_grips)
end)

callbacks.Register("Unload", function()
    print("[uitest.lua] Unloaded.")
end)
