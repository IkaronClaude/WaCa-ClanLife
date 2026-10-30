-- THE DAY CLOCK (tickets.md "Day clock HUD instead of an exhaustion meter", operator 2026-10-28: "a clock with the three
-- times of day rotating through (Cult of the Lamb's day clock), showing where the day is - exhaustion shown through it
-- instead of as a meter"). A dial on the gameplay HUD, top right: a 24-hour face (noon at the top), a mark where each
-- part of the clan's day begins (Morning, Noon, Evening, Night - duties.ini's hours), a needle at the hour, and its
-- middle your cat's tiredness - calm green when rested, amber when Tired, red when Exhausted. No meter, no numbers.
-- Made of the game's own round UI texture in the HUD's canvas (it goes with the HUD - hidden in menus and scenes).
-- Moves on the clock's own events (HourChanged, ClanThird) and on what tires the cat (TiredFactors, a pounce), never
-- polled.
-- clanlife.ini [DayClock] On / Size / Right / Top.
local DayClock = {}

local WaCa, log
local cfg = { on = true, size = 230, right = 230, top = 520 }
local CIRCLE = "/Game/Art/UXD/Textures/TEMP/T_UI_Circle_512x512.T_UI_Circle_512x512"
local THIRDS = { { name = "Morning", hour = 8, color = { R = 1.0, G = 0.78, B = 0.25, A = 1 } },
                 { name = "Noon", hour = 13, color = { R = 1.0, G = 0.97, B = 0.75, A = 1 } },
                 { name = "Evening", hour = 19, color = { R = 1.0, G = 0.5, B = 0.2, A = 1 } },
                 { name = "Night", hour = 23, color = { R = 0.45, G = 0.6, B = 1.0, A = 1 } } }
local parts = {}                 -- name -> widget path (the disc, the marks, the needle, the middle)
local partsHud                   -- the HUD (its full name) they were made in
local status                     -- the latest clan.status

local function widget(name)
    local p = parts[name]
    local w = p and StaticFindObject(p)
    return w and w:IsValid() and w or nil
end

-- the hour the needle shows: the clan's clock (daynight.lua) when it runs, else the start of the third the clan is in
local function hourNow()
    local h
    pcall(function() h = require("daynight").Hour() end)
    if h then return h end
    local third = status and status.third
    for _, t in ipairs(THIRDS) do if t.name == third then return t.hour end end
    return nil
end

-- the middle's colour by tiredness (0 rested .. 100): green -> amber (Tired) -> red (Exhausted)
local function tiredColor()
    local t = 0
    pcall(function() t = require("exhaustion").Tiredness() or 0 end)
    local f = math.max(0, math.min(1, t / 100))
    local r, g, b
    if f < 0.6 then
        local k = f / 0.6
        r, g, b = 0.35 + 0.65 * k, 0.8 - 0.1 * k, 0.45 - 0.3 * k
    else
        local k = (f - 0.6) / 0.4
        r, g, b = 1.0, 0.7 - 0.5 * k, 0.15
    end
    return { R = r, G = g, B = b, A = 0.9 }, t
end

-- an angle (degrees, clockwise from the top) for an hour - noon at the top
local function angleOf(hour) return ((hour - 12) / 24) * 360 end

local function update()
    local needle, middle = widget("needle"), widget("middle")
    if not (needle and middle) then return end
    local h = hourNow()
    if h then
        needle:SetRenderTransformAngle(angleOf(h))
        needle:SetVisibility(4)
    else
        needle:SetVisibility(2)
    end
    local color, t = tiredColor()
    middle:SetColorAndOpacity(color)
    log("day clock: %s, tiredness %.0f", h and string.format("%02d:00", math.floor(h) % 24) or "no hour", t)
end

-- one image in the HUD canvas, centred at the dial's middle + (dx, dy), size w x h
local function image(hud, canvas, name, w, h, dx, dy, textured)
    local img = StaticConstructObject(StaticFindObject("/Script/UMG.Image"), hud.WidgetTree, FName("WaCaDayClock_" .. name))
    local slot = canvas:AddChildToCanvas(img)
    slot:SetAnchors({ Minimum = { X = 1, Y = 0 }, Maximum = { X = 1, Y = 0 } })
    slot:SetAlignment({ X = 0.5, Y = 0.5 })
    slot:SetAutoSize(false)
    slot:SetSize({ X = w, Y = h })
    slot:SetPosition({ X = -cfg.right + dx, Y = cfg.top + dy })
    slot:SetZOrder(40)
    if textured then
        local tex = WaCa.LoadAsset(CIRCLE)
        if tex and tex:IsValid() then img:SetBrushFromTexture(tex, false) end
    end
    img:SetVisibility(4)                         -- (hit-test invisible: never in the way of the HUD's own buttons)
    parts[name] = (img:GetFullName():gsub("^%S+ ", ""))
    return img
end

local function build(hud)
    if not (hud and hud:IsValid()) then return end
    local name = hud:GetFullName()
    if partsHud == name and widget("needle") then return update() end
    local anchor = hud.mcGuiQuestObjective
    local canvas = anchor and anchor:IsValid() and anchor:GetParent()
    if not (canvas and canvas:IsValid() and canvas.AddChildToCanvas) then
        log("day clock: the gameplay HUD has no canvas to draw in - no clock")
        return
    end
    -- (ours from before a reload of the mod: out first)
    for i = canvas:GetChildrenCount() - 1, 0, -1 do
        local c = canvas:GetChildAt(i)
        if c and c:IsValid() and c:GetFName():ToString():find("^WaCaDayClock_") then c:RemoveFromParent() end
    end
    parts = {}
    local s = cfg.size
    local disc = image(hud, canvas, "disc", s, s, 0, 0, true)
    disc:SetColorAndOpacity({ R = 0.05, G = 0.07, B = 0.1, A = 0.6 })
    for _, t in ipairs(THIRDS) do
        local a = math.rad(angleOf(t.hour))
        local r = s * 0.38
        local mark = image(hud, canvas, "mark" .. t.name, s * 0.15, s * 0.15, math.sin(a) * r, -math.cos(a) * r, true)
        mark:SetColorAndOpacity(t.color)
    end
    -- (the needle: a bar from the middle outwards, turned about its foot)
    local needle = image(hud, canvas, "needle", s * 0.035, s * 0.36, 0, -s * 0.18, false)
    needle:SetColorAndOpacity({ R = 0.95, G = 0.92, B = 0.85, A = 0.95 })
    needle:SetRenderTransformPivot({ X = 0.5, Y = 1 })
    image(hud, canvas, "middle", s * 0.26, s * 0.26, 0, 0, true)
    partsHud = name
    log("day clock: on the HUD (%d units, %d from the right, %d from the top)", s, cfg.right, cfg.top)
    update()
end

local function hudNow()
    for _, sc in ipairs(FindAllOf("SwtScreen") or {}) do
        if sc:IsValid() and sc:IsInViewport() and sc:GetClass():GetFName():ToString():find("^WBP_GuiHudGame") then return sc end
    end
end

function DayClock.Init(c)
    WaCa, log = c.WaCa, c.log
    local d = (WaCa.ReadIni(c.modDir .. "/config/clanlife.ini") or {})["DayClock"] or {}
    cfg.on = (d.On or "1") ~= "0"
    cfg.size = tonumber(d.Size or "") or cfg.size
    cfg.right = tonumber(d.Right or "") or cfg.right
    cfg.top = tonumber(d.Top or "") or cfg.top
    if not cfg.on then
        log("day clock: off (clanlife.ini [DayClock] On = 0)")
        return
    end
    local function refresh() ExecuteInGameThread(function() pcall(update) end) end
    WaCa.On("ScreenShown", function(screen)
        local ok, name = pcall(function() return screen:GetClass():GetFName():ToString() end)
        if not (ok and name:find("^WBP_GuiHudGame")) then return end
        local ok2, err = pcall(build, screen)
        if not ok2 then log("day clock: %s", tostring(err)) end
    end)
    WaCa.Subscribe("clan.status", function(s)
        status = s
        if not widget("needle") then
            ExecuteInGameThread(function() pcall(build, hudNow()) end)
        else
            refresh()
        end
    end)
    WaCa.On("HourChanged", refresh)
    WaCa.On("ClanThird", refresh)
    WaCa.On("TiredFactors", refresh)
    WaCa.On("HuntCaught", refresh)                   -- (a pounce tires the cat: the middle's colour follows)
    WaCa.On("HuntMissed", refresh)
end

return DayClock
