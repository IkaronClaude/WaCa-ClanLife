-- Clanmates comment on a hunt (operator 2026-10-30, future work: "your party mates should be able to say a line of
-- dialogue after you land or miss a hunt"). config/lines.ini [Hunt] (a story pack's content\lines.ini adds lines):
-- after a catch or a missed pounce (WaCa Hunting's HuntCaught / HuntMissed) one of your party mates - the PARTY page's
-- cats walking with you (WaCa walkers), the game's own Party array, a patrol's companions - within Radius says one of the
-- Caught / Missed lines, by Chance %; with nobody in your party the nearest clanmate does (Who = Party: party mates
-- only). {PLAYER} = your cat's name, {PREY} = the prey kind
-- (mouse, rabbit ...). The line shows as WaCa Cutscenes' subtitle (its ShowLine event); without WaCa Cutscenes it is
-- only logged.
local HuntLines = {}
local WaCa, log
local cfg = { on = true, radius = 1500, chance = 100, partyOnly = false, caught = {}, missed = {} }
local function pc()
    for _, c in ipairs(FindAllOf("SwtPlayerController") or {}) do
        if c:IsValid() and c.Player then return c end
    end
end

local PREY = { Mice = "mouse", Squirrel = "squirrel", Rabbit = "rabbit", Bird = "bird", Rat = "rat", Fish = "fish" }

local function kindName(value)
    local name
    pcall(function()
        StaticFindObject("/Script/SwtQuest.ESwtQuestCharacterType"):ForEachName(function(n, v)
            if v == tonumber(value) then name = n:ToString():gsub("^.*::", ""):gsub("^Weak", "") end
        end)
    end)
    return PREY[name or ""] or (name and name:lower()) or "prey"
end

-- the party: the game's own (the pawn's Party array) and the cats following your cat - object path -> true
local function partyPaths()
    local set, n = {}, 0
    local pawn = pc() and pc().Pawn
    if not pawn then return set, 0 end
    pcall(function()
        pawn.Party:ForEach(function(_, e)
            local a = e:get()
            if a and a:IsValid() then set[(a:GetFullName():gsub("^%S+ ", ""))] = true n = n + 1 end
        end)
    end)
    pcall(function()
        for _, a in ipairs(require("walkers").Party()) do
            local path = (a:GetFullName():gsub("^%S+ ", ""))
            if not set[path] then set[path] = true n = n + 1 end
        end
    end)
    pcall(function()
        for _, a in ipairs(require("follow").Followers(pawn)) do
            local path = (a:GetFullName():gsub("^%S+ ", ""))
            if not set[path] then set[path] = true n = n + 1 end
        end
    end)
    return set, n
end

local function speaker()
    local mine = WaCa.PlayerClan and WaCa.PlayerClan() or nil
    local party, n = partyPaths()
    local nearest
    for _, c in ipairs(WaCa.Cats and WaCa.Cats() or {}) do
        if c.dist <= cfg.radius and (not mine or not c.clan or c.clan == mine) then
            if party[(c.actor:GetFullName():gsub("^%S+ ", ""))] then return c, "party" end
            nearest = nearest or c
        end
    end
    if cfg.partyOnly or n > 0 then return nil end      -- (a party is out: only its cats speak)
    return nearest, "nearest"
end

local function comment(list, kind)
    if #list == 0 or math.random(100) > cfg.chance then return end
    local who, why = speaker()
    if not who then
        log("hunt lines: nobody to comment (%s)", cfg.partyOnly and "no party mate within Radius" or "no clanmate within Radius")
        return
    end
    local line = list[math.random(#list)]
    local name = WaCa.PlayerName and WaCa.PlayerName() or "you"
    line = line:gsub("{PLAYER}", name):gsub("{PREY}", kindName(kind))
    log("hunt lines: %s (%s): %s", who.name, why, line)
    WaCa.SayOrShow(who.name, line)
end

function HuntLines.Init(c)
    WaCa, log = c.WaCa, c.log
    local ini = WaCa.ReadContent(c.modDir .. "/config/lines.ini", "lines") or {}
    local h = ini["Hunt"] or {}
    cfg.on = (h.On or "1") ~= "0"
    cfg.radius = tonumber(h.Radius or "") or cfg.radius
    cfg.chance = tonumber(h.Chance or "") or cfg.chance
    cfg.partyOnly = (h.Who or ""):lower() == "party"
    for _, k in ipairs(h.__order or {}) do
        if k:match("^Caught%d*$") then cfg.caught[#cfg.caught + 1] = h[k] end
        if k:match("^Missed%d*$") then cfg.missed[#cfg.missed + 1] = h[k] end
    end
    log("hunt lines: %s (%d for a catch, %d for a miss; %s)", cfg.on and "on" or "off", #cfg.caught, #cfg.missed,
        cfg.partyOnly and "party mates only" or "party mates, else the nearest clanmate")
    if not cfg.on then return end
    WaCa.On("HuntCaught", function(_, _, _, kind) pcall(comment, cfg.caught, kind) end)
    WaCa.On("HuntMissed", function(_, _, _, kind) pcall(comment, cfg.missed, kind) end)
end

return HuntLines
