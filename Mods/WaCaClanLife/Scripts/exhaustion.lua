-- Exhaustion (tickets.md 4): a RESOURCE, not a meter to watch (operator 2026-10-28) - it only goes down when your cat
-- DOES something: a pounce on prey (caught or missed: HuntCaught / HuntMissed - hunting by chance), a fight (its end
-- screen / the combat manager's EndCombat); LateFactor x for things done late (LateHour until DawnHour). Walking and
-- exploring cost nothing. Tired / Exhausted: slower, worse at hunting and fighting - so a day's hunting has a limit
-- (one cat can't keep the clan's pile full alone in leaf-bare). Sleep (a rest: the time-skip key) resets it. Kept with
-- the save. Emits TiredFactors(hunt, damage) - hunting.lua folds them into the hunting chance and the combat scaling.
-- config/exhaustion.ini.
local Exhaustion = {}

local WaCa, log, DayNight
local cfg = { on = false, perPounce = 3, perFight = 10, late = 22, dawn = 5, lateFactor = 1.5,
              levels = { { name = "Tired", at = 60, speed = 0.85, hunt = 0.85, damage = 0.9 },
                         { name = "Exhausted", at = 85, speed = 0.65, hunt = 0.6, damage = 0.75 } } }
local CARD = "/Game/Art/UXD/Blueprints/Popups/WBP_GuiPopupCenterMessage.WBP_GuiPopupCenterMessage_C"
local tired = 0
local level = 0                     -- 0 = fresh, 1 = Tired, 2 = Exhausted
local restoredFor

local function card(text)
    pcall(function()
        local c
        for _, x in ipairs(FindAllOf("SwtPlayerController") or {}) do if x:IsValid() and x.Player then c = x end end
        local w = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(c, WaCa.LoadAsset(CARD), c)
        w:AddToViewport(60)
        w.mcGuiTextInfo:SetText(FText(text))
        local name = (w:GetFullName():gsub("^%S+ ", ""))
        ExecuteInGameThreadWithDelay(6000, function()
            local o = StaticFindObject(name)
            if o and o:IsValid() then o:RemoveFromParent() end
        end)
    end)
end

-- the effects of the current level: walking speed through WaCa Core (its one speed for every mod's slow-downs: the
-- cat's time dilation - a sluggish, tired cat), hunting / damage through TiredFactors (WaCa Hunting)
local function apply()
    local l = cfg.levels[level]
    local speed, hunt, damage = 1, 1, 1
    if l then speed, hunt, damage = l.speed, l.hunt, l.damage end
    WaCa.Emit("SpeedFactor", "tired", speed)
    WaCa.Emit("TiredFactors", hunt, damage)
end

local function setTired(value, why)
    tired = math.max(0, math.min(100, value))
    local now = 0
    for i, l in ipairs(cfg.levels) do if tired >= l.at then now = i end end
    if now ~= level then
        local was = level
        level = now
        local l = cfg.levels[level]
        log("exhaustion: %s (%.0f, %s)", l and l.name or "rested", tired, why)
        if now > was then card(now == #cfg.levels and "Your cat is exhausted - it needs sleep." or "Your cat is getting tired.")
        else card("Your cat is rested.") end
        apply()
    end
end

function Exhaustion.Tiredness() return tired end

function Exhaustion.Add(points, why) setTired(tired + points, why or "effort") end

local function sidecar() return WaCa.SlotFile("WaCaExhaustion") end

function Exhaustion.Init(c)
    WaCa, log, DayNight = c.WaCa, c.log, c.DayNight
    local ini = WaCa.ReadIni(c.modDir .. "/config/exhaustion.ini") or {}
    local e = ini["Exhaustion"] or {}
    cfg.on = c.part("Exhaustion", e.On)
    cfg.perPounce = tonumber(e.PerPounce or "") or cfg.perPounce
    cfg.perFight = tonumber(e.PerFight or "") or cfg.perFight
    cfg.late = tonumber(e.LateHour or "") or cfg.late
    cfg.dawn = tonumber(e.DawnHour or "") or cfg.dawn
    cfg.lateFactor = tonumber(e.LateFactor or "") or cfg.lateFactor
    for i, name in ipairs({ "Tired", "Exhausted" }) do
        local sec = ini[name] or {}
        local l = cfg.levels[i]
        l.at = tonumber(sec.At or "") or l.at
        l.speed = tonumber(sec.Speed or "") or l.speed
        l.hunt = tonumber(sec.Hunt or "") or l.hunt
        l.damage = tonumber(sec.Damage or "") or l.damage
    end
    log("exhaustion: %s", cfg.on and "on" or "off")
    if not cfg.on then return end
    -- a thing done: tiredness (x LateFactor late; the hour only when the day / night cycle runs)
    local function did(points, what)
        local h = DayNight and DayNight.Hour()
        local late = h and (h >= cfg.late or h < cfg.dawn)
        setTired(tired + points * (late and cfg.lateFactor or 1), what)
    end
    WaCa.On("HuntCaught", function() did(cfg.perPounce, "a pounce") end)
    WaCa.On("HuntMissed", function() did(cfg.perPounce, "a pounce") end)
    -- a fight's end: its end screen or the combat manager's EndCombat - the second within seconds is the same fight
    -- (the end screen also shows while a world loads - only a fight whose popup opened counts)
    local lastFight, inFight = -100, false
    local function fought()
        if not inFight or os.clock() - lastFight < 5 then return end
        inFight = false
        lastFight = os.clock()
        did(cfg.perFight, "a fight")
    end
    WaCa.Watch("EndCombat", "/Script/SwtAdventure.SwtAdventureCombatManager", "WaCaTiredFight", "post")
    WaCa.On("WaCaTiredFight", fought)
    WaCa.On("TimeSkipped", function() setTired(0, "slept") end)
    WaCa.On("ScreenShown", function(screen)
        local name = screen:GetClass():GetFName():ToString()
        if name == "WBP_GuiPopupCombat_C" then inFight = true end
        if name == "WBP_GuiHudCombatOver_C" then fought() end
        if name:find("^WBP_GuiHudGame") then apply() end
    end)
    WaCa.On("GameSaved", function()
        local slot = WaCa.CurrentSlot()
        if slot and restoredFor ~= slot then
            restoredFor = slot
            local t = (WaCa.ReadIni(sidecar() or "") or {})["Exhaustion"] or {}
            if tonumber(t.Tiredness or "") then setTired(tonumber(t.Tiredness), "as saved") end
        end
        local path = sidecar()
        if path then
            WaCa.WriteIni(path, { Exhaustion = { Tiredness = string.format("%.1f", tired), __order = { "Tiredness" } },
                __order = { "Exhaustion" } }, "; WaCa Clan Life - your cat's tiredness (exhaustion.ini)")
        end
    end)
end

return Exhaustion
