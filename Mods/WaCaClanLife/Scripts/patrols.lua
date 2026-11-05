-- The clan's own patrols (operator 2026-10-28: "when the deputy assigns patrols I'd like to see them head out
-- together ... to feel more like stuff is really happening"): when a third of the clan loop begins (ClanThird), the
-- deputy sends out a patrol by chance - Size cats from the camp walk out together (follow.lua: a group travels) to
-- Points border points out in the territory, one after another, then back to camp, where they get their own AI back.
-- While a patrol is out, the roles in Roles speak their Case = Patrol lines (lines.ini [Dialogue.*]; Leader = the
-- role leading it) - meet them out there and they talk about the patrol. config/patrols.ini.
-- WaCa events: PatrolOut(id, cats), PatrolBack(id). Lua: Patrols.Send(cats, points, onBack) for a mod's own patrol.
local Patrols = {}

local WaCa, log, Duties, Follow, Lines
local cfg = { on = false, chance = 50, size = 3, points = 2, gather = 25000, roles = {}, leaderRole = nil, thirds = { Morning = true, Evening = true } }
local out = {}            -- id -> { group, points, i, onBack }

local function caseOn(on)
    if not Lines then return end
    for _, role in ipairs(cfg.roles) do
        if on then Lines.SetCase(role, "Patrol", cfg.leaderRole) else Lines.ClearCase(role) end
    end
end

-- a patrol walks its points one after another, then home; each leg a group travel (Follow.Travel)
function Patrols.Send(cats, points, onBack)
    if #cats == 0 or #points == 0 then return nil end
    local camp = Duties.Camp()
    local p = { points = points, i = 0, cats = cats, onBack = onBack }
    local function leg()
        if p.group then Follow.Release(p.group) end
        p.i = p.i + 1
        local target = p.points[p.i]
        if not target then
            -- home: back to the camp's middle, then their own AI
            if not p.home and camp and camp.middle then
                p.home = true
                p.group = Follow.Travel(p.cats, camp.middle, { distance = 500, spread = 200 }, function()
                    Follow.Release(p.group)
                    out[p.id] = nil
                    if not next(out) then caseOn(false) end
                    log("patrols: patrol %d is back", p.id)
                    WaCa.Emit("PatrolBack", p.id)
                    if p.onBack then pcall(p.onBack, p) end
                end)
                p.id = p.id or p.group.id
            end
            return
        end
        p.group = Follow.Travel(p.cats, target, { distance = 600, spread = 200 }, leg)
        p.id = p.id or p.group.id
    end
    leg()
    out[p.id] = p
    caseOn(true)
    log("patrols: patrol %d - %d cats head out - %d stop(s) on the way", p.id, #cats, #points)
    WaCa.Emit("PatrolOut", p.id, cats)
    return p
end

function Patrols.Out() return out end

-- A PATROL TO THESE POINTS, by whatever cats can go (the clan's own and a story's - Patrol: steps share it; library
-- exercise 2026-11-05): the camp's warriors on foot (walkers.lua). Returns who went, or nil (no camp cat free).
function Patrols.Dispatch(n, points, why, onBack)
    if #(points or {}) == 0 then return nil end
    -- (PatrolOut / PatrolBack once, whichever way it goes: Send emits its own; the walkers' way here)
    local id
    local function back()
        WaCa.Emit("PatrolBack", id)
        if onBack then pcall(onBack) end
    end
    local okW, wid, names = pcall(function() return require("walkers").Patrol(n, points, why, back, { warriors = true }) end)
    id = okW and wid or nil
    if id then
        WaCa.Emit("PatrolOut", id)
        return table.concat(names or {}, ", ")
    end
    -- (NO FIELD-CAT FALLBACK: the nearest field cats through follow.lua were sent here - their AI moves fail on this map
    -- (VM 2026-10-30, again 2026-11-05: Briar and Blaze 'set off' and stood 14 min), so a patrol was claimed and nobody
    -- walked. No camp cat free = no patrol, said so. tickets.md P2: field cats on the walkers' mover. Patrols.Send stays
    -- for a mod that has cats of its own.)
    return nil
end

function Patrols.Init(c)
    WaCa, log, Duties, Follow, Lines = c.WaCa, c.log, c.Duties, c.Follow, c.Lines
    local ini = WaCa.ReadContent(c.modDir .. "/config/patrols.ini", "patrols") or {}
    local p = ini["Patrols"] or {}
    cfg.on = c.part("Patrols", p.On)
    cfg.chance = tonumber(p.Chance or "") or cfg.chance
    cfg.size = math.max(1, math.floor(tonumber(p.Size or "") or cfg.size))
    cfg.points = math.max(1, math.floor(tonumber(p.Points or "") or cfg.points))
    cfg.gather = tonumber(p.GatherRadius or "") or cfg.gather
    cfg.leaderRole = (p.LeaderRole or "") ~= "" and p.LeaderRole or nil
    for role in (p.Roles or ""):gmatch("[^,%s]+") do table.insert(cfg.roles, role) end
    if (p.Thirds or "") ~= "" then
        cfg.thirds = {}
        for t in p.Thirds:gmatch("[^,%s]+") do cfg.thirds[t] = true end
    end
    log("patrols: %s (%d%% a third, %d cats, %d points)", cfg.on and "on" or "off", cfg.chance, cfg.size, cfg.points)
    if not cfg.on then return end
    WaCa.On("ClanThird", function(_, third)
        if not cfg.thirds[third] or next(out) then return end
        -- (the story's lever on the chance: ClanPatrol = 1 - a patrol leaves this third, -1 - none; operator
        -- 2026-10-29 "we need a control lever / override")
        local lever = 0
        pcall(function() lever = tonumber(require("events").Var("ClanPatrol")) or 0 end)
        if lever <= -1 then log("patrols: none this %s - ClanPatrol = %s", third:lower(), tostring(lever)) return end
        if lever < 1 and math.random() * 100 >= cfg.chance then return end
        if lever >= 1 then log("patrols: one leaves this %s - ClanPatrol = %s", third:lower(), tostring(lever)) end
        local camp = Duties.Camp()
        if not (camp and camp.middle) then
            log("patrols: no camp known yet - no patrol this %s", third:lower())
            return
        end
        -- (the camp's own cats are story cats the game doesn't walk; the clanmates that walk are out in the territory -
        -- VM: none within 60 m of the camp. The nearest within GatherRadius meet in camp first, then head out together.)
        -- (on foot with the walkers' mover - the camp's own cats, from camp; the AI walks of the field cats below fail
        -- on this map: VM 2026-10-30. Meeting the patrol out there stops it: walkers.lua)
        local points = Duties.BorderPoints(cfg.points, camp.middle)
        caseOn(true)
        local ok, who = pcall(Patrols.Dispatch, cfg.size, points, "the clan's " .. third:lower(), function()
            caseOn(false)
        end)
        if not (ok and who) then
            caseOn(false)
            log("patrols: no patrol this %s (%s%d border points)", third:lower(), ok and "" or (tostring(who) .. "; "), #points)
        end
    end)
end

return Patrols
