-- Clan cats say more than one thing (tickets.md 11). The game's chatter is its "filler" monologue: one line per cat
-- role, story chapter and tone (QST_Story.Monologue.Filler.<Role>.<Chapter>.<n>.Context.<n>.<Tone> - 755 groups,
-- each exactly ONE line - so every cat repeats itself). config/lines.ini adds pools of lines per role (or All) and
-- time of day; every in-game hour each filler line is, by chance (Share), one of its pool's lines for the hour, or
-- the game's own again. The text itself is swapped in the game's string table (WaCa.SetText) - the game picks the
-- key as always, so story lines keep their place and the change is just more to say. Needs the day / night cycle
-- for the time of day (without it: Day lines, rolled once per world).
-- DIALOGUE BY DAYS (the story's - operator 2026-10-28): [Dialogue.<Name>] Who = <filler role> (RiverClanQueen ...),
-- Days = 1-6 (story days; "3", "7-"), Require = <story conditions>, Case = Talk (default) | Patrol (while that cat is on a
-- patrol; Leader = <role> for one led by that role), Line1 ... LineN - that role says ONE of them all day, picked by a
-- GRAB BAG: no line again until all have come, and the last two of a bag wait out the next refill (A B C D -> C, B, D,
-- A, then a new bag without D / A first). The pick is kept with the save. A story entry beats the random pools.
-- Lua: Lines.Pick(name, lines, day) - the same daily grab bag for any mod; Lines.SetCase(role, case, leader) /
-- Lines.ClearCase(role) - e.g. duties.lua's patrols.
local Lines = {}

local WaCa, log, DayNight, Days, Events
local cfg = { on = false, share = 0.5, pools = {}, dialogue = {} }   -- pools[role][period] = { lines }
local bags = {}                                       -- name -> { bag = { i }, recent = { i }, n, day, pick }
local cases = {}                                      -- role -> { case, leader } (a cat on patrol ...)
local fixed = {}                                      -- role -> true: a story line today (the pools leave it alone)
local filler                                          -- { key, role } for every filler key
local original = {}                                   -- key -> the game's own text

local PERIODS = { { "Night", 0 }, { "Morning", 5 }, { "Day", 11 }, { "Evening", 17 }, { "Night", 21 } }
local function period(hour)
    local name = "Night"
    for _, p in ipairs(PERIODS) do if hour >= p[2] then name = p[1] end end
    return name
end

local function fillerKeys()
    if filler then return filler end
    filler = {}
    local ok, keys = pcall(function()
        return StaticFindObject("/Script/Engine.Default__KismetStringTableLibrary"):GetKeysFromStringTable(FName("SwtStrings"))
    end)
    if not ok or not keys then return filler end
    for i = 1, #keys do
        local k = keys[i]
        local key = type(k) == "string" and k or (k.ToString and k:ToString()) or (k.get and k:get():ToString()) or tostring(k)
        local role = key:match("^QST_Story%.Monologue%.Filler%.([^.]+)%.")
        if role then table.insert(filler, { key = key, role = role }) end
    end
    return filler
end

local today, inDays

-- this hour's lines for a role: its own pools + All's - the ones for today (Days / Require) - for the period, plus
-- their "Any" lines
local function poolFor(role, p)
    local out = {}
    local day = today()
    for _, who in ipairs({ role, "All" }) do
        for _, pool in ipairs(cfg.pools[who] or {}) do
            if inDays(pool.days, day) and (not Events or Events.Check(pool.require)) then
                for _, l in ipairs(pool.lines[p] or {}) do table.insert(out, l) end
                for _, l in ipairs(pool.lines.Any or {}) do table.insert(out, l) end
            end
        end
    end
    return out
end

-- the daily grab bag: today's line of a pool (the same all day); a new day draws from the bag; a used-up bag is
-- refilled with every line, the last two picks only after the others
function Lines.Pick(name, lines, day)
    local n = #lines
    if n == 0 then return nil end
    local b = bags[name]
    if not b or b.n ~= n then
        b = { bag = {}, recent = {}, n = n }
        bags[name] = b
    end
    if b.day == day and b.pick and b.pick <= n then return lines[b.pick], b.pick end
    if #b.bag == 0 then for i = 1, n do b.bag[i] = i end end
    local hold = math.min(2, n - 1)
    local options = {}
    for _, i in ipairs(b.bag) do
        local recent = false
        for k = math.max(1, #b.recent - hold + 1), #b.recent do if b.recent[k] == i then recent = true end end
        if not recent then table.insert(options, i) end
    end
    if #options == 0 then options = b.bag end
    local pick = options[math.random(#options)]
    for k, i in ipairs(b.bag) do if i == pick then table.remove(b.bag, k) break end end
    table.insert(b.recent, pick)
    while #b.recent > 2 do table.remove(b.recent, 1) end
    b.day, b.pick = day, pick
    return lines[pick], pick
end

-- the day the dialogue follows: the story day (days.lua), else the day count
today = function()
    local d = Days and Days.Story and Days.Get and Days.Get("Like") ~= nil and Days.Story()
    return d or (Days and Days.Story and Days.Story()) or (DayNight and DayNight.Day()) or 1
end

-- "1-6", "3", "7-", "" -> does day d fall in it
inDays = function(spec, d)
    spec = tostring(spec or "")
    if spec == "" then return true end
    local a, b = spec:match("^%s*(%d*)%s*%-%s*(%d*)%s*$")
    if a then return (a == "" or d >= tonumber(a)) and (b == "" or d <= tonumber(b)) end
    return tonumber(spec) == d
end

-- a role's story line for today (its case first: on a patrol ...), or nil
local function storyLine(role, day)
    local c = cases[role]
    for _, e in ipairs(cfg.dialogue) do
        if e.who == role and inDays(e.days, day) and (not Events or Events.Check(e.require))
            and e.case == (c and c.case or "Talk") and (not e.leader or (c and c.leader == e.leader)) then
            return Lines.Pick(e.name, e.lines, day)
        end
    end
    return nil
end

-- the story's dialogue for today: every role with a matching entry says its pick (all its filler keys)
local function story()
    fixed = {}
    if #cfg.dialogue == 0 then return end
    local day = today()
    local n = 0
    for _, f in ipairs(fillerKeys()) do
        local line = storyLine(f.role, day)
        if line then
            original[f.key] = original[f.key] or WaCa.GetText(f.key)
            WaCa.SetText(f.key, line)
            if not fixed[f.role] then n = n + 1 end
            fixed[f.role] = true
        end
    end
    if n > 0 then log("lines: day %d - %d roles have their story line for today", day, n) end
end

function Lines.SetCase(role, case, leader)
    cases[role] = { case = case, leader = leader }
    story()
end
function Lines.ClearCase(role)
    cases[role] = nil
    story()
end

local function roll(hour)
    local p = period(hour or 12)
    local swapped = 0
    for _, f in ipairs(fillerKeys()) do
        local pool = (not fixed[f.role]) and poolFor(f.role, p) or {}
        if #pool > 0 then
            original[f.key] = original[f.key] or WaCa.GetText(f.key)
            local text = (math.random() < cfg.share) and pool[math.random(#pool)] or original[f.key]
            if WaCa.SetText(f.key, text) and text ~= original[f.key] then swapped = swapped + 1 end
        elseif original[f.key] and not fixed[f.role] then
            WaCa.SetText(f.key, original[f.key])          -- no pool for today any more: the game's own line again
        end
    end
    log("lines: %s - %d clan cat lines changed for now", p, swapped)
end

function Lines.Init(c)
    WaCa, log, DayNight, Days, Events = c.WaCa, c.log, c.DayNight, c.Days, c.Events
    local ini = WaCa.ReadContent(c.modDir .. "/config/lines.ini", "lines") or {}
    local l = ini["Lines"] or {}
    cfg.on = (l.On or "0") == "1"
    cfg.share = math.max(0, math.min(1, tonumber(l.Share or "") or cfg.share))
    local n = 0
    local names = {}
    for section in pairs(ini) do if section ~= "__order" then table.insert(names, section) end end
    table.sort(names)
    for _, section in ipairs(names) do
        local sec = ini[section]
        local name = section:match("^Dialogue%.(.+)$")
        if name and (sec.Who or "") ~= "" and sec.Off ~= "1" then
            local lines = {}
            for i = 1, 99 do if (sec["Line" .. i] or "") ~= "" then table.insert(lines, sec["Line" .. i]) end end
            if #lines > 0 then
                table.insert(cfg.dialogue, { name = name, who = sec.Who, days = sec.Days, require = sec.Require,
                    case = (sec.Case or "") ~= "" and sec.Case or "Talk",
                    leader = (sec.Leader or "") ~= "" and sec.Leader or nil, lines = lines })
            end
        end
    end
    for _, section in ipairs(names) do
        local sec = ini[section]
        -- [Lines.<Role>] or [Lines.<Role>.<Tag>] (several pools per role - for given days: Days / Require)
        local role = section:match("^Lines%.([^.]+)")
        if role and sec.Off ~= "1" then
            local pool = { days = sec.Days, require = sec.Require, lines = {} }
            for _, key in ipairs(sec.__order or {}) do
                local p = key:match("^(%a+)%d*$")          -- Morning1, Morning2, Night, Any3 ...
                if p and p ~= "Days" and p ~= "Require" and p ~= "Off" and sec[key] ~= "" then
                    pool.lines[p] = pool.lines[p] or {}
                    table.insert(pool.lines[p], sec[key])
                    n = n + 1
                end
            end
            cfg.pools[role] = cfg.pools[role] or {}
            table.insert(cfg.pools[role], pool)
        end
    end
    log("lines: %s (%d extra lines, %d story dialogues)", cfg.on and "on" or "off", n, #cfg.dialogue)
    if not cfg.on or (n == 0 and #cfg.dialogue == 0) then return end
    WaCa.On("HourChanged", function(hour) roll(hour) end)
    WaCa.On("DayStarted", function() story() roll(DayNight.Hour()) end)
    local rolled = false
    WaCa.On("ScreenShown", function(screen)
        if rolled or not screen:GetClass():GetFName():ToString():find("^WBP_GuiHudGame") then return end
        rolled = true
        story()
        roll(DayNight.Hour())
    end)
    -- the grab bags live with the save (written when the game saves)
    local bagsFor
    WaCa.On("GameSaved", function()
        local slot = WaCa.CurrentSlot()
        local path = WaCa.SlotFile("WaCaLines")
        if slot and bagsFor ~= slot then
            bagsFor = slot
            bags = {}
            for name, v in pairs((WaCa.ReadIni(path or "") or {})["Bags"] or {}) do
                if name ~= "__order" then
                    local b = { bag = {}, recent = {} }
                    b.n = tonumber(v:match("n:(%d+)"))
                    b.day, b.pick = tonumber(v:match("day:(%d+)")), tonumber(v:match("pick:(%d+)"))
                    for i in (v:match("bag:([%d,]*)") or ""):gmatch("%d+") do table.insert(b.bag, tonumber(i)) end
                    for i in (v:match("recent:([%d,]*)") or ""):gmatch("%d+") do table.insert(b.recent, tonumber(i)) end
                    bags[name] = b
                end
            end
            story()
        end
        if path then
            local d = { __order = {} }
            for name, b in pairs(bags) do
                d[name] = string.format("n:%d bag:%s recent:%s day:%d pick:%d", b.n or 0, table.concat(b.bag, ","),
                    table.concat(b.recent, ","), b.day or 0, b.pick or 0)
                table.insert(d.__order, name)
            end
            WaCa.WriteIni(path, { Bags = d, __order = { "Bags" } }, "; WaCa Clan Life - the daily line picks (lines.ini)")
        end
    end)
end

return Lines
