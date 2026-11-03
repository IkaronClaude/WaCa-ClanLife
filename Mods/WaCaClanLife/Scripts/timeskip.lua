-- Intentional time skips (tickets.md 20): time passes on purpose and on screen, never implied by a story jump. A skip
-- moves the save's day count (DayNight.Skip) - the season, weather and prey follow through their events - and shows
-- a card ("A quarter moon passes...") on the game's own centre-message popup (WBP_GuiPopupCenterMessage, re-texted).
-- config/timeskip.ini: the rest key (skip to the next morning / by Days), the card's text and how long it shows.
-- Other modules / day scripts call TimeSkip.Skip(days).
local TimeSkip = {}

local WaCa, log, DayNight, Weather
local cfg = { on = false, key = nil, days = 1, hour = nil, seconds = 6, title = "", fade = 1.5, summary = true }
local before                      -- the world before a skip: { season, weather, story, packs = { name -> day } }
-- DEFINED SKIPS (operator 2026-11-03): timeskip.ini / a pack's content/timeskip.ini [Skip.<Name>] Days, Pile (the
-- fresh-kill pile's value after it), Card (its own text) - played with WaCa.Emit("SkipDays", "<Name>") or the scene
-- step Skip: <Name>; a number = that many days. Duties put on a skip are not run - the story check warns.
local skips = {}
local pendingDef

local function pc()
    for _, c in ipairs(FindAllOf("SwtPlayerController") or {}) do
        if c:IsValid() and c.Player then return c end
    end
end

local function fill(s, days, from, to)
    local season = Weather and Weather.Season() or nil
    local weather = Weather and Weather.Current() or nil
    local n = days == 1 and "A day" or string.format("%d days", days)
    if days == 7 then n = "A quarter moon" elseif days == 14 then n = "Half a moon" elseif days == 28 or days == 30 then n = "A moon" end
    return (s:gsub("{DAYS}", n):gsub("{PASS}", (n:find("^%d") and "pass" or "passes")):gsub("{DAY}", tostring(to)):gsub("{SEASON}", season or "")
        :gsub("{WEATHER}", weather and weather:lower() or ""))
end

-- the card: the game's centre-message popup with our text, for cfg.seconds
local function showCard(text)
    -- (the mod's one card queue - events.lua: never two cards at once; at dawn this one came on top of the day's verdict)
    require("events").Card(text, cfg.seconds)
end

-- WHAT HAPPENED (tickets.md 20, 2026-11-03 - "with what happened in it"): what the skip actually changed - the season,
-- the weather, how far the main story and each pack's own story moved. Only what changed; nothing made up (eating
-- from the pile, duties resolved by standing: rules the operator hasn't set).
local function snapshot()
    local okD, Days = pcall(require, "days")
    local s = { season = Weather and Weather.Season() or nil, weather = Weather and Weather.Current() or nil, packs = {} }
    if okD and Days.IsOn and Days.IsOn() then
        s.story = Days.Story()
        for _, pk in ipairs(Days.Packs and Days.Packs() or {}) do s.packs[pk.name] = pk.day end
    end
    return s
end
local function happened(was, now)
    local out = {}
    if was and now.season and was.season ~= now.season then out[#out + 1] = string.format("%s has come.", now.season) end
    if was and now.weather and was.weather ~= now.weather then
        out[#out + 1] = string.format("The weather turned: %s.", now.weather:lower())
    end
    if was and now.story and was.story and now.story ~= was.story then
        out[#out + 1] = string.format("The clan's story moved on (day %d).", now.story)
    end
    for name, day in pairs(now.packs) do
        if was and was.packs[name] and was.packs[name] ~= day then out[#out + 1] = string.format("%s: day %d.", name, day) end
    end
    return out
end

-- skip `days` days (the new day starts at WakeHour)
function TimeSkip.Skip(days)
    before = snapshot()
    -- (the day's basic hunt / patrol set aside - not missed: operator 2026-11-03)
    pcall(function() require("duties").SkipBasic("time skips ahead") end)
    if DayNight.Skip(days, cfg.hour) then return true end
    before = nil
    log("timeskip: no day / night cycle (daynight.ini On = 0) - nothing to skip")
    return false
end

function TimeSkip.Init(c)
    WaCa, log, DayNight, Weather = c.WaCa, c.log, c.DayNight, c.Weather
    local ini = WaCa.ReadIni(c.modDir .. "/config/timeskip.ini") or {}
    local t = ini["TimeSkip"] or {}
    cfg.on = c.part("TimeSkip", t.On)
    cfg.key = (t.RestKey or "") ~= "" and t.RestKey or nil
    if cfg.on and cfg.key then cfg.key = WaCa.ModKey("ClanLife", "Rest", cfg.key, "rest (a day passes)") end
    cfg.days = math.max(1, math.floor(tonumber(t.RestDays or "") or 1))
    cfg.hour = tonumber(t.WakeHour or "")
    cfg.seconds = tonumber(t.CardSeconds or "") or cfg.seconds
    cfg.title = t.Card or "{DAYS} passes. It is {SEASON}."
    cfg.fade = tonumber(t.Fade or "") or cfg.fade
    cfg.summary = (t.Summary or "1") ~= "0"
    log("timeskip: %s (rest key %s: %d day(s))", cfg.on and "on" or "off", tostring(cfg.key), cfg.days)
    if not cfg.on then return end
    -- (other mods skip time the same way - their Lua isn't this one: WaCa.Emit("SkipDays", n))
    local cs = WaCa.ReadContent(c.modDir .. "/config/timeskip.ini", "timeskip") or {}
    for section, sec in pairs(cs) do
        local name = type(sec) == "table" and tostring(section):match("^Skip%.(.+)$")
        if name and tonumber(sec.Days or "") then
            skips[name] = { name = name, days = math.max(1, math.floor(tonumber(sec.Days))), pile = tonumber(sec.Pile or ""),
                            card = (sec.Card or "") ~= "" and sec.Card or nil }
        end
    end
    WaCa.On("SkipDays", function(n)
        ExecuteInGameThread(function()
            local def = skips[tostring(n)]
            if def then
                pendingDef = def
                log("timeskip: the skip %s - %d day(s)%s", def.name, def.days, def.pile and (", the pile to " .. def.pile) or "")
                TimeSkip.Skip(def.days)
            elseif tonumber(n) and tonumber(n) >= 1 then
                TimeSkip.Skip(math.floor(tonumber(n)))
            else
                log("timeskip: no skip '%s' (timeskip.ini [Skip.<Name>], or a number of days)", tostring(n))
            end
        end)
    end)
    local pending
    WaCa.On("TimeSkipped", function(days, from, to)
        -- the card after the season / weather moved on (they react to DayStarted, emitted right after this)
        pending = { days, from, to }
        ExecuteInGameThread(function()
            if not pending then return end
            local p = pending
            pending = nil
            local lines = cfg.summary and happened(before, snapshot()) or {}
            before = nil
            local def = pendingDef
            pendingDef = nil
            if def and def.pile then
                local ok, v = pcall(function() return require("duties").SetPile(def.pile) end)
                if ok and v then lines[#lines + 1] = string.format("The fresh-kill pile: %d.", math.floor(v + 0.5)) end
                log("timeskip: %s - the fresh-kill pile set to %s%s", def.name, tostring(def.pile), (ok and v) and "" or " - FAILED")
            end
            local title = fill(def and def.card or cfg.title, p[1], p[2], p[3])
            log("timeskip: %s%s", title, #lines > 0 and (" - " .. table.concat(lines, " ")) or "")
            if cfg.fade <= 0 then
                showCard(title .. (#lines > 0 and ("\n" .. table.concat(lines, "\n")) or ""))
                return
            end
            -- (THE CARD AS A SCENE: the world fades to black, the card - and what happened - over it, the world back;
            -- the steps of events.lua, so other scenes wait their turn)
            local steps = { { kind = "Fade", value = tostring(cfg.fade) }, { kind = "Card", value = title } }
            if #lines > 0 then steps[#steps + 1] = { kind = "Card", value = table.concat(lines, "\n") } end
            steps[#steps + 1] = { kind = "FadeIn", value = tostring(cfg.fade) }
            require("events").Run(steps)
        end)
    end)
    if cfg.key then
        WaCa.On("KeyDown", function(_, name)
            -- only in the world: not in a menu, the player's cat is there
            local c = pc()
            if tostring(name) ~= cfg.key or WaCa.InMenu() or not (c and c.Pawn and c.Pawn:IsValid()) then return end
            log("timeskip: your cat rests (%s)", cfg.key)
            TimeSkip.Skip(cfg.days)
        end)
    end
end

return TimeSkip
