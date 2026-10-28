-- Intentional time skips (tickets.md 20): time passes on purpose and on screen, never implied by a story jump. A skip
-- moves the save's day count (DayNight.Skip) - the season, weather and prey follow through their events - and shows
-- a card ("A quarter moon passes...") on the game's own centre-message popup (WBP_GuiPopupCenterMessage, re-texted).
-- config/timeskip.ini: the rest key (skip to the next morning / by Days), the card's text and how long it shows.
-- Other modules / day scripts call TimeSkip.Skip(days).
local TimeSkip = {}

local WaCa, log, DayNight, Weather
local cfg = { on = false, key = nil, days = 1, hour = nil, seconds = 6, title = "" }
local CARD = "/Game/Art/UXD/Blueprints/Popups/WBP_GuiPopupCenterMessage.WBP_GuiPopupCenterMessage_C"
local card                       -- the card on screen (its full name: held objects can go stale)

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

local function hideCard()
    if not card then return end
    local w = StaticFindObject(card)
    card = nil
    if w and w:IsValid() then pcall(function() w:RemoveFromParent() end) end
end

-- the card: the game's centre-message popup with our text, for cfg.seconds
local function showCard(text)
    hideCard()
    local ok, err = pcall(function()
        local class = WaCa.LoadAsset(CARD)
        local controller = pc()
        if not class or not controller then error("no popup class / player") end
        local w = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(controller, class, controller)
        w:AddToViewport(60)
        -- after AddToViewport: its construct fills the text from its own string table key (empty here)
        w.mcGuiTextInfo:SetText(FText(text))
        pcall(function() w.CanvasMessage:SetVisibility(0) end)
        pcall(function() if w.MainAnimation then w:PlayAnimation(w.MainAnimation, 0, 1, 0, 1, false) end end)
        card = (w:GetFullName():gsub("^%S+ ", ""))
        local mine = card
        ExecuteInGameThreadWithDelay(math.floor(cfg.seconds * 1000), function() if card == mine then hideCard() end end)
    end)
    if not ok then log("timeskip: the card couldn't show (%s)", tostring(err)) end
end

-- skip `days` days (the new day starts at WakeHour)
function TimeSkip.Skip(days)
    if DayNight.Skip(days, cfg.hour) then return true end
    log("timeskip: no day / night cycle (daynight.ini On = 0) - nothing to skip")
    return false
end

function TimeSkip.Init(c)
    WaCa, log, DayNight, Weather = c.WaCa, c.log, c.DayNight, c.Weather
    local ini = WaCa.ReadIni(c.modDir .. "/config/timeskip.ini") or {}
    local t = ini["TimeSkip"] or {}
    cfg.on = (t.On or "0") == "1"
    cfg.key = (t.RestKey or "") ~= "" and t.RestKey or nil
    cfg.days = math.max(1, math.floor(tonumber(t.RestDays or "") or 1))
    cfg.hour = tonumber(t.WakeHour or "")
    cfg.seconds = tonumber(t.CardSeconds or "") or cfg.seconds
    cfg.title = t.Card or "{DAYS} passes. It is {SEASON}."
    log("timeskip: %s (rest key %s: %d day(s))", cfg.on and "on" or "off", tostring(cfg.key), cfg.days)
    if not cfg.on then return end
    local pending
    WaCa.On("TimeSkipped", function(days, from, to)
        -- the card after the season / weather moved on (they react to DayStarted, emitted right after this)
        pending = { days, from, to }
        ExecuteInGameThread(function()
            if not pending then return end
            local p = pending
            pending = nil
            showCard(fill(cfg.title, p[1], p[2], p[3]))
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
