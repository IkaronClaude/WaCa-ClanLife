-- Gatherings (tickets.md, operator 2026-10-28) - the GROUNDWORK the story builds on: every Every days (the story can
-- move it: days.ini Gathering = Yes / No) the leader picks who goes; on that day the announcement comes when the
-- AnnounceThird begins, and the Gathering itself (or staying behind) at the end of the Third (the task turned in).
-- The pick: the story's (days.ini GatheringPick = Chosen / NotChosen) - else not while BanVar > 0 (a punishment:
-- "Add: GatheringBan 1" in a scene; every Gathering that passes takes one off) or below MinRank - else by chance:
-- Base % + PerStanding x your standing (duties.lua) + PerFavour x FavourVar (a story variable, e.g. LeaderFavour).
-- Every step is a scene (events.lua steps) in gatherings.ini: [Announce], [Chosen] / [NotChosen] (right after), [Attend]
-- / [StayBehind] (the Gathering's evening). The outcome is a story variable (Gathering.Chosen = 1 / 0, Gathering.Count)
-- for the story's own beats and conditions (days.ini "Evening1 = If: Gathering.Chosen = 0" ... the rogues attack),
-- and WaCa events GatheringAnnounced(day, chosen) / GatheringHeld(day, chosen). Blocking Lua hooks inside the scenes:
-- Hook: GatheringAttend / GatheringStayBehind (by default) - a mod's own Gathering scene goes there.
local Gathering = {}

local WaCa, log, Events, Days, DayNight
local cfg = { on = false, first = 7, every = 28, third = "Evening", announce = "Morning", minRank = nil, base = 60,
              perStanding = 2, perFavour = 5, favourVar = "LeaderFavour", banVar = "GatheringBan", scenes = {} }
local today                  -- { day, chosen } of a Gathering day once announced

local function rankValue(name)
    local v
    pcall(function()
        StaticFindObject("/Script/SwtQuest.ECharacterRank"):ForEachName(function(n, val)
            if n:ToString():gsub("^.*::", "") == name then v = val end
        end)
    end)
    return v
end

-- is today a Gathering day? the story's word first, else FirstDay + every Every days
local function isGatheringDay(day)
    local story = Days and Days.Get and Days.Get("Gathering")
    if story then return story:lower() == "yes" or story == "1" end
    return day >= cfg.first and (day - cfg.first) % cfg.every == 0
end

-- the leader's pick: true (chosen) / false, and why
local function pick()
    local story = Days and Days.Get and Days.Get("GatheringPick")
    if story then return story:lower() == "chosen", "the story" end
    local ban = tonumber(Events.Var(cfg.banVar)) or 0
    if ban > 0 then return false, string.format("%s %d - not allowed this time", cfg.banVar, ban) end
    if cfg.minRank then
        local need, have = rankValue(cfg.minRank), tonumber(Events.Var("Rank")) or 0
        if need and have < need then return false, "below " .. cfg.minRank end
    end
    local chance = cfg.base + cfg.perStanding * (tonumber(Events.Var("Standing")) or 0)
        + cfg.perFavour * (tonumber(Events.Var(cfg.favourVar)) or 0)
    chance = math.max(0, math.min(100, chance))
    local roll = math.random() * 100
    return roll < chance, string.format("chance %.0f%%", chance)
end

local function third(ctx) return ctx and ctx.THIRD and (ctx.THIRD:gsub("^%l", string.upper)) end

function Gathering.Init(c)
    WaCa, log, Events, Days, DayNight = c.WaCa, c.log, c.Events, c.Days, c.DayNight
    local ini = WaCa.ReadContent(c.modDir .. "/config/gatherings.ini", "gatherings") or {}
    local g = ini["Gathering"] or {}
    cfg.on = (g.On or "0") == "1"
    cfg.first = math.floor(tonumber(g.FirstDay or "") or cfg.first)
    cfg.every = math.max(1, math.floor(tonumber(g.Every or "") or cfg.every))
    cfg.third = (g.Third or "") ~= "" and g.Third or cfg.third
    cfg.announce = (g.AnnounceThird or "") ~= "" and g.AnnounceThird or cfg.announce
    cfg.minRank = (g.MinRank or "") ~= "" and g.MinRank or nil
    cfg.base = tonumber(g.Base or "") or cfg.base
    cfg.perStanding = tonumber(g.PerStanding or "") or cfg.perStanding
    cfg.perFavour = tonumber(g.PerFavour or "") or cfg.perFavour
    cfg.favourVar = (g.FavourVar or "") ~= "" and g.FavourVar or cfg.favourVar
    cfg.banVar = (g.BanVar or "") ~= "" and g.BanVar or cfg.banVar
    for _, part in ipairs({ "Announce", "Chosen", "NotChosen", "Attend", "StayBehind" }) do
        cfg.scenes[part] = Events.Lines(ini[part], "Step")
    end
    if #cfg.scenes.Attend == 0 then cfg.scenes.Attend = { { kind = "Hook", value = "GatheringAttend" } } end
    if #cfg.scenes.StayBehind == 0 then cfg.scenes.StayBehind = { { kind = "Hook", value = "GatheringStayBehind" } } end
    log("gathering: %s (from day %d, every %d days; announced in the %s, held in the %s)", cfg.on and "on" or "off",
        cfg.first, cfg.every, cfg.announce:lower(), cfg.third:lower())
    if not cfg.on then return end
    Events.Provide("Gathering.Today", function() return today and 1 or 0 end)
    -- the announcement: when the AnnounceThird of a Gathering day begins (the clan loop's ClanThirdStart hook)
    Events.Hook("ClanThirdStart", function(ctx, continue)
        local day = ctx and ctx.DAY
        if not (day and third(ctx) == cfg.announce and isGatheringDay(day)) or (today and today.day == day) then
            return continue()
        end
        local chosen, why = pick()
        today = { day = day, chosen = chosen }
        Events.SetVar("Gathering.Chosen", chosen and 1 or 0)
        log("gathering: day %d - the leader %s your cat (%s)", day, chosen and "picks" or "doesn't pick", why)
        WaCa.Emit("GatheringAnnounced", day, chosen)
        local steps = {}
        for _, s in ipairs(cfg.scenes.Announce) do table.insert(steps, s) end
        for _, s in ipairs(chosen and cfg.scenes.Chosen or cfg.scenes.NotChosen) do table.insert(steps, s) end
        Events.Run(steps, continue, ctx)
    end)
    -- the Gathering: at the end of the Third (the clan loop's ClanThirdEnd hook) - there, or staying behind
    Events.Hook("ClanThirdEnd", function(ctx, continue)
        local day = ctx and ctx.DAY
        if not (today and today.day == day and third(ctx) == cfg.third) or today.held then return continue() end
        today.held = true
        local chosen = today.chosen
        local ban = tonumber(Events.Var(cfg.banVar)) or 0
        if ban > 0 and not chosen then Events.SetVar(cfg.banVar, ban - 1) end       -- one Gathering of the ban served
        Events.SetVar("Gathering.Count", (tonumber(Events.Var("Gathering.Count")) or 0) + (chosen and 1 or 0))
        log("gathering: day %d - %s", day, chosen and "your cat goes to the Gathering" or "your cat stays behind")
        WaCa.Emit("GatheringHeld", day, chosen)
        Events.Run(chosen and cfg.scenes.Attend or cfg.scenes.StayBehind, continue, ctx)
    end)
end

return Gathering
