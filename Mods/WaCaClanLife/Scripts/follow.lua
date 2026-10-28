-- Following (tickets.md "Following: cats moving together") - a modding tool: cats moving together.
--   Follow.Group(cats, leader, opts) -> group      the cats follow the leader (the player's cat or any cat) at staggered
--                                                   distances; while the leader sneaks (crouches) they hold back, and
--                                                   catch up when it stands again
--   Follow.Travel(cats, place, opts, onArrive) -> group   the cats walk to a place together (in a loose formation
--                                                   around it); onArrive(group) once they are all there
--   Follow.Release(group)                          the cats get their own AI back
--   Follow.Nearest(n, radius, at) -> cats          the nearest clanmates (helper)
-- cats: actors or their object paths. opts: distance (the first follower's, cm; 300), spread (each next one's extra;
-- 120), sneak = "hold" (default) | "follow", every (how many of the leader's footsteps between checks; 3).
-- How: each cat's own AI (its brain) is paused and its AIController moves it (MoveToActor / MoveToLocation - the
-- engine's pathfinding); the checks hang off FOOTSTEPS (the game's step notify for every cat, the stepping mesh handed
-- over - VM 2026-10-28), so nothing runs while nobody moves; sneaking is the game's own crouch event
-- (ASwtAdventureCharacter:OnExplorationCrouch, its bValue handed over). WaCa events: FollowArrived(group).
local Follow = {}

local WaCa, log
local groups = {}            -- id -> { id, cats = { path }, leader = path, place, opts, held, arrived = {}, onArrive }
local nextId = 0
local STEP = "/Game/Gameplay/Blueprints/BP_AnimStepNotify.BP_AnimStepNotify_C"

local function pathOf(o) return (o:GetFullName():gsub("^%S+ ", "")) end
local function actor(p)
    if type(p) ~= "string" then return p end
    local a = StaticFindObject(p)
    return a and a:IsValid() and a or nil
end

local function ai(cat)
    local c
    pcall(function() c = cat.Controller end)
    return c and c:IsValid() and c or nil
end

local function dist(a, b)
    local p, q = a:K2_GetActorLocation(), b.X and b or b:K2_GetActorLocation()
    return math.sqrt((p.X - q.X) ^ 2 + (p.Y - q.Y) ^ 2)
end

-- the i-th spot of a loose formation around a place (rings of 6)
local function slot(place, i, spread)
    if i == 1 then return place end
    local ring = math.floor((i - 2) / 6) + 1
    local a = ((i - 2) % 6) / 6 * 2 * math.pi + ring * 0.5
    local r = ring * spread * 2
    return { X = place.X + math.cos(a) * r, Y = place.Y + math.sin(a) * r, Z = place.Z }
end

local function take(cat)
    local c = ai(cat)
    if c then pcall(function() c.BrainComponent:StopLogic("WaCa: following") end) end
    return c
end

-- one look at a group: who is too far behind (follow) or not there yet (travel)
local function check(g)
    local leader = g.leader and actor(g.leader)
    for i, p in ipairs(g.cats) do
        local cat = actor(p)
        local c = cat and ai(cat)
        if c then
            pcall(function()
                if g.place then
                    local spot = slot(g.place, i, g.opts.spread)
                    if not g.arrived[i] and dist(cat, spot) <= g.opts.distance then g.arrived[i] = true
                    elseif not g.arrived[i] then c:MoveToLocation(spot, g.opts.distance / 2, true, true, false, true, nil, true) end
                elseif leader and not g.held then
                    local want = g.opts.distance + (i - 1) * g.opts.spread
                    if dist(cat, leader) > want + g.opts.spread then c:MoveToActor(leader, want, true, true, false, nil, true) end
                end
            end)
        end
    end
    if g.place and not g.done then
        local all = true
        for i = 1, #g.cats do if not g.arrived[i] and actor(g.cats[i]) then all = false end end
        if all then
            g.done = true
            log("follow: group %d arrived (%d cats)", g.id, #g.cats)
            WaCa.Emit("FollowArrived", g.id)
            if g.onArrive then pcall(g.onArrive, g) end
        end
    end
end

local function newGroup(cats, opts)
    nextId = nextId + 1
    local g = { id = nextId, cats = {}, arrived = {}, steps = 0,
                opts = { distance = (opts and opts.distance) or 300, spread = (opts and opts.spread) or 120,
                         sneak = (opts and opts.sneak) or "hold", every = (opts and opts.every) or 3 } }
    for _, c in ipairs(cats or {}) do
        local a = actor(c)
        if a then
            take(a)
            table.insert(g.cats, pathOf(a))
        end
    end
    groups[g.id] = g
    return g
end

function Follow.Group(cats, leader, opts)
    local g = newGroup(cats, opts)
    local l = actor(leader)
    g.leader = l and pathOf(l)
    log("follow: group %d - %d cats follow %s", g.id, #g.cats, l and l:GetFName():ToString() or "?")
    check(g)
    return g
end

function Follow.Travel(cats, place, opts, onArrive)
    local g = newGroup(cats, opts)
    g.place, g.onArrive = place, onArrive
    log("follow: group %d - %d cats travel to %.0f %.0f", g.id, #g.cats, place.X, place.Y)
    check(g)
    return g
end

function Follow.Release(g)
    if not g or not groups[g.id] then return end
    groups[g.id] = nil
    for _, p in ipairs(g.cats) do
        local c = actor(p) and ai(actor(p))
        if c then pcall(function() c:StopMovement() c.BrainComponent:RestartLogic() end) end
    end
    log("follow: group %d released", g.id)
end

function Follow.Nearest(n, radius, at)
    local out = {}
    local p = at
    if not p then
        for _, c in ipairs(FindAllOf("SwtPlayerController") or {}) do
            if c:IsValid() and c.Player and c.Pawn then p = c.Pawn:K2_GetActorLocation() end
        end
    end
    if not p or n <= 0 then return out end
    local near = {}
    for _, c in ipairs(FindAllOf("BP_Exploration_Character_Base_C") or {}) do
        pcall(function()
            if c:IsValid() and c.CharacterType == 1 and not c.bHidden and ai(c) then
                local d = dist(c, p)
                if d < (radius or 3000) and d > 1 then table.insert(near, { c, d }) end
            end
        end)
    end
    table.sort(near, function(a, b) return a[2] < b[2] end)
    for i = 1, math.min(n, #near) do table.insert(out, near[i][1]) end
    return out
end

function Follow.Init(c)
    WaCa, log = c.WaCa, c.log
    -- footsteps: a leader's (following) or a traveller's (arriving) - every Every-th step a look at that group
    WaCa.Watch("Received_Notify", STEP, "CatStep", "pre", "MeshComp")
    WaCa.On("CatStep", function(_, mesh)
        if not next(groups) or not mesh then return end
        local ok, owner = pcall(function() return pathOf(mesh:GetOwner()) end)
        if not ok then return end
        -- (a snapshot: an arrival can start the next leg - a new group - inside check)
        local list = {}
        for _, g in pairs(groups) do table.insert(list, g) end
        for _, g in ipairs(list) do
            local mine = groups[g.id] and g.leader == owner
            if not mine and groups[g.id] and g.place then
                for _, p in ipairs(g.cats) do if p == owner then mine = true break end end
            end
            if mine then
                g.steps = g.steps + 1
                if g.steps % g.opts.every == 0 then check(g) end
            end
        end
    end)
    -- the leader sneaks: hold back (its own crouch event, bValue handed over as "true" / "false")
    WaCa.Watch("OnExplorationCrouch", "/Script/SwtAdventure.SwtAdventureCharacter", "WaCaFollowCrouch", "post", "bValue")
    WaCa.On("WaCaFollowCrouch", function(who, value)
        local ok, path = pcall(pathOf, who)
        if not ok then return end
        for _, g in pairs(groups) do
            if g.leader == path and g.opts.sneak == "hold" then
                g.held = value == "true"
                log("follow: group %d %s", g.id, g.held and "holds back (the leader sneaks)" or "follows again")
                if g.held then
                    for _, p in ipairs(g.cats) do
                        local c = actor(p) and ai(actor(p))
                        if c then pcall(function() c:StopMovement() end) end
                    end
                else
                    check(g)
                end
            end
        end
    end)
end

return Follow
