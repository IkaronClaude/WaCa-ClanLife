-- Day / night cycle (tickets.md 4). The game's sky (BP_DayNightSky, one in the world: L_Lights) only switches fixed
-- looks; this moves it through a day: the sun's height (its movable DirectionalLight's pitch), the sun's and the sky
-- light's intensity (dimmed to NightLight at midnight) and the game's own night look (the sky's
-- "PostProcess-night", blended in by weight). config/daynight.ini. One scheduled step every UpdateSeconds while the
-- gameplay HUD is up (an animation step, not a state poll); the sky's own values at the start are the day's.
-- Other modules change the look on top through DayNight.SetLook (weather, seasons) - also with the cycle off.
local DayNight = {}

local WaCa, log, modDir
local cfg = { on = false, dayMinutes = 24, startHour = 8, sunHeight = 60, nightLight = 0.15, nightLook = 1.0, step = 2,
              keep = true, bedHour = nil }
local day = 1                    -- days passed in this save (counted at BedHour - or midnight without one - kept with the hour)
local restoredFor                -- the save slot whose hour was restored
local hour
local base                       -- the sky's own values: sun / sky light intensity, sun yaw, fog, sun colour (+ which sky)
local running, generation = false, 0
-- other modules' changes to the look (weather, seasons): source -> { light, sky, fog = multipliers, color = {R,G,B}
-- multiplier, dayMinutes / nightLight = overrides of the config's }. Applied on top of the cycle, and alone when the
-- cycle is off (the sky's own look then, only dimmed / tinted).
local looks = {}

local function sky()
    for _, s in ipairs(FindAllOf("BP_DayNightSky_C") or {}) do
        if s:IsValid() then return s end
    end
end

-- all looks combined: multipliers multiplied, overrides from the last source that sets one
local function combined()
    local c = { light = 1, sky = 1, fog = 1, color = { 1, 1, 1 } }
    for _, l in pairs(looks) do
        c.light = c.light * (l.light or 1)
        c.sky = c.sky * (l.sky or 1)
        c.fog = c.fog * (l.fog or 1)
        if l.color then for i = 1, 3 do c.color[i] = c.color[i] * l.color[i] end end
        c.dayMinutes = l.dayMinutes or c.dayMinutes
        c.nightLight = l.nightLight or c.nightLight
    end
    return c
end

-- 0 at noon, 1 at midnight, smooth (the sun's elevation curve)
local function nightFactor(h)
    return (1 + math.cos((h - 0) / 24 * 2 * math.pi)) / 2      -- 1 at 0:00, 0 at 12:00
end

-- the sky's own values, once per sky (a new world brings a new sky - never re-read our own changes as the base)
local function readBase(s)
    local owner = s:GetFullName()
    if base and base.owner == owner then return true end
    return pcall(function()
        local dl = s.DirectionalLight
        local col = dl.LightColor
        base = { sun = dl.Intensity, sky = s.SkyLight.Intensity, yaw = dl.RelativeRotation.Yaw,
                 fog = s.ExponentialHeightFog.FogDensity, color = { col.R / 255, col.G / 255, col.B / 255 }, owner = owner }
        log("daynight: the sky's day light: sun %.1f, sky light %.1f, fog %.3f", base.sun, base.sky, base.fog)
    end)
end

local function apply(s)
    local look = combined()
    local light, n = 1, 0
    if cfg.on then
        n = nightFactor(hour)
        local nightLight = look.nightLight or cfg.nightLight
        light = nightLight + (1 - nightLight) * (1 - n)
        local elevation = cfg.sunHeight * math.sin((hour - 6) / 12 * math.pi)      -- up 6:00-18:00, under the horizon at night
        -- (this build's FRotator names its first field "pitch", lower case - a "Pitch" key is silently dropped)
        s.DirectionalLight:K2_SetRelativeRotation({ pitch = -math.max(5, elevation), Yaw = base.yaw + (hour - 12) * 15, Roll = 0 },
            false, {}, true)
        local night = s["PostProcess-night"]
        night.bEnabled = n * cfg.nightLook > 0.01
        night.BlendWeight = n * cfg.nightLook
    end
    local dl = s.DirectionalLight
    dl:SetIntensity(base.sun * light * look.light)
    s.SkyLight:SetIntensity(base.sky * light * look.sky)
    s.ExponentialHeightFog:SetFogDensity(base.fog * look.fog)
    dl:SetLightColor({ R = math.min(1, base.color[1] * look.color[1]), G = math.min(1, base.color[2] * look.color[2]),
        B = math.min(1, base.color[3] * look.color[3]), A = 1 }, true)
end

local function refresh()
    local ok, err = pcall(function()
        local s = sky()
        if s and readBase(s) then apply(s) end
    end)
    if not ok then log("daynight: failed (%s)", tostring(err)) end
end

-- source's change to the look (nil = none): { light = x, sky = x, fog = x, color = {r, g, b}, dayMinutes = m,
-- nightLight = f } - applied at once while the gameplay HUD is up
function DayNight.SetLook(source, look)
    looks[source] = look
    if running or not cfg.on then refresh() end
end

local function dayMinutes()
    return combined().dayMinutes or cfg.dayMinutes
end

-- frozen time (tickets.md "Time freezes at story points"): source -> true; the clock stands still while any is set
local freezes = {}
local ticking = false              -- the clock's step chain is scheduled
local function frozen() return next(freezes) ~= nil end

-- the clock moves on by `hours`: the day's end (DayEnded / DayStarted), every whole hour crossed (HourChanged), the sky
local function advance(hours)
    local before = hour
    hour = (hour + hours) % 24
    -- the day ends at BedHour (midnight without one): DayEnded(day), then DayStarted(day + 1), for other modules
    -- (exhaustion, pacing, seasons, day scripts)
    local endAt = cfg.bedHour or 0
    local crossed
    if hour >= before then crossed = before < endAt and hour >= endAt           -- the same day
    else crossed = before < endAt or hour >= endAt end                     -- past midnight
    if crossed then
        log("daynight: day %d is over (%02d:00)", day, endAt)
        WaCa.Emit("DayEnded", day)
        day = day + 1
        WaCa.Emit("DayStarted", day)
    end
    refresh()
    -- every whole hour crossed, also when one step jumps past several (slow frames, a long UpdateSeconds) - an
    -- hour's scenes / weather countdown must not be skipped
    local whole = math.floor(hour)
    local last = DayNight.lastHour
    if whole ~= last then
        local h = last and (last + 1) % 24 or whole
        for _ = 1, 24 do
            log("daynight: %02d:00", h)
            WaCa.Emit("HourChanged", h, day)
            if h == whole then break end
            h = (h + 1) % 24
        end
        DayNight.lastHour = whole
    end
end

-- one step every UpdateSeconds while the gameplay HUD is up and time isn't frozen (frozen, the chain
-- ends - nothing to animate - and starts again when the last freeze is lifted)
local function step(gen)
    ticking = true
    ExecuteInGameThreadWithDelay(math.floor(cfg.step * 1000), function()
        if gen ~= generation or not running or frozen() then
            if gen == generation then ticking = false end
            return
        end
        advance(cfg.step / (dayMinutes() * 60) * 24)
        step(gen)
    end)
end

-- the clan sim (duties.lua) can DRIVE the clock: no real-time clock then - the cat's activities move it through the
-- day's slots (DayNight.Advance) - and the day turns at its first slot's hour (the morning), not at midnight
local driven = false

local function startClock()
    if driven or not running or ticking or frozen() then return end
    generation = generation + 1
    step(generation)
end

-- other modules stop the clock at story points (a scene, a ceremony - the clan sim decides which):
-- DayNight.Freeze("story", true) ... DayNight.Freeze("story", false)
function DayNight.Freeze(source, on)
    local was = frozen()
    freezes[source] = on and true or nil
    if was ~= frozen() then
        log("daynight: time %s (%s)", frozen() and "stands still" or "runs again", source)
        WaCa.Emit("TimeFrozen", frozen(), source)
        if not frozen() then startClock() end
    end
end
function DayNight.Frozen() return frozen() end

-- the clan sim takes the clock: from now on only DayNight.Advance moves it; days start (and end) at dayStart
function DayNight.Drive(dayStart)
    if not cfg.on then return false end
    driven = true
    generation = generation + 1                  -- a running step chain ends at its next step
    cfg.startHour, cfg.bedHour = dayStart % 24, dayStart % 24
    hour = cfg.startHour
    DayNight.lastHour = math.floor(hour)
    log("daynight: the clan's day drives the clock (days start at %02d:00)", math.floor(cfg.startHour))
    return true
end
function DayNight.Driven() return driven end

-- move the clock on by `hours` (the clan sim): nothing while frozen; false when the cycle is off / frozen
function DayNight.Advance(hours)
    if not cfg.on or frozen() or not hours or hours <= 0 then return false end
    advance(hours)
    return true
end

-- an intentional time skip (tickets.md 20): `days` days pass, the new day starts at `toHour` (default StartHour).
-- Emits DayEnded(fromDay), TimeSkipped(days, fromDay, toDay), then DayStarted(toDay) - the season, weather and prey follow. Returns
-- false when the cycle is off (no day count to move).
function DayNight.Skip(days, toHour)
    if not cfg.on or not days or days < 1 then return false end
    local from = day
    WaCa.Emit("DayEnded", from)                     -- resting ends the day: duties are judged, exhaustion etc. react
    day = day + math.floor(days)
    hour = (toHour or cfg.startHour) % 24
    DayNight.lastHour = math.floor(hour)          -- the skipped hours are not replayed one by one
    log("daynight: %d day(s) pass - day %d -> %d, %02d:00", days, from, day, math.floor(hour))
    WaCa.Emit("TimeSkipped", math.floor(days), from, day)
    WaCa.Emit("DayStarted", day)
    if running then refresh() end
    return true
end

-- the hour now (0-24), or nil when the cycle is off - for other modules (day scripts, pacing)
function DayNight.Hour() return cfg.on and hour or nil end
-- the day number of this save (1 = the first), or nil when the cycle is off
function DayNight.Day() return cfg.on and day or nil end

-- KeepTime: the hour and the day count live with the save (a sidecar next to it, written when the GAME saves - like
-- the game's own progress), restored on the first save after loading a character
local function sidecar() return WaCa.SlotFile("WaCaDayNight") end
local function restore()
    local slotNow = WaCa.CurrentSlot()
    if not cfg.keep or not slotNow or restoredFor == slotNow then return end
    restoredFor = slotNow
    local data = WaCa.ReadIni(sidecar() or "") or {}
    local t = data["Time"] or {}
    if tonumber(t.Hour or "") then
        hour = tonumber(t.Hour) % 24
        day = math.max(1, math.floor(tonumber(t.Day or "") or 1))
        log("daynight: back to day %d, %02d:%02d (as saved)", day, math.floor(hour), math.floor(hour % 1 * 60))
        WaCa.Emit("DayRestored", day)
    end
end
local function keep()
    if not cfg.keep then return end
    local path = sidecar()
    if not path then return end
    WaCa.WriteIni(path, { Time = { Hour = string.format("%.3f", hour), Day = tostring(day), __order = { "Hour", "Day" } },
        __order = { "Time" } }, "; WaCa Clan Life - this save's time of day (daynight.ini KeepTime)")
end

local function isHud(screen) return screen:GetClass():GetFName():ToString():find("^WBP_GuiHudGame") ~= nil end

function DayNight.Init(c)
    WaCa, log, modDir = c.WaCa, c.log, c.modDir
    local ini = WaCa.ReadIni(modDir .. "/config/daynight.ini") or {}
    local d = ini["DayNight"] or {}
    cfg.on = (d.On or "0") == "1"
    cfg.dayMinutes = math.max(1, tonumber(d.DayMinutes or "") or cfg.dayMinutes)
    cfg.startHour = tonumber(d.StartHour or "") or cfg.startHour
    cfg.sunHeight = tonumber(d.SunHeight or "") or cfg.sunHeight
    cfg.nightLight = tonumber(d.NightLight or "") or cfg.nightLight
    cfg.nightLook = tonumber(d.NightLook or "") or cfg.nightLook
    cfg.step = math.max(0.5, tonumber(d.UpdateSeconds or "") or cfg.step)
    hour = cfg.startHour % 24
    cfg.keep = (d.KeepTime or "1") ~= "0"
    cfg.bedHour = tonumber(d.BedHour or "")
    log("daynight: %s (a day = %d min, starting %02d:00)", cfg.on and "on" or "off", cfg.dayMinutes, math.floor(hour))
    if not cfg.on then
        -- no cycle: only other modules' looks, applied when the gameplay HUD shows (a new world's sky = a new base)
        WaCa.On("ScreenShown", function(screen)
            if isHud(screen) and next(looks) then refresh() end
        end)
        return
    end
    WaCa.On("GameSaved", function()
        restore()
        keep()
    end)
    WaCa.On("ScreenShown", function(screen)
        if running or not isHud(screen) then return end
        local s = sky()
        if not s then
            log("daynight: the world has no BP_DayNightSky - no cycle here")
            return
        end
        if not readBase(s) then return end
        running = true
        refresh()
        startClock()
    end)
    WaCa.On("ScreenHidden", function(screen)
        if isHud(screen) then running = false end
    end)
end

return DayNight
