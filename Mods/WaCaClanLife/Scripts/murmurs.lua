-- MURMURINGS (tickets.md "Murmurings: what the clan thinks, every day", operator 2026-10-28): the camp's cats say how
-- they feel - about you, the leader, the clan's hunger, the season, a Gathering - and it changes from day to day with
-- the clan's state. Walk past a camp cat and, now and then (Chance %), it murmurs a line (a subtitle - WaCa Cutscenes'
-- ShowLine): once per cat per day, from every config/lines.ini [Murmur.<Name>] section whose Require holds (the story
-- conditions: Standing >= 2, Pile < 30, Season = Leaf-bare, LeaderFavour <= -3 ...) and whose Who fits the cat (a story
-- role's ending: Elder, Warrior, Apprentice ... - All by default), picked by the daily grab bag (lines.lua: no line
-- again until all have come). {PLAYER}, {LEADER}, {DEPUTY}, {NAME} (the cat itself) are filled in. A story pack adds
-- its own [Murmur.*] in content\lines.ini. Checked on your cat's footsteps (every 3rd) - nothing runs while it stands.
-- lines.ini [Murmurs] On / Radius (cm) / Chance (%).
local Murmurs = {}

local WaCa, log, Events, Lines
local cfg = { on = true, radius = 450, chance = 35, entries = {} }
local said = {}                  -- cat name -> the day it was last asked (murmured or not)
local steps = 0

local function pawn()
    for _, c in ipairs(FindAllOf("SwtPlayerController") or {}) do
        if c:IsValid() and c.Player and c.Pawn and c.Pawn:IsValid() then return c.Pawn end
    end
end

-- the names the lines can use: your cat, your clan's leader and deputy (by their job), the cat itself
local function names(cat, cats)
    local n = { PLAYER = WaCa.PlayerName and WaCa.PlayerName() or "you", NAME = cat.name }
    for _, c in ipairs(cats) do
        if c.clan == cat.clan then
            if c.giver == "Leader" and not n.LEADER then n.LEADER = c.name end
            if c.giver == "Deputy" and not n.DEPUTY then n.DEPUTY = c.name end
        end
    end
    -- (the clan's own parts as Clan Life knows them - the game's giver role misses some leaders: Lionstar murmured
    -- about as "our leader", VM 2026-11-01)
    for _, part in ipairs({ "Leader", "Deputy" }) do
        local key = part:upper()
        if not n[key] then
            pcall(function()
                local a = Events.Who(part)
                local name = a and a:IsValid() and WaCa.CatName(a)
                if name and name ~= "" then n[key] = name end
            end)
        end
    end
    n.LEADER, n.DEPUTY = n.LEADER or "our leader", n.DEPUTY or "the deputy"
    return n
end

-- who may say a set: All, a part of a story role's name (Elder, Warrior ...), E:<story role>, a cat's name, or a pack's
-- own role S:<role> - the cat its [Cast] gives it (library exercise 2026-11-02: a pack's herbalist couldn't murmur)
local function whoFits(who, cat)
    if who == "All" then return true end
    local spec = who
    if who:match("^S:") then
        local c = Events.CastSpecs and Events.CastSpecs() or {}
        spec = type(c[who]) == "string" and c[who] or ""
    end
    local role = spec:match("^E:(.+)$")
    if role then return (cat.story or "") == role end
    if spec ~= "" and spec == cat.name then return true end
    return not who:match("^S:") and (cat.story or ""):find(who .. "$") ~= nil
end

local function check()
    local me = pawn()
    if not me or (WaCa.InMenu and WaCa.InMenu()) then return end
    local cats = WaCa.Cats and WaCa.Cats() or {}
    local mine = WaCa.PlayerClan and WaCa.PlayerClan() or nil
    local day = Events.Var("Day")
    -- (the nearest cat in reach not asked today - a party mate walking beside you would always be the nearest)
    local cat
    for _, c in ipairs(cats) do
        if c.dist > cfg.radius then break end
        if (not mine or not c.clan or c.clan == mine) and said[c.name] ~= day then cat = c break end
    end
    if not cat then return end
    said[cat.name] = day
    if math.random(100) > cfg.chance then return end
    local lines, from = {}, {}
    for _, e in ipairs(cfg.entries) do
        if whoFits(e.who, cat) and Events.Check(e.require) then
            for _, l in ipairs(e.lines) do lines[#lines + 1] = l end
            from[#from + 1] = e.name
        end
    end
    local n = names(cat, cats)
    local function fill(l)
        l = l:gsub("{(%u+)}", function(k) return n[k] or ("{" .. k .. "}") end)
        return Events.Fill and Events.Fill(l) or l           -- ({S:storyteller}, {Leader}, a name: the cat's name)
    end
    -- (no cat talks about itself as someone else - operator 2026-11-04: "Hollystar: Hollystar has been up since dawn
    -- again", the leader given the line about {LEADER}; {NAME} - its own name - is meant)
    local own = {}
    for _, l in ipairs(lines) do
        if not fill((l:gsub("{NAME}", ""))):find(cat.name, 1, true) then own[#own + 1] = l end
    end
    lines = own
    if #lines == 0 then return end
    local line = Lines.Pick("Murmur." .. cat.name, lines, day)
    if not line then return end
    line = fill(line)
    line = line:gsub("^%l", string.upper)                  -- ("our leader ..." opening a line)
    log("murmurs: %s (%s): %s", cat.name, table.concat(from, ", "), line)
    WaCa.Emit("ShowLine", cat.name .. ": " .. line)
end

function Murmurs.Init(c)
    WaCa, log = c.WaCa, c.log
    Events, Lines = require("events"), require("lines")
    local ini = WaCa.ReadContent(c.modDir .. "/config/lines.ini", "lines") or {}
    local m = ini["Murmurs"] or {}
    cfg.on = (m.On or "1") ~= "0"
    cfg.radius = tonumber(m.Radius or "") or cfg.radius
    cfg.chance = tonumber(m.Chance or "") or cfg.chance
    local names = {}
    for section in pairs(ini) do
        if type(section) == "string" and section:match("^Murmur%.") then names[#names + 1] = section end
    end
    table.sort(names)
    for _, section in ipairs(names) do
        local sec = ini[section]
        local e = { name = section:gsub("^Murmur%.", ""), require = sec.Require or "", who = (sec.Who or "") ~= "" and sec.Who or "All",
                    lines = {} }
        for _, k in ipairs(sec.__order or {}) do
            if k:match("^Line%d*$") and sec[k] ~= "" then e.lines[#e.lines + 1] = sec[k] end
        end
        if #e.lines > 0 then cfg.entries[#cfg.entries + 1] = e end
    end
    log("murmurs: %s (%d sets of lines)", cfg.on and "on" or "off", #cfg.entries)
    if not cfg.on or #cfg.entries == 0 then return end
    WaCa.On("CatStep", function(_, mesh)
        local me = pawn()
        if not (me and mesh) then return end
        local ok, mineStep = pcall(function() return (WaCa.Live(mesh:GetOwner()) or error("no owner")):GetAddress() == me:GetAddress() end)
        if not (ok and mineStep) then return end
        steps = steps + 1
        if steps % 3 ~= 0 then return end
        local ok2, err = pcall(check)
        if not ok2 then log("murmurs: %s", tostring(err)) end
    end)
end

return Murmurs
