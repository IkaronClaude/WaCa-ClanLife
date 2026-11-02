-- The story as days (tickets.md 25): the story is data - config/days.ini, one [Day.N] per story day. A story day sets
-- its scenes per phase (Morning / Afternoon / Evening, at the [Days] phase hours: a card and / or one of the game's
-- conversations - events.lua plays them), the day's duties (duties.lua; instead of the clan's needs), its season and
-- weather chances (weather.lua), and the condition to move on (Advance). Until that holds the story day REPEATS:
-- same setup, minus the scenes already seen. Like = M copies day M's keys (only the ones it doesn't set itself).
-- The story day lives with the save (a sidecar). Needs the day / night cycle (its DayStarted / HourChanged).
--   Advance = Always | Duties (all of the day's duties done) | Rank:<Name> (the cat's rank reached, e.g. Rank:Warrior)
--   Morning / Afternoon / Evening = Card: <text>  or  Dialogue: <SequenceDialogueId>  (both: two lines, Morning2 ...)
--   Advance = If: <conditions>   the story's variables (events.lua's: "SawLoner = 1, Day >= 3")
--
-- A PACK'S OWN STORY (tickets.md "Mod stories", the design refined with the operator 2026-10-28; built 2026-11-02): a
-- pack's content/story.ini - [Story] Name / Priority, and its own [Day.N] (the same keys) - is a story of its own,
-- with ITS OWN DAY COUNTER and its own Advance: each story is judged at the same calendar boundary (DayStarted), and a
-- story whose condition isn't met repeats its day; stories never read each other's day numbers. Its beats play after
-- the main story's in each phase (packs by Priority, lower first). The day's setup (duties, season, weather) stays
-- the main story's.
--   SYNC POINTS: a day with Sync = <Name> is a barrier - the story repeats that day until EVERY story that declares a
--   day with that Sync is on it and ready (its Advance met); then they cross together. No repeat limit: a long wait is
--   the normal case. (Against the game's own quests the barrier can't hold - not built yet.)
--   Owns = Morning[, Noon, Evening, Night] + <Third>Duty = <duty>: the pack's day takes that third's task.
--   Goal = <text>: the story's own panel on the HUD that day (its Name and the goal).
local Days = {}

local WaCa, log, DayNight, Weather, Duties, Events
local cfg = { on = false, phases = { Morning = 7, Afternoon = 13, Evening = 19 }, days = {} }
local story = 1                    -- the story day the save is on
local seen = {}                    -- scenes played on this story day (repeats skip them): "Morning1" = true
local lastJudged                   -- the last DutiesJudged result: { done, missed }
local restoredFor
local packs = {}                   -- a pack's own story: { name, mod, priority, days = { [n] = section }, day, seen }

-- a key of story day n of a story's days, following Like chains
local function getIn(days, n, key, depth)
    local d = days[n]
    if not d or (depth or 0) > 20 then return nil end
    if d[key] == "none" then return nil end           -- "none": nothing, not even what the Like day sets
    if d[key] ~= nil and d[key] ~= "" then return d[key] end
    if d.Like then return getIn(days, tonumber(d.Like), key, (depth or 0) + 1) end
    return nil
end
local function get(n, key, depth) return getIn(cfg.days, n, key, depth) end

-- a phase's scenes of story day n: any scene step (events.lua: Card / Dialogue / Fade / Bond / Hook ...), in order;
-- Noon also reads the older Afternoon keys
local function scenesIn(days, n, phase)
    local out = {}
    local keys = { phase }
    if phase == "Noon" then table.insert(keys, "Afternoon") end
    for _, base in ipairs(keys) do
        -- (all numbers, not 1-9: a day with more beats - or a pack's beats added to it - lost its end silently)
        local suffixes = { "" }
        for i = 1, 99 do suffixes[#suffixes + 1] = tostring(i) end
        for _, suffix in ipairs(suffixes) do
            local v = getIn(days, n, base .. suffix)
            local step = v and Events and Events.Parse(v)
            if step then
                step.key = base .. suffix
                table.insert(out, step)
            end
        end
    end
    return out
end
local function scenesOf(n, phase) return scenesIn(cfg.days, n, phase) end

-- the clan loop's hook point (duties.lua): the story day's beats for a phase not seen yet on this story day - Morning /
-- Noon / Evening / Night (at that third's end, after the task's turn-in) and MorningStart / NoonStart / EveningStart /
-- NightStart (when the third begins, before the deputy) - marked seen
function Days.Beats(phase)
    local out = {}
    if not cfg.on then return out end
    for _, step in ipairs(scenesOf(story, phase)) do
        if not seen[step.key] then
            seen[step.key] = true
            log("days: story day %d, %s: %s %s", story, step.key, step.kind, tostring(step.value))
            table.insert(out, step)
        end
    end
    -- (then each pack's own story, by Priority)
    for _, pk in ipairs(packs) do
        for _, step in ipairs(scenesIn(pk.days, pk.day, phase)) do
            if not pk.seen[step.key] then
                pk.seen[step.key] = true
                log("days: %s day %d, %s: %s %s", pk.name, pk.day, step.key, step.kind, tostring(step.value))
                table.insert(out, step)
            end
        end
    end
    return out
end

-- the day's setup: duties, season / weather
local function setUp(why)
    if not cfg.days[story] then
        log("days: story day %d has no [Day.%d] - the clan's needs decide", story, story)
        if Duties then Duties.Plan(nil, nil) end
        return
    end
    local hunt, patrol = tonumber(get(story, "Hunt") or ""), tonumber(get(story, "Patrol") or "")
    -- the story's activity per slot of the clan's day (MorningDuty = Train, NightDuty = Hunt: a night hunt ...)
    local kinds, chances
    for _, slot in ipairs({ "Morning", "Noon", "Evening", "Night" }) do
        local k = get(story, slot .. "Duty") or (slot == "Noon" and get(story, "AfternoonDuty")) or nil
        if k then
            kinds = kinds or {}
            kinds[slot] = k
        end
        -- (the story day's chances instead of the clan's: MorningDuties = Hunt:3, Patrol:1)
        local c = get(story, slot .. "Duties")
        if c then
            chances = chances or {}
            chances[slot] = c
        end
    end
    -- (a pack's story day can take a third's task: Owns = Morning[, Night] + MorningDuty = <duty> - the main story's
    -- task for that third gives way; two packs claiming one third = the first by Priority, the other reported)
    local owner = {}
    for _, pk in ipairs(packs) do
        for slot in tostring(getIn(pk.days, pk.day, "Owns") or ""):gmatch("[%a]+") do
            local k = getIn(pk.days, pk.day, slot .. "Duty")
            if not k then
                log("days: %s day %d owns the %s but sets no %sDuty - nothing taken", pk.name, pk.day, slot, slot)
            elseif owner[slot] then
                log("days: CONFLICT - %s and %s both own the %s today; %s's %s plays", owner[slot], pk.name, slot,
                    owner[slot], kinds[slot])
            else
                kinds = kinds or {}
                owner[slot], kinds[slot] = pk.name, k
                log("days: %s owns the %s today - %s", pk.name, slot, k)
            end
        end
    end
    if Duties then Duties.Plan(hunt, patrol, kinds, chances, get(story, "Events"), get(story, "NoEvents")) end
    if Weather then Weather.SetDay(get(story, "Season"), get(story, "Weather")) end
    log("days: story day %d (%s) - duties hunt %s / patrol %s, season %s, weather %s, advance on %s", story, why,
        tostring(hunt or "by needs"), tostring(patrol or "by needs"), tostring(get(story, "Season") or "by days"),
        tostring(get(story, "Weather") or "the season's"), tostring(get(story, "Advance") or "Always"))
    -- (what the day holds - its events and its beats per phase, every file's (a pack's added ones too): a writer sees
    -- the day as it will play; library exercise 2026-11-02)
    local parts = {}
    if get(story, "Events") then parts[#parts + 1] = "events " .. get(story, "Events") end
    if get(story, "NoEvents") then parts[#parts + 1] = "no events " .. get(story, "NoEvents") end
    for _, ph in ipairs({ "Morning", "Noon", "Evening", "Night" }) do
        for _, kind in ipairs({ "Start", "", "After" }) do
            local steps = scenesOf(story, ph .. kind)
            if #steps > 0 then
                local keys = {}
                for _, st in ipairs(steps) do keys[#keys + 1] = st.key .. (seen[st.key] and " (seen)" or "") end
                parts[#parts + 1] = table.concat(keys, ", ")
            end
        end
    end
    log("days: story day %d holds: %s", story, #parts > 0 and table.concat(parts, "; ") or "no beats or events")
    -- (and each pack's own story day)
    for _, pk in ipairs(packs) do
        local keys = {}
        for _, ph in ipairs({ "Morning", "Noon", "Evening", "Night" }) do
            for _, kind in ipairs({ "Start", "", "After" }) do
                for _, st in ipairs(scenesIn(pk.days, pk.day, ph .. kind)) do
                    keys[#keys + 1] = st.key .. (pk.seen[st.key] and " (seen)" or "")
                end
            end
        end
        log("days: %s day %d holds: %s%s", pk.name, pk.day, #keys > 0 and table.concat(keys, ", ") or "no beats",
            getIn(pk.days, pk.day, "Sync") and (" - the sync point " .. getIn(pk.days, pk.day, "Sync")) or "")
        -- (ON THE HUD: a story day's Goal = <text> shows as the story's own panel - its name and the goal - until a day
        -- without one; WaCa Core draws it with the others. The game's quest list itself: not yet)
        if WaCa.HudPanel then
            local goal = getIn(pk.days, pk.day, "Goal")
            pcall(WaCa.HudPanel, "WaCaClanLife.story." .. pk.mod, goal and { title = pk.name, activity = goal, order = 60 } or nil)
        end
    end
end

local function rankValue(name)
    local v
    pcall(function()
        StaticFindObject("/Script/SwtQuest.ECharacterRank"):ForEachName(function(n, val)
            if n:ToString():gsub("^.*::", "") == name then v = val end
        end)
    end)
    return v
end

-- did a story day's condition hold?
local function advancesIn(days, n)
    local a = getIn(days, n, "Advance") or "Always"
    if a == "Always" then return true end
    local cond = a:match("^If:%s*(.+)$")
    if cond then return Events ~= nil and Events.Check(cond) end
    if a == "Duties" then return lastJudged and lastJudged.missed == 0 and lastJudged.done > 0 end
    local rank = a:match("^Rank:%s*(%a+)$")
    if rank then
        local r = WaCa.PlayerRank()
        return r and rankValue(rank) and r >= rankValue(rank) or false
    end
    return false
end

-- every story: the main one (days.ini) and each pack's
local function stories()
    local out = { { name = "the main story", days = cfg.days, day = story, main = true } }
    for _, pk in ipairs(packs) do out[#out + 1] = { name = pk.name, days = pk.days, day = pk.day, pack = pk } end
    return out
end
-- the stories that declare sync point <name> (a day with Sync = name) and the day they declare it on
local function syncDays(name, all)
    local out = {}
    for _, st in ipairs(all) do
        for n, sec in pairs(st.days) do
            if type(sec) == "table" and sec.Sync and sec.Sync:match("^%s*(.-)%s*$") == name then
                out[#out + 1] = { st = st, at = n }
            end
        end
    end
    return out
end
-- the new day: each story on or repeating - a sync day only when every story declaring it is there and ready
local function newDay()
    local all = stories()
    local go = {}
    for i, st in ipairs(all) do go[i] = advancesIn(st.days, st.day) end
    local held = {}
    for i, st in ipairs(all) do
        local sync = getIn(st.days, st.day, "Sync")
        if sync and go[i] then
            local waiting = {}
            for _, e in ipairs(syncDays(sync, all)) do
                local ready = false
                for j, other in ipairs(all) do
                    if other == e.st then ready = other.day == e.at and go[j] end
                end
                if not ready then
                    waiting[#waiting + 1] = string.format("%s (day %d, the sync is its day %d)", e.st.name, e.st.day, e.at)
                end
            end
            if #waiting > 0 then
                held[i] = true
                log("days: %s waits at the sync point %s (its day %d) for %s", st.name, sync, st.day,
                    table.concat(waiting, ", "))
            end
        end
    end
    for i, st in ipairs(all) do
        if go[i] and not held[i] then
            if st.main then story, seen = story + 1, {} else st.pack.day, st.pack.seen = st.pack.day + 1, {} end
            log("days: %s - on to day %d", st.name, st.day + 1)
        elseif not held[i] then
            log("days: %s - day %d repeats (%s not met)", st.name, st.day, getIn(st.days, st.day, "Advance") or "?")
        end
    end
end

-- the packs' own stories: <Mod>/content/story.ini of every enabled mod
local function readPacks(modDir)
    local modsDir = modDir:match("^(.*)[/\\][^/\\]+$") or modDir
    for _, mod in ipairs(WaCa.EnabledMods(modsDir)) do
        local ini = WaCa.ReadIni(modsDir .. "/" .. mod .. "/content/story.ini")
        local st = ini and ini["Story"]
        if st then
            local pk = { name = (st.Name or "") ~= "" and st.Name or mod, mod = mod, priority = tonumber(st.Priority or "") or 100,
                         days = {}, day = 1, seen = {} }
            local n = 0
            for section, sec in pairs(ini) do
                local num = tonumber(tostring(section):match("^Day%.(%d+)$") or "")
                if num then pk.days[num] = sec n = n + 1 end
            end
            packs[#packs + 1] = pk
            log("days: %s's own story '%s' - %d day(s), priority %d", mod, pk.name, n, pk.priority)
        end
    end
    table.sort(packs, function(a, b) if a.priority ~= b.priority then return a.priority < b.priority end return a.mod < b.mod end)
end
function Days.Packs() return packs end

function Days.Story() return story end
-- the story moved to day n (a story pack's start, start.lua): its beats from now on, kept with the save
function Days.SetStory(n, why)
    if not cfg.on or not tonumber(n) then return false end
    story = math.max(1, math.floor(tonumber(n)))
    seen = {}
    log("days: story day %d (%s)", story, why or "set")
    setUp(why or "set")
    return true
end
-- a key of the current story day (Like chains followed) - other features' story overrides (gatherings.ini ...)
function Days.Get(key) return cfg.on and get(story, key) or nil end
function Days.IsOn() return cfg.on end

local function sidecar() return WaCa.SlotFile("WaCaDays") end

function Days.Init(c)
    WaCa, log, DayNight = c.WaCa, c.log, c.DayNight
    Weather, Duties, Events = c.Weather, c.Duties, c.Events
    local ini = WaCa.ReadContent(c.modDir .. "/config/days.ini", "days") or {}
    local d = ini["Days"] or {}
    cfg.on = c.part("Days", d.On)
    for name in pairs(cfg.phases) do cfg.phases[name] = tonumber(d[name .. "Hour"] or "") or cfg.phases[name] end
    local n = 0
    for section, sec in pairs(ini) do
        local num = tonumber(section:match("^Day%.(%d+)$") or "")
        if num then cfg.days[num] = sec n = n + 1 end
    end
    log("days: %s (%d story days)", cfg.on and "on" or "off", n)
    if not cfg.on then return end
    local okPacks, errPacks = pcall(readPacks, c.modDir)
    if not okPacks then log("days: the packs' stories couldn't be read (%s)", tostring(errPacks)) end
    local started = false
    WaCa.On("ScreenShown", function(screen)
        if started or not screen:GetClass():GetFName():ToString():find("^WBP_GuiHudGame") then return end
        started = true
        setUp("the session starts")
    end)
    WaCa.On("DutiesJudged", function(_, done, missed) lastJudged = { done = done, missed = missed } end)
    -- (other mods - a story mod, a test - move the story: WaCa.Emit("SetStoryDay", n); kept with the save as any day)
    WaCa.On("SetStoryDay", function(n)
        if tonumber(n) then Days.SetStory(math.floor(tonumber(n)), "asked for (SetStoryDay)") end
    end)
    -- (registered before duties / weather react to the same DayStarted - main.lua inits days first)
    WaCa.On("DayStarted", function()
        newDay()
        lastJudged = nil
        setUp("a new day")
    end)
    WaCa.On("HourChanged", function(hour)
        if DayNight.Driven() then return end             -- the clan loop plays the beats (Days.Beats)
        for phase, at in pairs(cfg.phases) do
            if hour == at then
                local steps = Days.Beats(phase)
                if #steps > 0 and Events then Events.Run(steps) end
            end
        end
    end)
    WaCa.On("GameSaved", function()
        local slot = WaCa.CurrentSlot()
        if slot and restoredFor ~= slot then
            restoredFor = slot
            local saved = WaCa.ReadIni(sidecar() or "") or {}
            local s = saved["Story"] or {}
            for _, pk in ipairs(packs) do
                local ps = saved["Pack." .. pk.mod] or {}
                pk.day, pk.seen = math.max(1, math.floor(tonumber(ps.Day or "") or 1)), {}
                for key in (ps.Seen or ""):gmatch("[^,%s]+") do pk.seen[key] = true end
            end
            if tonumber(s.Day or "") then
                story = math.floor(tonumber(s.Day))
                seen = {}
                for key in (s.Seen or ""):gmatch("[^,%s]+") do seen[key] = true end
                setUp("as saved")
            end
        end
        local path = sidecar()
        if path then
            local keys = {}
            for k in pairs(seen) do table.insert(keys, k) end
            local out = { Story = { Day = tostring(story), Seen = table.concat(keys, ","), __order = { "Day", "Seen" } },
                          __order = { "Story" } }
            for _, pk in ipairs(packs) do
                local pkeys = {}
                for k in pairs(pk.seen) do pkeys[#pkeys + 1] = k end
                out["Pack." .. pk.mod] = { Day = tostring(pk.day), Seen = table.concat(pkeys, ","), __order = { "Day", "Seen" } }
                table.insert(out.__order, "Pack." .. pk.mod)
            end
            WaCa.WriteIni(path, out, "; WaCa Clan Life - the story day this save is on (days.ini), and each pack's own")
        end
    end)
end

return Days
