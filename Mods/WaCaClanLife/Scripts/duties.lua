-- THE CLAN LOOP (tickets.md 15 + "the clan loop", operator 2026-10-28): the clan's day - the MORNING and the AFTERNOON
-- (config name Noon) are duties, the EVENING is the clan together, then the NIGHT:
--   a duty third begins (its story beats: days.ini <Third>Start) -> the DEPUTY assigns a task -> you do it, exploring
--   as long as you like (a done task never sends you home) -> you TURN IT IN at its end point ([Task.<Kind>] TurnIn: a
--   hunt at the fresh-kill pile, a patrol by reporting to the deputy, a spar is its own end) -> the clan's event of
--   that third, if any (clan meetings, ceremonies ...: clanevents.ini, the story's beats: days.ini <Third>) -> the
--   time moves on a full third -> the next assignment.
--   The evening (operator 2026-10-28: not a third task): the clan comes together in camp - eating, sharing tongues, staged
--   with the cats themselves (clanevents.ini When = Evening: Gather / Pose steps), the story's evening beats.
-- Then the night - sleep in your den's nest (the game's own sleep spot: use it) or the night watch (go to the guard
-- spot at the camp entrance: a short cutscene shows the night passing), or what the story sets (days.ini NightDuty =
-- Hunt: a night hunt).
-- The clan's day drives the clock (DayNight.Drive): the sky shows each third at its [Thirds] hour - no wall clock.
-- Tasks: Hunt (N prey - every prey caught feeds the clan's pile, hunt on as long as you like), Patrol (N border points
-- out in the territory, clanmates walk it with you), Train (a sparring fight with the clan's move teacher - the
-- game's own fight), Free (nothing - the time is yours). At the day's end the tasks done raise your standing in the
-- clan, the missed ones lower it (kept with the save). Below MaxRank only.
-- HOOK POINTS (for story / other mods - all optional):
--   configs  duties.ini [Third.<Third>] Start / Event steps, [Assign.<Task>] steps (the deputy's words), [NightWatch]
--            steps; clanevents.ini [Event.<Name>] (When / Chance / Days / Once / steps); days.ini per story day
--            <Third>Start, <Third> (beats), <Third>Duty, NightDuty. Steps = events.lua's scene steps (Card / Dialogue /
--            Fade / Bond / Emit / Hook ...).
--   blocking Lua hooks (events.lua Events.Hook(name, fn(ctx, continue))): the loop runs ClanThirdStart, ClanAssign,
--            ClanThirdEnd (after the turn-in and the third's events), ClanNight (the watch's cutscene) at those points - a mod's own cutscene / scene goes there.
--   events   WaCa.On: ClanThird(day, third), TaskAssigned(day, third, task), TaskDone(day, third, task),
--            TaskTurnedIn(day, third, task, how), ClanThirdEnded(day, third), CampEntered / CampLeft(day, third),
--            ClanNight(day, kind), DutiesJudged(day, done, missed, standing).
--   Lua      Duties.Now() -> { day, third, stage, task }, Duties.Plan(hunt, patrol, kinds), Duties.Standing().
-- config/duties.ini, config/clanevents.ini.
local Duties = {}

local WaCa, log, DayNight, Events, Days
local THIRDS = { "Morning", "Noon", "Evening" }
local KINDS = { Hunt = true, Patrol = true, Train = true, Free = true, NightWatch = true, Sleep = true, Gather = true,
                Bedding = true, Water = true }
local COUNTED = { Hunt = true, Patrol = true, Train = true, NightWatch = true }
local cfg = { on = false, repeatFactor = 0.35, repeatMemory = 2, maxRank = "Deputy", huntMin = 1, huntMax = 3, pileLow = 50, patrolPoints = 2, pilePerPrey = 4,
              companions = 2, companionRadius = 3000,
              train = true, trainMaxRank = "Apprentice", trainBond = 2,
              trainTag = "Gameplay.Combat.Generator.Fixed.TrainingGrounds",
              huntingGround = true,
              reach = 800, minDist = 3000, maxDist = 12000, standingDone = 2, standingMissed = -1, seconds = 5,
              hours = { Morning = 8, Noon = 13, Evening = 19, Night = 23 },
              weights = { Morning = { Hunt = 2, Patrol = 2, Train = 1 }, Noon = { Hunt = 1, Patrol = 1, Train = 2 },
                          Evening = { Patrol = 2, Hunt = 1, Free = 1 }, Night = { Sleep = 3, NightWatch = 1 } },
              turnIn = { Hunt = "Pile", Patrol = "Deputy", Free = "Deputy", Train = "Partner", Gather = "MedicineCat",
                         Bedding = "Deputy", Water = "Elder" },
              gatherCount = 3, gatherReach = 250, gatherMinDist = 1500, gatherMaxRank = "Apprentice", waterGreenleaf = 3,
              pileFactor = 3, campRadius = 3500, campMax = 6000, watchStanding = 1, stepEvery = 1,
              reportKey = "F", reportRadius = 500,
              thirdScenes = {}, assignScenes = {}, watchScene = {}, clanEvents = {} }
local HINT = "/Game/Gameplay/Blueprints/WorldElements/POIHintArea/BP_POI_HintArea_Quest.BP_POI_HintArea_Quest_C"
local lastPatrol, lastHunt = {}, nil   -- the last patrol's places / hunt spot (no repeat while there are others)
local plan                        -- day scripts' override: { hunt = n, patrol = n, kinds = { Morning = "Hunt", ... } }
local today                       -- { day, third = 1..3 / 4 = night, stage, task, record = { { third, kind, done } } }
local standing = 0
local restoredFor
local ready = false
local eventsDone = {}             -- clan events with Once = 1 already held in this save
local pendingBlackout             -- the night watch faded out: the morning fades back in

local function pc()
    for _, c in ipairs(FindAllOf("SwtPlayerController") or {}) do
        if c:IsValid() and c.Player then return c end
    end
end

-- (one queue for every card of the mod - events.lua: never two on screen at once)
local function card(text) Events.Card(text, cfg.seconds) end
-- a card for a key press that did nothing yet (at most one every 4 s: a held key repeats)
local lastFeedback = 0
local function feedback(text)
    if WaCa.Now() - lastFeedback < 4 then return end
    lastFeedback = WaCa.Now()
    card(text)
end

local function ranks()
    local out = {}
    pcall(function()
        StaticFindObject("/Script/SwtQuest.ECharacterRank"):ForEachName(function(n, v) out[n:ToString():gsub("^.*::", "")] = v end)
    end)
    local rank = WaCa.PlayerRank()       -- (the name first, then the save: WaCa.lua)
    return out, rank
end

local function rankAllows()
    local r, rank = ranks()
    return not (rank and r[cfg.maxRank] and rank >= r[cfg.maxRank])
end

-- --- training: a sparring fight ---

local roleNames
local function roleName(v)
    if not roleNames then
        roleNames = {}
        pcall(function()
            StaticFindObject("/Script/SwtQuest.ENarrativeRole"):ForEachName(function(n, x) roleNames[x] = n:ToString():gsub("^.*::", "") end)
        end)
    end
    return roleNames[v]
end

-- the sparring partner: the clan's move teacher (a story cat), else the nearest clanmate - its object path, its story
-- role (for the bond; nil for a plain clanmate) and a name for the cards
local function trainingPartner()
    local p = pc() and pc().Pawn
    if not p then return nil end
    for _, a in ipairs(FindAllOf("QuestBaseActor") or {}) do
        local found
        pcall(function()
            local name = a:IsValid() and not a.bHidden and a.narrativeRole and roleName(a.narrativeRole)
            if name and name:find("WarriorMoveLearn$") then
                found = { path = (a:GetFullName():gsub("^%S+ ", "")), role = a.narrativeRole, who = "the clan's move teacher" }
            end
        end)
        if found then return found end
    end
    local at = p:K2_GetActorLocation()
    local best, bd
    for _, c in ipairs(FindAllOf("BP_Exploration_Character_Base_C") or {}) do
        pcall(function()
            if c:IsValid() and c.CharacterType == 1 and c:GetAddress() ~= p:GetAddress() then
                local q = c:K2_GetActorLocation()
                local d = (q.X - at.X) ^ 2 + (q.Y - at.Y) ^ 2
                if not bd or d < bd then best, bd = c, d end
            end
        end)
    end
    return best and { path = (best:GetFullName():gsub("^%S+ ", "")), who = "a clanmate" } or nil
end

-- the fight, the game's own way: its combat boxes start one when the player's character overlaps them - the handler
-- (SwtAdventureCombatBoxComponent::OnBeginOverlap, exe 0x1417E1370) checks the actor is player-controlled, the
-- component is its capsule and the box's OWNER is not that actor (an owner that is a character is the opponent), then
-- starts combat (0x141803400) with the box's CombatType + CombatTag. So: a box made inside the partner, TrainingGrounds
-- (5) + the TrainingGrounds encounter, its overlap called for the player. VM 2026-10-28: the turn-based fight opens.
local function startSpar(partner)
    local p = pc() and pc().Pawn
    local owner = StaticFindObject(partner.path)
    if not (p and owner and owner:IsValid()) then return false end
    local ok, err = pcall(function()
        local box = StaticConstructObject(StaticFindObject("/Script/SwtAdventure.SwtAdventureCombatBoxComponent"), owner,
            FName("WaCaSparBox"))
        box.CombatType = 5
        box.CombatTag = { TagName = FName(cfg.trainTag) }
        box:OnBeginOverlap(box, p, p.CapsuleComponent, 0, false, {})
    end)
    if not ok then log("duties: the sparring fight didn't start: %s", tostring(err)) end
    return ok
end

-- spots for the patrol: random points in the areas of the generators 20-90 m away (where the clan's prey and
-- threats are - the border of what your cat knows), each marked with the game's quest hint (sense-mode trail)
local function patrolPoints(n)
    local p = pc() and pc().Pawn
    if not p then return {} end
    local at = p:K2_GetActorLocation()
    local candidates = {}
    for _, g in ipairs(FindAllOf("BP_Enemy_Generator_C") or {}) do
        pcall(function()
            local q = g:K2_GetActorLocation()
            local d = math.sqrt((q.X - at.X) ^ 2 + (q.Y - at.Y) ^ 2)
            if d >= cfg.minDist and d <= cfg.maxDist then table.insert(candidates, g) end
        end)
    end
    local out = {}
    local class = WaCa.LoadAsset(HINT)
    -- (not the places of the last patrol again while there are others - operator 2026-10-29: "avoid repeats")
    local fresh = {}
    for _, g in ipairs(candidates) do
        local key = g:GetFName():ToString()
        if not lastPatrol[key] then fresh[#fresh + 1] = g end
    end
    if #fresh >= n then candidates = fresh end
    lastPatrol = {}
    for _ = 1, math.min(n, #candidates) do
        local g = table.remove(candidates, math.random(#candidates))
        lastPatrol[g:GetFName():ToString()] = true
        local ok = pcall(function()
            local area = g.AreaComponent
            local c, e = area:K2_GetComponentLocation(), area:GetScaledBoxExtent()
            local point = { X = c.X + (math.random() * 2 - 1) * e.X * 0.5, Y = c.Y + (math.random() * 2 - 1) * e.Y * 0.5, Z = c.Z }
            local marker = class and p:GetWorld():SpawnActor(class, point, { pitch = 0, Yaw = 0, Roll = 0 })
            if marker and marker:IsValid() then
                pcall(function() marker.SenseTrackedComponent.bTrackingEnabled = true end)
                pcall(function() marker:OnQuestTracked(true, nil) end)
                point.marker = (marker:GetFullName():gsub("^%S+ ", ""))
            end
            table.insert(out, point)
        end)
        if not ok then log("duties: a patrol point couldn't be placed") end
    end
    return out
end

-- GATHERING for the medicine cat (tickets.md "Apprentice duties", operator 2026-10-28: fetch moss / herbs for the
-- medicine cat): n of the game's own pickups out in the territory - moss where the world has it
-- (BP_InteractableReward_Container_Moss), else its herbs (BP_Pickup_*: healing herbs, catnip ...) - each marked like a
-- border point; reaching one gathers it (the game's own pickup works there too). Turned in to the medicine cat.
local GATHER = { "BP_InteractableReward_Container_Moss_C", "BP_Pickup_SmallHealingHerb_C", "BP_Pickup_MediumHealingHerb_C",
                 "BP_Pickup_BigHealingHerb_C", "BP_Pickup_SmallCatnip_C", "BP_Pickup_MediumCatnip_C", "BP_Pickup_BigCatnip_C" }
-- the season now (weather.lua), or nil
local function season()
    local s
    pcall(function() s = require("weather").Season() end)
    return s
end

-- water to soak moss in: the nearest of the game's fishing spots (the stream, the lake) outside camp
local function waterSpot()
    local p = pc() and pc().Pawn
    if not p then return nil end
    local at = p:K2_GetActorLocation()
    local best, bd
    for _, a in ipairs(FindAllOf("BP_Interactable_Claw_FishingSpot_C") or {}) do
        pcall(function()
            local q = a:K2_GetActorLocation()
            local d = math.sqrt((q.X - at.X) ^ 2 + (q.Y - at.Y) ^ 2)
            if d >= cfg.gatherMinDist and d <= cfg.maxDist and (not bd or d < bd) then best, bd = { X = q.X, Y = q.Y, Z = q.Z }, d end
        end)
    end
    return best
end

-- a spot just out of camp (the old bedding goes there): the nearest place the game itself put out in the territory -
-- a herb, a border area - at least the camp's size from its middle; marked when the bedding is taken
local function dumpSpot()
    local c = Duties.Camp and Duties.Camp() or nil
    local mid = c and c.middle
    if not mid then return nil end
    local best, bd
    local function consider(q)
        local d = math.sqrt((q.X - mid.X) ^ 2 + (q.Y - mid.Y) ^ 2)
        if d >= cfg.campRadius and (not bd or d < bd) then best, bd = { X = q.X, Y = q.Y, Z = q.Z }, d end
    end
    for _, cls in ipairs(GATHER) do
        for _, a in ipairs(FindAllOf(cls) or {}) do pcall(function() if not a.bHidden then consider(a:K2_GetActorLocation()) end end) end
    end
    for _, g in ipairs(FindAllOf("BP_Enemy_Generator_C") or {}) do pcall(function() consider(g:K2_GetActorLocation()) end) end
    return best
end

local function gatherPoints(n)
    local p = pc() and pc().Pawn
    if not p then return {}, nil end
    local at = p:K2_GetActorLocation()
    local found, what = {}, nil
    for _, cls in ipairs(GATHER) do
        if #found >= n then break end
        for _, a in ipairs(FindAllOf(cls) or {}) do
            pcall(function()
                if a.bHidden then return end
                local q = a:K2_GetActorLocation()
                local d = math.sqrt((q.X - at.X) ^ 2 + (q.Y - at.Y) ^ 2)
                if d >= cfg.gatherMinDist and d <= cfg.maxDist then
                    found[#found + 1] = { X = q.X, Y = q.Y, Z = q.Z, d = d }
                    what = what or (cls:find("Moss") and "moss" or "herbs")
                end
            end)
        end
    end
    table.sort(found, function(x, y) return x.d < y.d end)
    -- (spots apart from each other: two herbs side by side were gathered in one step - VM 2026-10-31)
    local spaced = {}
    for _, f in ipairs(found) do
        local ok = true
        for _, o in ipairs(spaced) do
            if (f.X - o.X) ^ 2 + (f.Y - o.Y) ^ 2 < (cfg.gatherReach * 4) ^ 2 then ok = false break end
        end
        if ok then spaced[#spaced + 1] = f end
    end
    found = spaced
    local out = {}
    local class = WaCa.LoadAsset(HINT)
    for i = 1, math.min(n, #found) do
        local point = found[i]
        point.d = nil
        pcall(function()
            local marker = class and p:GetWorld():SpawnActor(class, point, { pitch = 0, Yaw = 0, Roll = 0 })
            if marker and marker:IsValid() then
                pcall(function() marker.SenseTrackedComponent.bTrackingEnabled = true end)
                pcall(function() marker:OnQuestTracked(true, nil) end)
                point.marker = (marker:GetFullName():gsub("^%S+ ", ""))
            end
        end)
        out[#out + 1] = point
    end
    return out, what
end

-- the hunting ground for the day's hunt (tickets.md 8, hunting missions): a prey creature about 20-90 m away, its
-- spot marked like the patrol points - the clan sends you where the prey is this season (preyworld.lua hides the
-- rest), the sense trail shows the way
local function huntingGround()
    local p = pc() and pc().Pawn
    if not p then return nil end
    local at = p:K2_GetActorLocation()
    local kinds = {}
    pcall(function()
        StaticFindObject("/Script/SwtQuest.ESwtQuestCharacterType"):ForEachName(function(n, v)
            kinds[v] = (n:ToString():gsub("^.*::", ""):gsub("^Weak", ""))
        end)
    end)
    local prey = { Mice = true, Squirrel = true, Rabbit = true, Bird = true }
    local found = {}
    for _, c in ipairs(FindAllOf("BP_Exploration_Character_Base_C") or {}) do
        pcall(function()
            if c:IsValid() and not c.bHidden and prey[kinds[c.CharacterType] or ""] then
                local q = c:K2_GetActorLocation()
                local d = math.sqrt((q.X - at.X) ^ 2 + (q.Y - at.Y) ^ 2)
                if d >= cfg.minDist and d <= cfg.maxDist then table.insert(found, { q, kinds[c.CharacterType] }) end
            end
        end)
    end
    if #found == 0 then return nil end
    -- (not the spot of the last hunt again, while there are others)
    local fresh = {}
    for _, f in ipairs(found) do
        if not (lastHunt and math.abs(f[1].X - lastHunt.X) < 1 and math.abs(f[1].Y - lastHunt.Y) < 1) then fresh[#fresh + 1] = f end
    end
    if #fresh > 0 then found = fresh end
    local pick = found[math.random(#found)]
    lastHunt = { X = pick[1].X, Y = pick[1].Y }
    local point = { X = pick[1].X, Y = pick[1].Y, Z = pick[1].Z, kind = pick[2] }
    pcall(function()
        local marker = p:GetWorld():SpawnActor(WaCa.LoadAsset(HINT), point, { pitch = 0, Yaw = 0, Roll = 0 })
        pcall(function() marker.SenseTrackedComponent.bTrackingEnabled = true end)
        pcall(function() marker:OnQuestTracked(true, nil) end)
        point.marker = (marker:GetFullName():gsub("^%S+ ", ""))
    end)
    return point
end

-- the clan's fresh-kill pile (its resource component, on the game state) - a finished hunt adds to it the game's way
local function pileComponent()
    for _, comp in ipairs(FindAllOf("SwtAdventureFreshKillPileComponent") or {}) do
        if comp:IsValid() then return comp end
    end
end

-- clanmates on the patrol (tickets.md 7): the nearest clan cats walk with you (follow.lua - they hold back while you
-- sneak) until the patrol is done or the day ends
local function companionsJoin(n)
    if n <= 0 then return nil end
    -- (the walkers' temporary party - it walks on any ground; the AI follow below is the fallback)
    local ok, paths = pcall(function() return require("walkers").Escort(n, "your patrol") end)
    if ok and paths and #paths > 0 then
        log("duties: %d clanmate(s) join your patrol", #paths)
        return { escort = paths }
    end
    local Follow = require("follow")
    local cats = Follow.Nearest(n, cfg.companionRadius)
    if #cats == 0 then return nil end
    log("duties: %d clanmate(s) join your patrol", #cats)
    return Follow.Group(cats, pc().Pawn, { distance = 250, spread = 150 })
end

local function companionsLeave(group)
    if group and group.escort then pcall(function() require("walkers").Unescort(group.escort, "the patrol is over") end)
    elseif group then require("follow").Release(group) end
end

local function removeMarker(point)
    local m = point.marker and StaticFindObject(point.marker)
    if m and m:IsValid() then pcall(function() m:K2_DestroyActor() end) end
    point.marker = nil
end

-- --- places: the camp, patrol points, the guard spot - trigger boxes reported by the native area hook ---

-- the game's own movement-modifier box Blueprint (its overlap is bound there - fishing.lua's pattern), flag cleared:
-- AreaOverlap(nil, area, actor, "1" / "0", flag) when the player's cat walks in / out (areas.cpp)
local areaClass
local areas = {}                  -- area path -> fn(entering)

local function pathOf(o) return (o:GetFullName():gsub("^%S+ ", "")) end

local function placeArea(at, extent, yaw, onChange)
    if not areaClass then
        for _, a in ipairs(FindAllOf("SwtAdventureMovementModifierArea") or {}) do
            if a:IsValid() and a:GetClass():GetFName():ToString():find("^BP_MovementModifier_Loud") then
                areaClass = a:GetClass()
                if WaCaNative_HookAreas then WaCaNative_HookAreas(a:GetAddress()) end
                break
            end
        end
    end
    if not areaClass then return nil end
    local path
    local ok, err = pcall(function()
        local p = pc().Pawn
        local area = p:GetWorld():SpawnActor(areaClass, at, { pitch = 0, Yaw = yaw or 0, Roll = 0 })
        area.MovementFlag = 0
        area.TriggerBox:SetCollisionProfileName(FName("OverlapAllDynamic"), true)
        area.TriggerBox:SetBoxExtent(extent, true)
        path = pathOf(area)
        areas[path] = onChange
    end)
    if not ok then log("duties: a trigger box couldn't be placed (%s)", tostring(err)) end
    return path
end

local function removeArea(path)
    if not path then return end
    areas[path] = nil
    local a = StaticFindObject(path)
    if a and a:IsValid() then pcall(function() a:K2_DestroyActor() end) end
end

local function playerPos()
    local p = pc() and pc().Pawn
    return p and p:K2_GetActorLocation()
end

-- the camp - THE GAME'S OWN: its zone-name triggers (WrcZoneNameTrigger: ZoneCode "R-05", ZoneNameId
-- STR_RIVERCLAN_ZONE_5 = "RiverClan Camp"; big boxes over an area + thin gate pairs where one zone hands over to the next
-- - tools/camp_map.py draws them). The camp's zone = the one whose boxes hold the most of the player's clan's story cats
-- (the deputy, the leader, the medicine cat ...). In / out of camp = the zone the cat last walked into (the triggers'
-- OnOverlapBegin, watched with the entering actor); its gates are the camp's entrances (the night watch's guard spot).
-- Fallback without zones: the story cats' median + a radius, asked at the cat's footsteps.
local camp = { code = nil, boxes = {}, gates = {}, center = nil, inside = false, entry = nil, zoneSeen = false }

local function inBox(b, p, margin)
    local dx, dy = p.X - b.x, p.Y - b.y
    local yaw = math.rad(b.yaw)
    local lx = dx * math.cos(yaw) + dy * math.sin(yaw)
    local ly = -dx * math.sin(yaw) + dy * math.cos(yaw)
    return math.abs(lx) <= b.ex + (margin or 0) and math.abs(ly) <= b.ey + (margin or 0)
end

local function campInside(p)
    if not p then return false end
    if camp.code then
        -- the zone's boxes are its name triggers, not its whole floor (VM: the deputy stands 4.5 m outside them): the
        -- rectangle around its area boxes, + 10 m (VM: every story cat and den door of the camp is in it)
        local h = camp.hull
        return p.X >= h.x0 and p.X <= h.x1 and p.Y >= h.y0 and p.Y <= h.y1
    end
    local c = camp.center
    return c and math.sqrt((p.X - c.X) ^ 2 + (p.Y - c.Y) ^ 2) <= (camp.radius or cfg.campRadius) or false
end

local function clanName()
    return WaCa.PlayerClan()          -- (the cat in the world's, else the save's)
end

-- the game's zone boxes: { code, name, x, y, ex, ey, yaw } (a gate: one side under 1.5 m)
local function zoneBoxes()
    local out = {}
    for _, z in ipairs(FindAllOf("WrcZoneNameTrigger") or {}) do
        pcall(function()
            if not z:IsValid() then return end
            local comp = z.DetectionComponent
            local c, e = comp:K2_GetComponentLocation(), comp:GetScaledBoxExtent()
            table.insert(out, { code = z.ZoneCode:ToString(), name = z.ZoneNameId:ToString(), x = c.X, y = c.Y,
                ex = e.X, ey = e.Y, yaw = comp:K2_GetComponentRotation().Yaw, gate = math.min(e.X, e.Y) < 150 })
        end)
    end
    return out
end

-- a place from the game's own zone triggers: the middle of the zone whose code starts with `match` ("I-": the
-- Island) or whose name id holds it (STR_ISLAND_ZONE) - its area boxes; a zone that only has a gate (the Island: one
-- thin trigger where you step onto it, VM 2026-10-31) - that. nil when no zone matches.
function Duties.ZonePlace(match)
    if WaCa.ZonePlace then return WaCa.ZonePlace(match) end
    local sums = { area = { 0, 0, 0, 0 }, gate = { 0, 0, 0, 0 } }
    for _, z in ipairs(FindAllOf("WrcZoneNameTrigger") or {}) do
        pcall(function()
            if not z:IsValid() then return end
            local code, name = z.ZoneCode:ToString(), z.ZoneNameId:ToString()
            if code:sub(1, #match) ~= match and not name:find(match, 1, true) then return end
            local comp = z.DetectionComponent
            local e = comp:GetScaledBoxExtent()
            local c = comp:K2_GetComponentLocation()
            local t = sums[math.min(e.X, e.Y) < 150 and "gate" or "area"]
            t[1], t[2], t[3], t[4] = t[1] + 1, t[2] + c.X, t[3] + c.Y, t[4] + c.Z
        end)
    end
    local t = sums.area[1] > 0 and sums.area or sums.gate
    if t[1] == 0 then return nil end
    return { X = t[2] / t[1], Y = t[3] / t[1], Z = t[4] / t[1] }
end

local onCamp
local function findCamp()
    local mine = clanName()
    local cats = {}
    for _, a in ipairs(FindAllOf("QuestBaseActor") or {}) do
        pcall(function()
            local r = a:IsValid() and not a.bHidden and a.narrativeRole and roleName(a.narrativeRole)
            if r and mine and r:find("^" .. mine) then table.insert(cats, a:K2_GetActorLocation()) end
        end)
    end
    if #cats == 0 and not mine then
        log("duties: no clan known - back-in-camp can't be told")
        return false
    end
    -- the game's camp zone (VM 2026-10-28, all four: R-05, S-08, T-10, W-04 - "<Clan> Camp"): of the player's clan's
    -- zones (the code's letter = the clan's initial) the one with the most DEN DOORS in its outline (every camp has 6-7;
    -- the other clans' story cats aren't in the world, the doors always are); else the zone holding the most of the
    -- clan's story cats
    local zones = zoneBoxes()
    local hulls = {}
    for _, b in ipairs(zones) do
        if not b.gate then
            local h = hulls[b.code] or { x0 = math.huge, y0 = math.huge, x1 = -math.huge, y1 = -math.huge }
            local r = math.max(b.ex, b.ey)
            h.x0, h.x1 = math.min(h.x0, b.x - r - 1000), math.max(h.x1, b.x + r + 1000)
            h.y0, h.y1 = math.min(h.y0, b.y - r - 1000), math.max(h.y1, b.y + r + 1000)
            hulls[b.code] = h
        end
    end
    local count, why = {}, "den doors"
    local initial = mine and mine:sub(1, 1)
    for _, door in ipairs(FindAllOf("SwtAdventureHousingDoorActor") or {}) do
        pcall(function()
            local q = door:K2_GetActorLocation()
            for code, h in pairs(hulls) do
                if code:sub(1, 1) == initial and q.X >= h.x0 and q.X <= h.x1 and q.Y >= h.y0 and q.Y <= h.y1 then
                    count[code] = (count[code] or 0) + 1
                end
            end
        end)
    end
    local best
    for code, n in pairs(count) do if not best or n > count[best] then best = code end end
    if not (best and count[best] >= 3) then
        count, why, best = {}, "story cats", nil
        for _, b in ipairs(zones) do
            if not b.gate then
                for _, p in ipairs(cats) do if inBox(b, p, 300) then count[b.code] = (count[b.code] or 0) + 1 end end
            end
        end
        for code, n in pairs(count) do if not best or n > count[best] then best = code end end
        if best and count[best] < 2 then best = nil end
    end
    if best then
        camp.code = best
        local h = { x0 = math.huge, y0 = math.huge, x1 = -math.huge, y1 = -math.huge }
        for _, b in ipairs(zones) do
            if b.code == best then
                table.insert(b.gate and camp.gates or camp.boxes, b)
                camp.name = b.name
                -- (the area boxes only: the gates sit on the zone's border, next to the neighbour's - VM: a rectangle
                -- around them took in the neighbouring zone's gate)
                if not b.gate then
                    local r = math.max(b.ex, b.ey)
                    h.x0, h.x1 = math.min(h.x0, b.x - r), math.max(h.x1, b.x + r)
                    h.y0, h.y1 = math.min(h.y0, b.y - r), math.max(h.y1, b.y + r)
                end
            end
        end
        h.x0, h.y0, h.x1, h.y1 = h.x0 - 1000, h.y0 - 1000, h.x1 + 1000, h.y1 + 1000
        camp.hull = h
        camp.inside = campInside(playerPos())
        camp.stepInside = camp.inside
        log("duties: the camp is the game's zone %s (%s): %d areas, %d entrances, %.0f x %.0f m (by its %d %s); your cat is %s",
            best, tostring(camp.name), #camp.boxes, #camp.gates, (h.x1 - h.x0) / 100, (h.y1 - h.y0) / 100, count[best],
            why, camp.inside and "in it" or "out")
        return true
    end
    -- no zones: the story cats' median + the farthest within CampMax
    if #cats == 0 then
        log("duties: no camp zone and no story cats of %s - back-in-camp can't be told", tostring(mine))
        return false
    end
    local xs, ys = {}, {}
    for i, p in ipairs(cats) do xs[i], ys[i] = p.X, p.Y end
    table.sort(xs) table.sort(ys)
    local m = math.floor((#xs + 1) / 2)
    camp.center = { X = xs[m], Y = ys[m], Z = cats[1].Z }
    local far = 0
    for _, p in ipairs(cats) do
        local d = math.sqrt((p.X - camp.center.X) ^ 2 + (p.Y - camp.center.Y) ^ 2)
        if d <= cfg.campMax and d > far then far = d end
    end
    camp.radius = math.max(cfg.campRadius, far + 1000)
    camp.inside = campInside(playerPos())
    log("duties: no camp zone - the camp is around %d story cats, %.0f m across; your cat is %s", #cats,
        camp.radius / 50, camp.inside and "in it" or "out")
    return true
end

-- the guard spot: the camp entrance (gate) nearest to where your cat last came in, else that spot, else an edge
local function guardSpot()
    local ref = camp.entry or playerPos()
    local best, bd
    for _, g in ipairs(camp.gates) do
        local d = ref and ((g.x - ref.X) ^ 2 + (g.y - ref.Y) ^ 2) or 0
        if not bd or d < bd then best, bd = g, d end
    end
    if best then return { X = best.x, Y = best.y, Z = (ref and ref.Z) or 0 } end
    if camp.entry then return camp.entry end
    local c = camp.center
    return c and { X = c.X + (camp.radius or cfg.campRadius), Y = c.Y, Z = c.Z } or nil
end

-- YOUR NEST (operator 2026-10-28: sleep = go to your den and lie down, not a key): the game's own sleep spots
-- (BP_Interactable_Sleep - a nest you use; its sunspot variant is a daytime nap, left out) - the one in camp nearest
-- to your cat, else the nearest at all. Using it at night is sleeping (OnInteracted, watched below).
local SLEEP_CLASS = "^BP_Interactable_Sleep"
local function isNest(actor)
    local ok, name = pcall(function() return actor:GetClass():GetFName():ToString() end)
    return ok and name:find(SLEEP_CLASS) ~= nil and not name:find("Sunspot")
end

local function findNest()
    local p = playerPos()
    if not p then return nil end
    local best, bd, bestCamp, bdCamp
    for _, a in ipairs(FindAllOf("SwtAdventureInteractableActor") or {}) do
        pcall(function()
            if not (a:IsValid() and isNest(a)) then return end
            local q = a:K2_GetActorLocation()
            local d = (q.X - p.X) ^ 2 + (q.Y - p.Y) ^ 2
            if not bd or d < bd then best, bd = q, d end
            if campInside(q) and (not bdCamp or d < bdCamp) then bestCamp, bdCamp = q, d end
        end)
    end
    return bestCamp or best, bestCamp and "in camp" or (best and "outside the camp" or nil)
end

-- YOUR DEN (operator 2026-10-28: rest in EITHER den - the game's own "your den", or the den of your rank): the
-- camp's den doors (WrcHousingDoorActor: Clan, RequiredRank, a DestinationComponent inside - the warriors' door has
-- one per rank: Warrior / Deputy / Leader) take your cat inside; arriving at a fitting den's inside point at night is
-- going to sleep. Fitting: your clan's, and your own den ("My den") or your rank's (by the dens' names).
-- the den of each rank (the game's den names): apprentices, warriors (the deputy too), the leader
local RANK_DENS = { [0] = "STR_DEN_APPRENTICE", "STR_DEN_APPRENTICE", "STR_DEN_WARRIOR", "STR_DEN_WARRIOR", "STR_DEN_LEADER" }

local function enumNames(path)
    local out = {}
    pcall(function()
        StaticFindObject(path):ForEachName(function(n, v) out[v] = (n:ToString():gsub("^.*::", "")) end)
    end)
    return out
end

-- every den of your clan (the old bedding is in all of them): { door, dest, title }
local function allClanDens()
    local clans = enumNames("/Script/SwtQuest.EClanType")
    local mine = clanName()
    local out = {}
    for _, door in ipairs(FindAllOf("WrcHousingDoorActor") or {}) do
        pcall(function()
            if not door:IsValid() or door.bIsExit then return end
            local clan = clans[door.Clan]
            if mine and clan and clan ~= mine then return end
            out[#out + 1] = { door = door:K2_GetActorLocation(), dest = door.DestinationComponent:K2_GetComponentLocation(),
                              title = door.ActorTitle:ToString() }
        end)
    end
    return out
end

local function myDens()
    local clans, rankNames = enumNames("/Script/SwtQuest.EClanType"), enumNames("/Script/SwtQuest.ECharacterRank")
    local mine, rank = clanName(), WaCa.PlayerRank()
    local multiClass = StaticFindObject("/Script/Wrc.WrcHousingMultiRankDestinationDoorActor")
    local out, all = {}, {}
    for _, door in ipairs(FindAllOf("WrcHousingDoorActor") or {}) do
        pcall(function()
            if not door:IsValid() or door.bIsExit then return end
            local clan = clans[door.Clan]
            if mine and clan and clan ~= mine then return end
            local multi = multiClass and door:IsA(multiClass)
            local dest = door.DestinationComponent
            if multi and rank and rank >= 2 then
                dest = (rank >= 4 and door.LeaderDestinationComponent) or (rank == 3 and door.DeputyDestinationComponent)
                    or door.WarriorDestinationComponent
            end
            -- which den it is: its title against the game's own den names (any language); RequiredRank is only who
            -- may go in (every den said Apprentice - VM 2026-10-28)
            local title = door.ActorTitle:ToString()
            local personal = title == WaCa.GetText("STR_DEN_MY") or #door.AllHotspots > 0
            local mine = WaCa.GetText(RANK_DENS[rank or 1] or "STR_DEN_APPRENTICE")
            local fits = personal or title == mine
            local d = { door = door:K2_GetActorLocation(), dest = dest:K2_GetComponentLocation(), personal = personal,
                        title = door.ActorTitle:ToString(), rank = rankNames[door.RequiredRank] or tostring(door.RequiredRank) }
            table.insert(all, string.format("%s%s (%s)%s", d.title ~= "" and d.title or "a den", personal and " [yours]" or "",
                multi and "Warrior/Deputy/Leader" or d.rank, fits and "" or " - not for you"))
            if fits then table.insert(out, d) end
        end)
    end
    log("duties: the dens - %s", #all > 0 and table.concat(all, "; ") or "none found")
    return out
end

-- your clan's leader: the story cat whose narrative role is a leader's (the game names them by their story -
-- RiverClan's is TheMistrustfulLeader, not "RiverClanLeader": the old match found none, operator 2026-10-30) and whose
-- own ClanType (AQuestBaseActor.ClanType, the game's) is your cat's clan; nil when there is none
local function ownLeader()
    -- (your cat's own ClanType - read from the game; nil only before a cat is loaded)
    local mine = clanName()
    if not mine then log("duties: your cat's clan couldn't be read - no cat loaded?") return nil end
    -- (the same role is on a scenery filler too - BP_Quest_Filler_C, parked where nobody sees it: VM 2026-10-30, the
    -- meeting place 14 m from the Lionstar standing in camp. The cat you meet is the one available for quests.)
    local clans = enumNames("/Script/SwtQuest.EClanType")
    local best, bestScore
    for _, a in ipairs(FindAllOf("QuestBaseActor") or {}) do
        pcall(function()
            local r = a:IsValid() and a.narrativeRole and roleName(a.narrativeRole)
            if not (r and r:find("Leader") and clans[a.ClanType] == mine) then return end
            local score = (a.bIsAvailableForQuest and 2 or 0) + (a:GetClass():GetFName():ToString():find("Filler") and 0 or 1)
            if not bestScore or score > bestScore then best, bestScore = a, score end
        end)
    end
    return best
end

-- THE WORLD MAP (mapmarks.lua): each duty's spot gets its mark - the meeting place cyan (MEET_COLOR), the hunting
-- ground green, the patrol's border points orange, your den lavender (operator 2026-10-30: "a cyan map marker for it,
-- etc.")
local MARK_HUNT = { R = 0.45, G = 0.9, B = 0.2, A = 1 }
local MARK_PATROL = { R = 1.0, G = 0.55, B = 0.1, A = 1 }
local MARK_DEN = { R = 0.7, G = 0.6, B = 1.0, A = 1 }
local function mapMark(id, at, color, label)
    pcall(function() require("mapmarks").Set(id, at, color, label) end)
end
local function mapClear(id) pcall(function() require("mapmarks").Clear(id) end) end

-- the meeting place's interactable: the game's generic interactable (BP_Interactable_CInematic - no cinematic set,
-- its editor placeholder mesh hidden), so the game itself shows "Interact" when your cat is near (VM 2026-10-30: the
-- cinematic interactable prompts wherever it is spawned; the placed rocks / sunspots don't, or go on cooldown)
local GLOW = "/Game/Art/Vfx/Niagaras/GameplayElements/NS_Scent_Hint_Item.NS_Scent_Hint_Item"
local MEET_COLOR = { R = 0.0, G = 0.9, B = 1.0, A = 1.0 }          -- cyan: clan management
local GLOW_SCALE, GLOW_EVERY = 1.6, 2500
local SPOT = "/Game/Gameplay/Blueprints/WorldElements/Interactables/BP_Interactable_CInematic.BP_Interactable_CInematic_C"
local function meetingSpot(point)
    local path
    pcall(function()
        local a = pc().Pawn:GetWorld():SpawnActor(WaCa.LoadAsset(SPOT), point, { pitch = 0, Yaw = 0, Roll = 0 })
        pcall(function() a.StaticMeshComponent:SetVisibility(false, false) end)
        path = pathOf(a)
    end)
    -- ITS MARK (operator 2026-10-30: the gold glow, in cyan): the game's scent hint glow (NS_Scent_Hint_Item) with its
    -- own colour parameter (User.Code_Color) set - on the ground at the spot, removed with it (cleanup)
    local glow
    local ok, err = pcall(function()
        local lib = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
        local fx = lib:SpawnSystemAtLocation(FindFirstOf("World"), WaCa.LoadAsset(GLOW),
            { X = point.X, Y = point.Y, Z = point.Z - 40 }, { pitch = 0, Yaw = 0, Roll = 0 },
            { X = GLOW_SCALE, Y = GLOW_SCALE, Z = GLOW_SCALE }, false, false, 0, true)
        fx:SetVariableLinearColor(FName("Code_Color"), MEET_COLOR)
        fx:Activate(true)
        glow = pathOf(fx)
    end)
    if not ok then log("duties: the meeting place's glow couldn't be made (%s)", tostring(err)) end
    -- (the glow is one short burst - VM 2026-10-30: gone after a few seconds - so it plays again every GLOW_EVERY ms
    -- while its spot stands; the chain ends with the spot)
    local function pulse()
        local g, s = glow and StaticFindObject(glow), path and StaticFindObject(path)
        if not (g and g:IsValid() and s and s:IsValid()) then return end
        pcall(function() g:ResetSystem() end)
        ExecuteInGameThreadWithDelay(GLOW_EVERY, pulse)
    end
    if glow then ExecuteInGameThreadWithDelay(GLOW_EVERY, pulse) end
    return path, glow
end

-- WHERE the meeting spot goes (operator 2026-10-30: it sat inside the rock under the leader, and must not share its
-- place with a cat you can talk to - the leader's own Talk took the interact): open, standable ground 2.5 - 4.5 m
-- around the leader, at least 2.5 m from every story cat, the one nearest the camp's middle. Read off the world itself
-- (the camp has no navigation mesh - VM: every projection came back unmoved): terrain / rock / tree (world static)
-- ground about the leader's height under it, 3 m of air over it (not under a fallen trunk), nothing at knee height
-- 60 cm around it (not inside a rock or against a wall).
local kismetLib
local NONE = { R = 0, G = 0, B = 0, A = 0 }
local function traceHit(pawn, from, to)
    kismetLib = kismetLib or StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local hit = {}
    local ok, yes = pcall(function()
        return kismetLib:LineTraceSingleForObjects(pawn, from, to, { 0 }, false, { pawn }, 0, hit, true, NONE, NONE, 0)
    end)
    if not (ok and yes) then return nil end
    local z
    pcall(function() z = hit.ImpactPoint.Z end)
    if not z then pcall(function() z = hit.Location.Z end) end
    return z or to.Z
end

local function standable(pawn, x, y, nearZ)
    local gz = traceHit(pawn, { X = x, Y = y, Z = nearZ + 150 }, { X = x, Y = y, Z = nearZ - 300 })
    if not gz or math.abs(gz - nearZ) > 150 then return nil end
    if traceHit(pawn, { X = x, Y = y, Z = gz + 40 }, { X = x, Y = y, Z = gz + 300 }) then return nil end
    for k = 0, 3 do
        local a = k * math.pi / 2
        if traceHit(pawn, { X = x, Y = y, Z = gz + 40 }, { X = x + math.cos(a) * 60, Y = y + math.sin(a) * 60, Z = gz + 40 }) then
            return nil
        end
    end
    return gz
end

local function meetingPoint(leaderAt)
    local pawn = pc() and pc().Pawn
    if not pawn then return nil end
    local cats = {}
    for _, a in ipairs(FindAllOf("QuestBaseActor") or {}) do
        pcall(function() if a:IsValid() and not a.bHidden then cats[#cats + 1] = a:K2_GetActorLocation() end end)
    end
    -- (the leader's feet: the ground under it)
    local feet = traceHit(pawn, { X = leaderAt.X, Y = leaderAt.Y, Z = leaderAt.Z + 50 }, { X = leaderAt.X, Y = leaderAt.Y, Z = leaderAt.Z - 400 })
        or leaderAt.Z - 40
    local mid = Duties.Camp().middle or leaderAt
    local best, bestScore
    for _, r in ipairs({ 250, 350, 450 }) do
        for k = 0, 11 do
            local ang = k * math.pi / 6
            local x, y = leaderAt.X + math.cos(ang) * r, leaderAt.Y + math.sin(ang) * r
            local gz = standable(pawn, x, y, feet)
            if gz then
                local clear = true
                for _, c in ipairs(cats) do
                    if math.sqrt((c.X - x) ^ 2 + (c.Y - y) ^ 2) < 250 then clear = false break end
                end
                if clear then
                    local score = math.sqrt((mid.X - x) ^ 2 + (mid.Y - y) ^ 2)
                    if not bestScore or score < bestScore then best, bestScore = { X = x, Y = y, Z = gz }, score end
                end
            end
        end
    end
    return best
end

-- how near counts as at the spot: its own interaction shape (what the game prompts by)
local function spotReach(a)
    local r
    pcall(function()
        local c = a.InteractionComponents[1]
        r = c:GetScaledSphereRadius()
    end)
    if not r then pcall(function() r = a.InteractionComponent:GetScaledSphereRadius() end) end
    return (r and r > 0 and r or 150) + 60
end

local function marker(point)
    local path
    pcall(function()
        local m = pc().Pawn:GetWorld():SpawnActor(WaCa.LoadAsset(HINT), point, { pitch = 0, Yaw = 0, Roll = 0 })
        pcall(function() m.SenseTrackedComponent.bTrackingEnabled = true end)
        pcall(function() m:OnQuestTracked(true, nil) end)
        path = pathOf(m)
    end)
    return path
end

-- --- the loop ---

local NAMES = { Hunt = "hunting", Patrol = "patrol", Train = "training", Free = "free time", NightWatch = "night watch",
                Gather = "gathering", Bedding = "the dens' bedding", Water = "water for the elders",
                Sleep = "sleep" }

local function thirdName(i) return THIRDS[i or (today and today.third) or 1] or "Night" end
-- what the player reads: the config's Noon is the afternoon
local LABELS = { Noon = "Afternoon" }
local function thirdLabel(i)
    local n = thirdName(i)
    return LABELS[n] or n
end

local function thirdAt(h)
    local hs = cfg.hours
    local function within(a, b) return (h - a) % 24 < (b - a) % 24 end
    if within(hs.Morning, hs.Noon) then return 1 end
    if within(hs.Noon, hs.Evening) then return 2 end
    if within(hs.Evening, hs.Night) then return 3 end
    return 4
end

local function describe(t)
    if not t then return "" end
    if t.kind == "Hunt" then return string.format("hunt %d prey (%d)", t.need, t.got) end
    if t.kind == "Patrol" and t.points then
        local d = 0
        for _, pt in ipairs(t.points) do if pt.done then d = d + 1 end end
        return string.format("patrol %d border points (%d)", #t.points, d)
    end
    if t.kind == "Train" and t.who then return "spar with " .. t.who end
    if t.kind == "Water" and t.points then
        return t.points[1].done and "bring the wet moss to the elders" or "soak moss in the stream for the elders"
    end
    if t.kind == "Bedding" and t.points then
        return t.points[1].done and "throw the old bedding out of camp" or ("take the old bedding out of the " .. (t.den or "den"))
    end
    if t.kind == "Gather" and t.points then
        local d = 0
        for _, pt in ipairs(t.points) do if pt.done then d = d + 1 end end
        return string.format("gather %s for the medicine cat (%d of %d)", t.what or "herbs", d, #t.points)
    end
    return NAMES[t.kind] or t.kind
end

-- THE DAY AT A GLANCE (WaCa topic "clan.status", sticky - hud.lua shows it as an objective panel like the game's own,
-- any mod can show it its own way). { v = 1, day, third, stage, task (kind), turnIn,
--   title ("Day 18 - Morning"), where (where to go, or nil), activity ("Hunt for the clan:"),
--   goal ("Prey"), got, need (nil when the goal has no count), done (the goal is met), text (all of it on one line) }.
-- Published whenever the day moves on or the task makes progress.
local lastStatus
local function publishStatus()
    if not today then return end
    local t = today.task
    local s = { v = 1, day = today.day, third = thirdName(), stage = today.stage, task = t and t.kind,
                turnIn = today.stage == "turnin" and today.turnIn or nil }
    s.title = string.format("Day %d - %s", today.day, thirdLabel())
    if today.stage == "turnin" then
        local how = today.turnIn
        s.activity = (NAMES[t and t.kind or "Free"] or "task"):gsub("^%l", string.upper) .. " done - turn it in:"
        if how == "Camp" then
            s.activity = "You lead the clan's " .. thirdLabel():lower() .. "."
            s.where, s.goal = "The meeting place, next to your leader", "Give out the clan's tasks there"
        elseif how == "Pile" then
            s.where, s.goal = "Camp", "Bring your catch to the fresh-kill pile"
        elseif how == "Partner" then
            s.where, s.goal = "Camp", "Talk to " .. ((t and t.who) or "your partner")
        else
            -- (MedicineCat -> "medicine cat": VM 2026-10-31 showed "Report to the medicinecat")
            s.where, s.goal = "Camp", "Report to the " .. tostring(how):gsub("(%l)(%u)", "%1 %2"):lower()
        end
    elseif today.stage == "event" then
        s.where = "Camp"
        s.activity = today.third == 3 and "The clan eats and shares tongues." or "The clan comes together."
    elseif today.stage == "sleeping" then
        s.where, s.activity = "Your den", "Asleep."
    elseif today.stage == "sleep" or (t and t.kind == "Sleep") then
        s.where, s.activity, s.goal = "Your den", "Night falls.", "Sleep in your nest"
        if (cfg.restKey or "") ~= "" then s.goal = s.goal .. " (or " .. cfg.restKey .. ")" end
    elseif t and t.kind == "NightWatch" then
        s.where, s.activity = "The camp's entrance", "Keep watch through the night:"
        s.goal, s.done = "Take your guard post", t.done
    elseif t and t.kind == "Hunt" then
        s.where, s.activity, s.goal, s.got, s.need = "The hunting grounds", "Hunt for the clan:", "Prey", t.got, t.need
        s.done = t.got >= t.need
    elseif t and t.kind == "Patrol" and t.points then
        s.where, s.activity, s.goal, s.got, s.need = "The border", "Patrol the border:", "Border points", 0, #t.points
        for _, pt in ipairs(t.points) do if pt.done then s.got = s.got + 1 end end
        s.done = s.got >= s.need
    elseif t and t.kind == "Water" and t.points then
        s.where, s.activity, s.goal = "The water (marked)", "Water for the elders:", "Soak moss in the water"
        s.got, s.need, s.done = t.points[1].done and 1 or 0, 1, t.points[1].done
    elseif t and t.kind == "Bedding" and t.points then
        local took = t.points[1].done
        s.where = took and "Out of camp (marked)" or (t.den or "A den")
        s.activity = "Clear out the old bedding:"
        s.goal = took and "Throw it out of camp" or "Take the old moss from the den"
        s.got, s.need = (took and 1 or 0) + (t.points[2].done and 1 or 0), 2
        s.done = s.got >= 2
    elseif t and t.kind == "Gather" and t.points then
        s.where, s.activity = "The territory", "Gather for the medicine cat:"
        s.goal, s.got, s.need = (t.what or "herbs"):gsub("^%l", string.upper), 0, #t.points
        for _, pt in ipairs(t.points) do if pt.done then s.got = s.got + 1 end end
        s.done = s.got >= s.need
    elseif t and t.kind == "Train" then
        s.where, s.activity, s.goal, s.done = "The training ground", "Train:", "Spar with " .. (t.who or "your mentor"), t.done
    elseif t and t.kind == "Free" then
        s.activity = "Free time - the forest is yours."
    else
        s.where, s.activity = "Camp", "The deputy gives out the tasks."
    end
    s.text = s.title .. ": " .. s.activity .. (s.goal and (" " .. s.goal) or "") ..
        (s.need and string.format(" %d/%d", s.got, s.need) or "") .. (s.done and " - done" or "")
    if s.text == lastStatus then return end
    lastStatus = s.text
    WaCa.Publish("clan.status", s, true)
end

-- the status once the current chain of the loop has run (an event can come before the stage it leads to is set)
local statusDue = false
local function statusSoon()
    if statusDue then return end
    statusDue = true
    ExecuteInGameThread(function()
        statusDue = false
        local ok, err = pcall(publishStatus)
        if not ok then log("duties: status failed (%s)", tostring(err)) end
    end)
end

-- where your clan's leader speaks from ([MeetingPlace] in duties.ini, per clan - the game's text names none): the
-- lake era's (ThunderClan's Highledge - Highrock was the old forest's: operator 2026-10-28), else Default
local function meetingPlace()
    local clan = WaCa.PlayerClan and WaCa.PlayerClan() or nil
    local places = cfg.meetingPlaces or {}
    return (clan and places[clan]) or places.Default or "the leader's rock"
end

local function context()
    local t = today and today.task
    return { DAY = today and today.day, THIRD = thirdLabel():lower(), TASK = t and describe(t) or "",
             N = t and (t.need or (t.points and #t.points)) or "", DEPUTY = cfg.deputyName,
             WHO = t and t.who or "", RESTKEY = cfg.restKey, MEETINGPLACE = meetingPlace() }
end

local function append(into, steps) for _, s in ipairs(steps or {}) do table.insert(into, s) end end
local function hook(name) return { kind = "Hook", value = name } end

-- move the sky on to a later third's hour of the same day - never across the morning (the next day comes only with a
-- rest or the night watch: VM 2026-10-28, a restored night hour moved "to the night" went round the clock and ended
-- two days at once), and not at all when the clock is in that third already (a session starting mid-third)
local function setClock(name)
    local h = DayNight.Hour()
    if not h then return end
    local want = name == "Night" and 4 or (name == "Noon" and 2 or (name == "Evening" and 3 or 1))
    local now = thirdAt(h)
    if now >= want then return end
    local diff = (cfg.hours[name] - h) % 24
    if diff > 1e-6 then DayNight.Advance(diff) end
end

local function pileValue()
    local pile = 100
    pcall(function() pile = tonumber(WaCa.GameProgress().FreshKill.Value) or 100 end)
    return pile
end

-- the third's task: the story's choice, else picked by weight ([Tasks]) from the clan's needs - hunting counts
-- PileFactor x when the fresh-kill pile is low, training only up to [Train] MaxRank
local function weights(text)
    local out = {}
    for kind, w in tostring(text):gmatch("(%a+)%s*:%s*([%d%.]+)") do out[kind] = tonumber(w) end
    return out
end

-- the picks so far, newest last: { third, kind } - a task the cat just had is less likely next (RepeatFactor per time
-- in the same third's last RepeatMemory picks, and once more for the third right before; operator 2026-10-29: "our
-- random pick needs to avoid repeats")
local picked = {}

local function pickKind(name)
    if plan and plan.kinds and plan.kinds[name] then
        picked[#picked + 1] = { third = name, kind = plan.kinds[name] }
        log("duties: %s's task %s - the story day's", name, plan.kinds[name])
        return plan.kinds[name]
    end
    local r, rank = ranks()
    local canTrain = cfg.train and not (rank and r[cfg.trainMaxRank] and rank > r[cfg.trainMaxRank])
    local low = pileValue() < cfg.pileLow
    local options, total = {}, 0
    -- (the story day's own chances for this third - days.ini <Third>Duties - else the clan's, duties.ini [Tasks])
    local base = (plan and plan.weights and plan.weights[name]) or cfg.weights[name] or {}
    local last = picked[#picked]
    for kind, weight in pairs(base) do
        local x = weight
        local same = 0
        for i = #picked, math.max(1, #picked - cfg.repeatMemory * 4 + 1), -1 do
            if picked[i].third == name and picked[i].kind == kind and same < cfg.repeatMemory then same = same + 1 end
        end
        if last and last.kind == kind then same = same + 1 end
        if same > 0 then x = x * cfg.repeatFactor ^ same end
        if kind == "Hunt" and low then x = x * cfg.pileFactor end
        if kind == "Train" and not canTrain then x = 0 end
        if kind == "Water" and season() == "Greenleaf" then x = x * cfg.waterGreenleaf end
        if (kind == "Gather" or kind == "Bedding" or kind == "Water") and not (rank and r[cfg.gatherMaxRank] and rank <= r[cfg.gatherMaxRank]) then
            x = 0
        end
        if kind == "Hunt" and plan and plan.hunt == 0 then x = 0 end
        if kind == "Patrol" and plan and plan.patrol == 0 then x = 0 end
        if x > 0 then
            table.insert(options, { kind, x })
            total = total + x
        end
    end
    local function remember(kind)
        picked[#picked + 1] = { third = name, kind = kind }
        while #picked > 40 do table.remove(picked, 1) end
        local parts = {}
        for _, o in ipairs(options) do parts[#parts + 1] = string.format("%s %.2f", o[1], o[2]) end
        log("duties: %s's task %s - chances %s%s", name, kind, table.concat(parts, ", "),
            (plan and plan.weights and plan.weights[name]) and " (the story day's)" or "")
        return kind
    end
    if total <= 0 then return remember(name == "Night" and "Sleep" or "Free") end
    local roll = math.random() * total
    for _, o in ipairs(options) do
        roll = roll - o[2]
        if roll <= 0 then return remember(o[1]) end
    end
    return remember(options[#options][1])
end

local taskDone, thirdEnd, startThird, sleepNow, talkLine, setTalk, startWhenFree, waitingToStart

local function cleanup(t)
    if t.ground then removeMarker(t.ground) mapClear("hunt") end
    for i, pt in ipairs(t.points or {}) do
        if t.kind ~= "Bedding" and t.kind ~= "Water" then mapClear((t.kind == "Gather" and "gather" or "patrol") .. i) end
        removeMarker(pt)
        removeArea(pt.area)
    end
    removeArea(t.area)
    if t.guardMarker then removeMarker({ marker = t.guardMarker }) end
    if t.nestMarker then removeMarker({ marker = t.nestMarker }) end
    if t.denMarker then mapClear("den") end
    if t.kind == "Bedding" then mapClear("bedding") end
    if t.kind == "Water" then mapClear("water") end
    if t.meetMarker then removeMarker({ marker = t.meetMarker }) end
    if t.meetSpot then removeMarker({ marker = t.meetSpot }) end
    if t.meetSpot then require("mapmarks").Clear("meeting") end
    if t.meetGlow then
        local g = StaticFindObject(t.meetGlow)
        if g and g:IsValid() then pcall(function() g:DestroyComponent(g) end) end
        t.meetGlow = nil
    end
    if t.denMarker then removeMarker({ marker = t.denMarker }) end
    companionsLeave(t.companions)
    t.companions = nil
end

-- a patrol point / the teacher / the guard spot reached
local function reached(t, what, i)
    if t.done or not today or today.task ~= t then return end
    if what == "point" and t.kind == "Water" then
        local pt = t.points[1]
        if pt.done then return end
        pt.done = true
        removeMarker(pt)
        mapClear("water")
        log("duties: moss soaked for the elders")
        card("The moss soaks up the cool water. Carry it to the elders.")
        taskDone(t)
        statusSoon()
        return
    end
    if what == "point" and t.kind == "Bedding" then
        local pt = t.points[i]
        if pt.done or (i == 2 and not t.points[1].done) then return end
        pt.done = true
        if i == 1 then
            log("duties: the old bedding taken from the %s", t.den or "den")
            if t.denMarker then removeMarker({ marker = t.denMarker }) t.denMarker = nil end
            mapClear("den")
            t.points[2].marker = marker(t.points[2])
            mapMark("bedding", t.points[2], MARK_PATROL, "Throw the old bedding out")
            card("You gather up the old, flattened moss. Carry it out of camp.")
        else
            log("duties: the old bedding thrown out of camp")
            removeMarker(t.points[2])
            mapClear("bedding")
            taskDone(t)
        end
        statusSoon()
        return
    end
    if what == "point" then
        local pt = t.points[i]
        if pt.done then return end
        pt.done = true
        removeMarker(pt)
        removeArea(pt.area)
        local gathering = t.kind == "Gather"
        log(gathering and "duties: %s gathered (%d)" or "duties: border point %d checked", gathering and t.what or i, i)
        local all = true
        for _, q in ipairs(t.points) do if not q.done then all = false end end
        if all then taskDone(t)
        else card(string.format(gathering and "Gathered - %s." or "Border point checked - %s.", describe(t))) end
        statusSoon()
    elseif what == "teacher" then
        if t.fighting or WaCa.InMenu() then return end
        if startSpar(t) then
            t.fighting = true
            log("duties: sparring with %s", t.who)
        end
    elseif what == "guard" then
        t.done = true
        cleanup(t)
        log("duties: on night watch")
        local steps = {}
        append(steps, cfg.watchScene)
        table.insert(steps, hook("ClanNight"))
        Events.Run(steps, function()
            WaCa.Emit("TaskDone", today.day, "Night", "NightWatch")
            today.blackout = true
            DayNight.Skip(1)            -- the night passes: DayEnded (the verdict), DayStarted (the morning)
        end, context())
    end
end

-- the task's setup: markers out in the territory, trigger boxes, companions, the partner
local function setUp(kind)
    local t = { kind = kind, third = today.third }
    if kind == "Hunt" then
        t.need = math.max(1, (plan and plan.hunt) or (pileValue() < cfg.pileLow and cfg.huntMax or math.random(cfg.huntMin, cfg.huntMax)))
        t.got = 0
        if cfg.huntingGround then t.ground = huntingGround() end
        if t.ground then mapMark("hunt", t.ground, MARK_HUNT, "Hunting ground: " .. (t.ground.kind or "prey")) end
    elseif kind == "Patrol" then
        t.points = patrolPoints((plan and plan.patrol) or cfg.patrolPoints)
        if #t.points == 0 then
            log("duties: no border points to place - free time instead")
            t.kind, t.points = "Free", nil
        else
            for i, pt in ipairs(t.points) do
                mapMark("patrol" .. i, pt, MARK_PATROL, "Border point " .. i)
                pt.area = placeArea(pt, { X = cfg.reach, Y = cfg.reach, Z = 1000 }, 0, function(entering)
                    if entering then reached(t, "point", i) end
                end)
            end
            t.companions = companionsJoin(cfg.companions)
        end
    elseif kind == "Water" then
        -- (tickets.md "Apprentice duties": soak moss in the stream and bring it to the elders - they drink from it)
        local spot = waterSpot()
        if not spot then
            log("duties: no water near enough to soak moss - free time instead")
            t.kind = "Free"
        else
            t.points = { spot }
            spot.marker = marker(spot)
            mapMark("water", spot, MARK_PATROL, "Soak moss here")
            log("duties: water for the elders - soak moss at %.0f %.0f", spot.X, spot.Y)
        end
    elseif kind == "Bedding" then
        -- (tickets.md "Apprentice duties": clear out the old bedding moss - into a den for it, then out of camp)
        local dens = {}
        pcall(function() dens = allClanDens() end)
        local den = #dens > 0 and dens[math.random(#dens)] or nil
        local dump = den and dumpSpot()
        if not (den and dump) then
            log("duties: no den / no spot out of camp for the old bedding - free time instead")
            t.kind = "Free"
        else
            t.den = den.title ~= "" and den.title or "den"
            t.points = { { X = den.dest.X, Y = den.dest.Y, Z = den.dest.Z }, dump }
            t.denMarker = marker(den.door)
            mapMark("den", den.door, MARK_DEN, t.den .. ": old bedding")
            log("duties: the old bedding - from the %s (inside at %.0f %.0f %.0f), out of camp at %.0f %.0f", t.den,
                den.dest.X, den.dest.Y, den.dest.Z, dump.X, dump.Y)
        end
    elseif kind == "Gather" then
        t.points, t.what = gatherPoints(cfg.gatherCount)
        if #t.points == 0 then
            log("duties: nothing to gather near enough - free time instead")
            t.kind, t.points = "Free", nil
        else
            for i, pt in ipairs(t.points) do
                mapMark("gather" .. i, pt, MARK_HUNT, "Gather " .. (t.what or "herbs"))
                pt.area = placeArea(pt, { X = cfg.gatherReach, Y = cfg.gatherReach, Z = 1000 }, 0, function(entering)
                    if entering then reached(t, "point", i) end
                end)
            end
            log("duties: gather %s - %d spots marked (the game's own %s)", t.what, #t.points, t.what)
        end
    elseif kind == "Train" then
        local partner = trainingPartner()
        if partner then
            t.path, t.role, t.who = partner.path, partner.role, partner.who
            local a = StaticFindObject(t.path)
            if a and a:IsValid() then
                t.area = placeArea(a:K2_GetActorLocation(), { X = cfg.reach / 2, Y = cfg.reach / 2, Z = 500 }, 0, function(entering)
                    if entering then reached(t, "teacher") end
                end)
            end
        else
            log("duties: no one to train with - free time instead")
            t.kind = "Free"
        end
    elseif kind == "Sleep" then
        -- your den (yours or your rank's: walk in, and you sleep), else a nest out in the open (use it)
        t.dens = myDens()
        local show
        for _, d in ipairs(t.dens) do if not d.personal then show = d break end end
        show = show or t.dens[1]
        if show then
            t.denMarker = marker(show.door)
            mapMark("den", show.door, MARK_DEN, show.title .. ": sleep")
            log("duties: %d den(s) to sleep in - marked: %s", #t.dens, show.title)
        end
        local nest, where = findNest()
        if nest then
            t.nest = nest
            if not show then t.nestMarker = marker(nest) end
            log("duties: a nest to sleep in - %s (%.0f %.0f)", where, nest.X, nest.Y)
        elseif not show then
            log("duties: no den or nest found - sleep with the rest key%s", (cfg.restKey or "") == "" and " (none set: timeskip.ini RestKey)" or "")
        end
    elseif kind == "NightWatch" then
        local spot = guardSpot()
        if spot then
            t.spot = spot
            t.guardMarker = marker(spot)
        else
            log("duties: no guard spot (no camp) - sleep instead")
            t.kind = "Sleep"
        end
    end
    return t
end

-- the deputy assigns the third's task
local function assign()
    local name = thirdName()
    local kind = pickKind(name)
    if today.lead and today.third <= 2 then kind = "Free" end
    if not KINDS[kind] then
        log("duties: unknown task %s for the %s - free time", tostring(kind), name)
        kind = "Free"
    end
    local t = setUp(kind)
    today.task, today.stage = t, "task"
    table.insert(today.record, t)
    log("duties: day %d, %s - %s: %s", today.day, name, today.lead and "your own" or "the deputy", describe(t))
    WaCa.Emit("TaskAssigned", today.day, name, t.kind)
    local steps = {}
    if today.lead and t.kind == "Free" then
        -- leading = giving out the clan's tasks at its meeting place (operator 2026-10-28; the full management UI is a
        -- ticket): the leader's spot in camp, else the camp's middle - marked; the report key there ends the third
        t.lead = true
        -- THE MEETING PLACE (operator 2026-10-30: "a location, that's marked, and when you go near, appears as
        -- interactable, like any other location" - a key pressed somewhere in an area was illegible): next to your
        -- clan's leader in camp (else the camp's middle), a game interactable (meetingSpot) - the game shows its own
        -- "Interact" prompt there; interacting gives out the tasks (meetingInteract)
        local leader = ownLeader()
        local at = leader and leader:IsValid() and leader:K2_GetActorLocation()
        local where
        if at and campInside(at) then
            where = roleName(leader.narrativeRole)
        else
            at = Duties.Camp().middle
            where = "the camp's middle (" .. (leader and "your leader is out of camp" or "no leader of your clan found") .. ")"
        end
        local ground = at and meetingPoint(at)
        if at and not ground then log("duties: no walkable spot clear of the story cats near %s - the spot goes there", where) end
        at = ground and { X = ground.X, Y = ground.Y, Z = ground.Z + 40 } or at
        if at then
            t.meet = { X = at.X, Y = at.Y, Z = at.Z }
            t.meetSpot, t.meetGlow = meetingSpot(t.meet)
            require("mapmarks").Set("meeting", t.meet, MEET_COLOR, "Meeting place: give out the clan's tasks")            -- (and on the world map, cyan)
            -- (no quest hint marker here: once tracked it guides to the tracked QUEST's objective - the main quest's
            -- StarClan marker far off, operator 2026-10-30; the cyan glow marks the spot)
        end
        log("duties: the clan's meeting place: %s (%s), %s", where, at and string.format("%.0f %.0f", at.X, at.Y) or "-",
            t.meetSpot and "interactable" or "NO interactable spawned")
        append(steps, { { kind = "Card", value = "Give out the clan's tasks at the meeting place." } })
    else
        append(steps, cfg.assignScenes[t.kind] or { { kind = "Card", value = "{DEPUTY}: {TASK}." } })
    end
    table.insert(steps, hook("ClanAssign"))
    Events.Run(steps, function()
        if t.kind == "Free" then taskDone(t) end
        if t.kind == "Sleep" then today.stage = "sleep" end
        statusSoon()
    end, context())
end

-- the task is done: the rest of the third is yours - its turn-in (when you like) ends the third
taskDone = function(t)
    if t.done and t.kind ~= "Free" and t.kind ~= "Hunt" then return end
    local first = not t.done
    t.done = true
    -- (a hunt's ground stays: hunt on as long as you like; a lead third's meeting place stays until the tasks are out)
    if t.kind ~= "Hunt" and not t.lead then cleanup(t) end
    if first then
        log("duties: %s - %s done", thirdName(), NAMES[t.kind])
        WaCa.Emit("TaskDone", today.day, thirdName(), t.kind)
    end
    if today.task ~= t or today.stage ~= "task" then return end
    -- the task's END POINT (operator 2026-10-28: not just walking into camp): its turn-in ([Task.<Kind>] TurnIn) -
    -- Pile = the catch onto the fresh-kill pile, Partner = talk to the cat the task was with (training: the mentor),
    -- a role (Deputy, Leader, MedicineCat ...) = report to that cat, None = done is the end
    local turnIn = (t.lead and "Camp") or cfg.turnIn[t.kind] or "None"
    if turnIn == "None" then
        today.stage = "turnin"
        return thirdEnd()
    end
    today.stage = "turnin"
    today.turnIn = turnIn
    -- (short - operator 2026-10-28: too much text; the day panel carries the details)
    if t.lead or t.kind == "Free" then return end      -- (its card was the assignment's)
    local after = { Hunt = "Hunt done.", Patrol = "Patrol done.", Train = "Training done." }
    local where = { Pile = "Take your catch to the fresh-kill pile.", Partner = "Talk to " .. (t.who or "them") .. "." }
    card((after[t.kind] or "Done.") .. " " .. (where[turnIn] or ("Report to the " .. turnIn:lower() .. ".")))
end

-- the turn-in happened: the third ends (Pile: the game's own contribution; Partner / a role: a talk with that cat)
local function turnedIn(how)
    if not today or today.stage ~= "turnin" or today.turnIn ~= how then return false end
    log("duties: %s turned in (%s)", NAMES[today.task and today.task.kind or "Free"] or "task", how)
    WaCa.Emit("TaskTurnedIn", today.day, thirdName(), today.task and today.task.kind, how)
    if today.task and today.task.lead then cleanup(today.task) end
    thirdEnd()
    return true
end

-- REPORTING WITHOUT A CONVERSATION ([Duties] ReportKey, default F): a talk turn-in (Deputy / Partner / a role) also
-- happens with the report key next to that cat - the game doesn't offer every cat a conversation at every moment (a
-- deputy whose story line is used up has nothing to say), and a turn-in that can't be done would stall the clan's day.
-- The cat to report to: the task's partner (by its path), else the nearest story cat whose role ends with the turn-in
-- (Deputy matches ThunderClanDeputy ...), within ReportRadius.
local function reportTarget(how)
    local pawn = pc() and pc().Pawn
    if not (pawn and pawn:IsValid()) then return nil end
    local at, best, bd = pawn:K2_GetActorLocation(), nil, nil
    for _, a in ipairs(FindAllOf("QuestBaseActor") or {}) do
        pcall(function()
            if not a:IsValid() or a.bHidden then return end
            local fits
            if how == "Partner" then
                fits = today.task and today.task.path and pathOf(a) == today.task.path
            else
                fits = a.narrativeRole and a.narrativeRole > 0 and roleName(a.narrativeRole):find(how .. "$") ~= nil
            end
            if not fits then return end
            local p = a:K2_GetActorLocation()
            local d = math.sqrt((p.X - at.X) ^ 2 + (p.Y - at.Y) ^ 2)
            if d <= cfg.reportRadius and (not bd or d < bd) then best, bd = a, d end
        end)
    end
    return best, bd
end

-- the game's interact (Player_Interact) at the meeting place: the tasks are given out, the third ends
local PLAYER_INTERACT = 65
local function meetingInteract()
    local t = today and today.task
    if not (t and t.meetSpot and today.stage == "turnin" and today.turnIn == "Camp") then return end
    local a, p = StaticFindObject(t.meetSpot), playerPos()
    if not (a and a:IsValid() and p) then return end
    local q = a:K2_GetActorLocation()
    local d = math.sqrt((q.X - p.X) ^ 2 + (q.Y - p.Y) ^ 2)
    if d > spotReach(a) then return end
    log("duties: your cat gives out the clan's tasks at the meeting place - the %s ends", thirdName():lower())
    turnedIn("Camp")
end

local function reportKey()
    local how = today and today.stage == "turnin" and today.turnIn
    if not how or how == "Pile" or how == "None" or WaCa.InMenu() then return end
    -- (leading: the meeting place is an interactable now - meetingInteract)
    if how == "Camp" then return end
    local cat, dist = reportTarget(how)
    if not cat then
        log("duties: the report key - no %s within %d to report to", how == "Partner" and "partner" or how, cfg.reportRadius)
        feedback(string.format("No %s close enough to report to.", how == "Partner" and (today.task and today.task.who or "partner") or how:lower()))
        return
    end
    log("duties: your cat reports to %s (%.0f away, the report key)", pathOf(cat):match("([^.]+)$") or "?", dist)
    turnedIn(how)
end

-- the night in your nest: a fade, then the night passes (DayEnded: the verdict, DayStarted: the morning fades in)
sleepNow = function()
    if not today or today.stage == "sleeping" then return end
    today.stage = "sleeping"
    if today.task then today.task.done = true cleanup(today.task) end
    -- (your cat lies down - the game's own sleep animation - and the screen fades; the morning fades back in)
    Events.Run({ { kind = "Pose", value = "Sleep", who = "Player" }, { kind = "Wait", value = "2" },
                 { kind = "Fade", value = "2" }, { kind = "Card", value = "You curl up and sleep." } }, function()
        if today then today.blackout = true end
        DayNight.Skip(1)
    end, context())
end

-- THE DEPUTY'S WORDS ([Talk] in duties.ini): the game's line for "nothing new" (Key) is swapped while you talk to the
-- deputy - Report when you have a task to report, Busy while your task is under way; the game's own otherwise
local talkOriginal
talkLine = function(npc)
    if not today then return nil end
    local role = npc.narrativeRole and roleName(npc.narrativeRole) or ""
    if not role:find("Deputy$") then return nil end
    local t = today.task
    local line
    if today.stage == "turnin" and today.turnIn == "Deputy" then line = cfg.talk.report
    elseif today.stage == "task" and t and not t.done and not t.lead then line = cfg.talk.busy end
    if not line or line == "" then return nil end
    local ctx = context()
    ctx.TASKNAME = t and NAMES[t.kind] or ""
    return (line:gsub("{(%u+)}", function(k) return ctx[k] ~= nil and tostring(ctx[k]) or "{" .. k .. "}" end))
end

-- (the game's own line is kept as a sticky topic too: a reload of the mod mid-talk lost it and the deputy kept our
-- words - VM 2026-10-28; Init puts it back)
setTalk = function(line)
    local key = cfg.talk.key
    if line then
        if not talkOriginal then
            talkOriginal = WaCa.GetText(key)
            WaCa.Publish("clanlife.talkOriginal", { key = key, text = talkOriginal }, true)
        end
        WaCa.SetText(key, line)
        log("duties: the deputy says: %s", line)
    elseif talkOriginal then
        WaCa.SetText(key, talkOriginal)
        talkOriginal = nil
    end
end

-- the clan's events of a third: every [Event.*] of clanevents.ini whose When is this third, on its days, by chance
-- (the story's lever on an event's Chance: the story variable Event:<Name> - 1 it happens (its third, its
-- conditions), -1 it doesn't; and a story day's Events = A, B / NoEvents = A, B in days.ini. Operator 2026-10-29:
-- "some randomness is fine but we need a control lever / override")
local function eventLever(e)
    if plan and plan.noEvents and plan.noEvents[e.name] then return -1, "the story day says no" end
    if plan and plan.events and plan.events[e.name] then return 1, "the story day's" end
    local ok, v = pcall(function() return tonumber(Events.Var("Event:" .. e.name)) end)
    v = ok and v or 0
    if v >= 1 then return 1, "Event:" .. e.name .. " = 1" end
    if v <= -1 then return -1, "Event:" .. e.name .. " = -1" end
    return 0
end

local function pickEvents(name, day)
    local out = {}
    for _, e in ipairs(cfg.clanEvents) do
        local dayOk = (not e.day or day >= e.day) and (not e.every or (day - (e.day or 1)) % e.every == 0)
            and (not e.only or day == e.only)
        if e.when == name and dayOk and not (e.once and eventsDone[e.name]) and Events.Check(e.require) then
            local lever, why = eventLever(e)
            if lever >= 1 then
                log("duties: the %s's event %s - %s", name:lower(), e.name, why)
                table.insert(out, e)
            elseif lever <= -1 then
                log("duties: the %s's event %s held back - %s", name:lower(), e.name, why)
            elseif math.random() * 100 < e.chance then
                table.insert(out, e)
            end
        end
    end
    return out
end

-- the third's end (the task turned in): the story's beats, the clan's events, then the next third
thirdEnd = function()
    if not today or today.stage ~= "turnin" then return end
    today.stage = "event"
    local name = thirdName()
    log("duties: the %s's end - its events", name:lower())
    WaCa.Emit("ClanThirdEnded", today.day, name)
    -- the ORDER (operator 2026-10-28: a story's cutscene after the hand-in, BEFORE or AFTER the clan's event): numbered
    -- slots, lowest first - the story's beats 100 (days.ini <Third>), the clan's events 200 (each its own Order =),
    -- the story's after-beats 300 (<Third>After), duties.ini [Third.X] Event 350, the blocking hook ClanThirdEnd 400
    local parts = {}
    local function part(order, steps, what)
        if steps and #steps > 0 then table.insert(parts, { order = order, steps = steps, what = what, n = #parts }) end
    end
    part(100, Days and Days.Beats and Days.Beats(name), "the story")
    for _, e in ipairs(pickEvents(name, today.day)) do
        part(e.order or 200, e.steps, "clan event " .. e.name)
        if e.once then eventsDone[e.name] = true end
    end
    part(300, Days and Days.Beats and Days.Beats(name .. "After"), "the story (after)")
    part(350, cfg.thirdScenes[name] and cfg.thirdScenes[name].Event, "duties.ini")
    part(400, { hook("ClanThirdEnd") }, "the hook")
    table.sort(parts, function(a, b) if a.order ~= b.order then return a.order < b.order end return a.n < b.n end)
    local steps, order = {}, {}
    for _, pt in ipairs(parts) do
        append(steps, pt.steps)
        if pt.what ~= "the hook" then table.insert(order, string.format("%s (%d)", pt.what, pt.order)) end
    end
    if #order > 0 then log("duties: the %s's end: %s", name:lower(), table.concat(order, ", ")) end
    local day = today
    Events.Run(steps, function()
        if today ~= day then return end
        if day.third < 4 then startThird(day.third + 1)
        else
            day.stage = "sleep"
            statusSoon()
        end
    end, context())
end

onCamp = function(entering)
    if entering ~= camp.inside then log("duties: your cat %s the camp", entering and "walks into" or "leaves") end
    camp.inside = entering
    -- (the step check's last answer follows: after a teleport in - the zone told, the steps never saw camp - walking out
    -- read "out" again, no change, and no CampLeft came: the party never set off, VM 2026-10-30)
    camp.stepInside = entering
    if entering then camp.entry = playerPos() end
    if today and not entering then today.leftCamp = true end
    WaCa.Emit(entering and "CampEntered" or "CampLeft", today and today.day, today and thirdName())
end

-- a third begins: the clock moves on to it, its beats, then the deputy
local pendingThird               -- a third that waits for time to run again: { i, why }
startThird = function(i, why)
    local name = thirdName(i)
    -- (time stands still - a story point, a scene: the next third waits for it, so the clan's day and the sky never part)
    if DayNight.Frozen and DayNight.Frozen() and DayNight.Hour() then
        if not pendingThird then log("duties: the %s waits - time stands still", name:lower()) end
        pendingThird = { i, why }
        return
    end
    -- (the last third's markers go with it, however it ended - a third the clock or a rest ended kept its marker and
    -- its particles in the world until the next morning: operator 2026-10-30, "the particles never despawn")
    if today.task then cleanup(today.task) end
    today.third, today.stage, today.task, today.leftCamp = i, "start", nil, false
    setClock(name)
    log("duties: day %d - the %s begins (%s)", today.day, name:lower(), why or "the loop")
    WaCa.Emit(i == 4 and "ClanNight" or "ClanThird", today.day, name)
    local steps = {}
    if today.blackout then
        today.blackout = false
        table.insert(steps, { kind = "FadeIn", value = "2" })
    end
    append(steps, Days and Days.Beats and Days.Beats(name .. "Start"))
    append(steps, cfg.thirdScenes[name] and cfg.thirdScenes[name].Start)
    table.insert(steps, hook("ClanThirdStart"))
    local day = today
    Events.Run(steps, function()
        if today ~= day then return end
        if i == 3 then
            -- the evening is no duty: the clan comes together (its events: eating, sharing tongues), then the night
            today.stage, today.turnIn = "turnin", nil
            log("duties: day %d - evening: the clan eats and shares tongues", today.day)
            thirdEnd()
        else
            assign()
        end
    end, context())
end

-- the day's end (the morning after, or a rest): the tasks done raise standing, missed ones lower it
local function verdict()
    if not today then return end
    local done, missed, bonus = 0, 0, 0
    for _, t in ipairs(today.record) do
        cleanup(t)
        if COUNTED[t.kind] then
            if t.done then
                done = done + 1
                if t.kind == "NightWatch" then bonus = bonus + cfg.watchStanding end
            else
                missed = missed + 1
            end
        end
    end
    local change = done * cfg.standingDone + missed * cfg.standingMissed + bonus
    standing = standing + change
    log("duties: day %d over - %d done, %d missed: standing %+d = %d", today.day, done, missed, change, standing)
    -- (no card for a day with nothing to judge - a session that starts at night showed "0 of 0 duties done": VM
    -- 2026-10-28)
    if done + missed > 0 then
        card(string.format("Day %d: %d of %d duties done (standing %d).", today.day, done, done + missed, standing))
    end
    WaCa.Emit("DutiesJudged", today.day, done, missed, standing)
    local blackout = today.blackout
    today = nil
    return blackout
end

local function newDay(n, why)
    -- from MaxRank on your cat hands the duties out: each third is its own to lead (free time, ended with the report
    -- key in camp) - the day still moves on through its thirds, its clan events and its night
    local lead = not rankAllows()
    local rank, from = WaCa.PlayerRank()
    log("duties: your cat's rank %s (from its %s) - %s", tostring(rank), tostring(from),
        lead and ("it leads the clan's day (" .. cfg.maxRank .. " or above)") or "the deputy gives it tasks")
    today = { day = n, record = {}, blackout = pendingBlackout, lead = lead }
    -- (awake: the night's sleep animation ends)
    pcall(function() pc().Pawn:StopAnimMontage(nil) end)
    pendingBlackout = nil
    startThird(why == "dawn" and 1 or thirdAt(DayNight.Hour() or cfg.hours.Morning), why)
end

-- the session's first day, once your cat is free (no menu, conversation or cutscene up)
waitingToStart = false
startWhenFree = function()
    if today or not ready then
        waitingToStart = false
        return
    end
    if WaCa.InMenu() then
        if not waitingToStart then log("duties: the day starts once the conversation / cutscene is over") end
        waitingToStart = true
        return
    end
    waitingToStart = false
    newDay(DayNight.Day() or 1, "the session starts")
end

-- a fight is over (its end screen / the combat manager's EndCombat, the second within seconds the same one; the end
-- screen also shows while a world loads - only a fight whose popup opened counts): a running spar counts
local lastFight, inFight = -100, false
local function fightOver()
    if not inFight or WaCa.Now() - lastFight < 5 then return end
    inFight = false
    lastFight = WaCa.Now()
    local t = today and today.task
    if not (t and t.kind == "Train" and t.fighting) then return end
    t.fighting = false
    local bond = t.role and cfg.trainBond > 0 and WaCaNative_AddBond and WaCaNative_AddBond(t.role, cfg.trainBond)
    log("duties: sparring done%s", bond and string.format(" - bond with %s +%d", t.who, cfg.trainBond) or "")
    taskDone(t)
end

-- where the cat is - in / out of the camp, a patrol point / the teacher / the guard spot reached: asked at the cat's
-- own footsteps (every StepEvery-th - walking is what changes it) and at sense pulses. The trigger boxes report the
-- same where they work (VM 2026-10-28: a box spawned at the camp reported nothing for teleports - the steps carry it).
local function where()
    local p = playerPos()
    if not p then return end
    -- (always, next to the zone events: teleports - fast travel, respawns, cutscenes - cross no gate; VM: after a
    -- teleport back into camp the zones alone never told. Each signal acts when ITS answer changes.)
    if camp.code or camp.center then
        local inside = campInside(p)
        if not camp.checked then
            camp.checked = true
            log("duties: the camp check reads your cat's steps (%.0f %.0f: %s)", p.X, p.Y, inside and "in camp" or "out")
        end
        if inside ~= camp.stepInside then
            camp.stepInside = inside
            if inside ~= camp.inside then onCamp(inside) end
        end
    end
    local t = today and today.task
    if not t or t.done then return end
    local function dist(q) return q and math.sqrt((q.X - p.X) ^ 2 + (q.Y - p.Y) ^ 2) or math.huge end
    if t.kind == "Patrol" then
        for i, pt in ipairs(t.points) do if not pt.done and dist(pt) <= cfg.reach then reached(t, "point", i) end end
    elseif t.kind == "Water" and t.points then
        if not t.points[1].done and dist(t.points[1]) <= cfg.gatherReach * 2 then reached(t, "point", 1) end
    elseif t.kind == "Bedding" and t.points then
        if not t.points[1].done and dist(t.points[1]) <= 700 then reached(t, "point", 1)
        elseif t.points[1].done and not t.points[2].done and dist(t.points[2]) <= cfg.gatherReach * 2 then reached(t, "point", 2) end
    elseif t.kind == "Gather" and t.points then
        for i, pt in ipairs(t.points) do if not pt.done and dist(pt) <= cfg.gatherReach then reached(t, "point", i) end end
    elseif t.kind == "Train" then
        local a = StaticFindObject(t.path)
        if a and a:IsValid() and dist(a:K2_GetActorLocation()) <= cfg.reach then reached(t, "teacher") end
    elseif t.kind == "Sleep" and t.dens then
        -- in a den: its door brought your cat to the inside point
        for _, d in ipairs(t.dens) do
            if dist(d.dest) <= 700 then
                log("duties: your cat is in its den (%s) - it goes to sleep", d.title)
                return sleepNow()
            end
        end
    elseif t.kind == "NightWatch" and t.spot then
        -- (night falls with your cat right where it came in - the spot counts once it has stepped away and back)
        local d = dist(t.spot)
        if d > 800 then t.armed = true end
        if t.armed and d <= 400 then reached(t, "guard") end
    end
end

function Duties.Standing() return standing end
function Duties.Now()
    return today and { day = today.day, third = thirdName(), stage = today.stage, task = today.task and today.task.kind }
end
-- day scripts (days.lua): the story day's choices (nil = the clan's needs decide) - prey / border points, and a task
-- per third: { Morning = "Train", Night = "Hunt" (a night hunt) ... }
-- the duty levers checked (the event WaCaDutiesSelfTest): a story day's chances win; equal chances repeat seldom
local function dutiesSelfTest()
    local savedPlan, savedPicked, savedWeights = plan, picked, cfg.weights.Night
    picked = {}
    plan = { weights = { Night = { NightWatch = 1 } } }
    local storyWins = true
    for _ = 1, 10 do if pickKind("Night") ~= "NightWatch" then storyWins = false end end
    plan, picked = nil, {}
    cfg.weights.Night = { Sleep = 1, NightWatch = 1, Hunt = 1 }
    local repeats, last = 0, nil
    for _ = 1, 40 do
        local k = pickKind("Night")
        if k == last then repeats = repeats + 1 end
        last = k
    end
    plan, picked, cfg.weights.Night = savedPlan, savedPicked, savedWeights
    -- the clan events' lever: Event:<Name> = 1 always, -1 never (whatever its Chance)
    local forced, blocked = true, true
    local any
    for _, e in ipairs(cfg.clanEvents) do any = any or e end
    if any then
        local savedChance = any.chance
        any.chance = 0
        Events.SetVar("Event:" .. any.name, 1)
        for _ = 1, 10 do
            local hit = false
            for _, e in ipairs(pickEvents(any.when, 1000)) do if e == any then hit = true end end
            if not hit then forced = false end
        end
        any.chance = 100
        Events.SetVar("Event:" .. any.name, -1)
        for _ = 1, 10 do
            for _, e in ipairs(pickEvents(any.when, 1000)) do if e == any then blocked = false end end
        end
        Events.SetVar("Event:" .. any.name, 0)
        any.chance = savedChance
    end
    -- the places: the second patrol / hunt avoids the first one's (markers cleaned up again)
    local function drop(points)
        for _, pt in ipairs(points or {}) do
            pcall(function() local m = StaticFindObject(pt.marker) if m and m:IsValid() then m:K2_DestroyActor() end end)
        end
    end
    local samePatrol, patrolNote = 0, ""
    local okP = pcall(function()
        local first = patrolPoints(2)
        local firstKeys = {}
        for k in pairs(lastPatrol) do firstKeys[k] = true end
        local second = patrolPoints(2)
        for k in pairs(lastPatrol) do if firstKeys[k] then samePatrol = samePatrol + 1 end end
        patrolNote = string.format("%d + %d points", #first, #second)
        drop(first)
        drop(second)
    end)
    local sameHunt, huntNote = false, ""
    local okH = pcall(function()
        local h1 = huntingGround()
        local h2 = huntingGround()
        sameHunt = h1 and h2 and math.abs(h1.X - h2.X) < 1 and math.abs(h1.Y - h2.Y) < 1 or false
        huntNote = (h1 and h2) and "two spots" or "no prey around"
        drop({ h1, h2 })
    end)
    log("duties: self-test - no repeat: patrol places shared by two draws %d (%s): %s; hunt spot twice the same: %s (%s): %s",
        samePatrol, patrolNote, (okP and samePatrol == 0) and "PASS" or "FAIL", tostring(sameHunt), huntNote,
        (okH and not sameHunt) and "PASS" or "FAIL")
    log("duties: self-test - the story day's chances win: %s; equal chances, back-to-back repeats %d of 39 (by pure chance ~13): %s; Event:%s = 1 plays at 0%%: %s, = -1 never at 100%%: %s",
        storyWins and "PASS" or "FAIL", repeats, repeats <= 8 and "PASS" or "FAIL", any and any.name or "?",
        forced and "PASS" or "FAIL", blocked and "PASS" or "FAIL")
end

function Duties.Plan(hunt, patrol, kinds, chances, events, noEvents)
    local w
    for slot, text in pairs(chances or {}) do
        local parsed = weights(text)
        if next(parsed) then w = w or {} w[slot] = parsed end
    end
    local function set(text)
        if not text or text == "" then return nil end
        local t = {}
        for n in text:gmatch("[^,%s]+") do t[n] = true end
        return next(t) and t or nil
    end
    local ev, nev = set(events), set(noEvents)
    plan = (hunt or patrol or (kinds and next(kinds)) or w or ev or nev)
        and { hunt = hunt, patrol = patrol, kinds = kinds, weights = w, events = ev, noEvents = nev } or nil
end
function Duties.Today() return today end
-- for other modules (patrols.lua ...): the camp - { middle = {X,Y,Z}, inside = bool, code = the game's zone } - and N
-- border points out in the territory (unmarked)
function Duties.Camp()
    local mid = camp.center
    if camp.hull then
        local h = camp.hull
        mid = { X = (h.x0 + h.x1) / 2, Y = (h.y0 + h.y1) / 2, Z = (camp.boxes[1] and playerPos() and playerPos().Z) or 0 }
    end
    return { middle = mid, inside = camp.inside, code = camp.code }
end
function Duties.BorderPoints(n, from)
    local pts = {}
    for _, g in ipairs(FindAllOf("BP_Enemy_Generator_C") or {}) do
        pcall(function()
            local q = g:K2_GetActorLocation()
            local d = from and math.sqrt((q.X - from.X) ^ 2 + (q.Y - from.Y) ^ 2) or cfg.minDist
            if d >= cfg.minDist and d <= cfg.maxDist then table.insert(pts, { X = q.X, Y = q.Y, Z = q.Z }) end
        end)
    end
    local out = {}
    for _ = 1, math.min(n, #pts) do table.insert(out, table.remove(pts, math.random(#pts))) end
    return out
end

local function sidecar() return WaCa.SlotFile("WaCaDuties") end

-- "Kind:weight, Kind:weight" -> { Kind = weight }

function Duties.Init(c)
    WaCa, log, DayNight = c.WaCa, c.log, c.DayNight
    WaCa.On("TimeFrozen", function(frozen)
        if frozen or not pendingThird then return end
        local p = pendingThird
        pendingThird = nil
        log("duties: time runs again - the %s begins", thirdName(p[1]):lower())
        ExecuteInGameThread(function() pcall(startThird, p[1], p[2]) end)
    end)
    WaCa.On("WaCaDutiesSelfTest", function()
        local ok, err = pcall(dutiesSelfTest)
        if not ok then log("duties: self-test failed to run: %s", tostring(err)) end
    end)
    Events, Days = c.Events or require("events"), c.Days
    local ini = WaCa.ReadContent(c.modDir .. "/config/duties.ini", "duties") or {}
    local d = ini["Duties"] or {}
    cfg.on = c.part("Duties", d.On)
    cfg.maxRank = (d.MaxRank or "") ~= "" and d.MaxRank or cfg.maxRank
    cfg.deputyName = (d.DeputyName or "") ~= "" and d.DeputyName or "The deputy"
    cfg.meetingPlaces = {}
    for name, v in pairs(ini["MeetingPlace"] or {}) do
        if name ~= "__order" and v ~= "" then cfg.meetingPlaces[name] = v end
    end
    cfg.campRadius = tonumber(d.CampRadius or "") or cfg.campRadius
    cfg.campMax = tonumber(d.CampMax or "") or cfg.campMax
    cfg.reportKey = (d.ReportKey or "") ~= "" and d.ReportKey or cfg.reportKey
    cfg.reportRadius = tonumber(d.ReportRadius or "") or cfg.reportRadius
    local th = ini["Thirds"] or {}
    for _, name in ipairs({ "Morning", "Noon", "Evening", "Night" }) do
        cfg.hours[name] = tonumber(th[name] or "") or cfg.hours[name]
        local sec = ini["Third." .. name]
        cfg.thirdScenes[name] = { Start = Events.Lines(sec, "Start"), Event = Events.Lines(sec, "Event") }
    end
    local tk = ini["Tasks"] or {}
    for _, name in ipairs({ "Morning", "Noon", "Evening", "Night" }) do
        if (tk[name] or "") ~= "" then cfg.weights[name] = weights(tk[name]) end
        cfg.repeatFactor = tonumber(tk.RepeatFactor or "") or cfg.repeatFactor
        cfg.repeatMemory = tonumber(tk.RepeatMemory or "") or cfg.repeatMemory
    end
    cfg.pileFactor = tonumber(tk.PileFactor or "") or cfg.pileFactor
    for kind in pairs(KINDS) do
        local steps = Events.Lines(ini["Assign." .. kind], "Step")
        if #steps > 0 then cfg.assignScenes[kind] = steps end
    end
    for kind in pairs(KINDS) do
        local tsec = ini["Task." .. kind]
        if tsec and (tsec.TurnIn or "") ~= "" then cfg.turnIn[kind] = tsec.TurnIn end
    end
    local w = ini["NightWatch"] or {}
    cfg.watchStanding = tonumber(w.Standing or "") or cfg.watchStanding
    cfg.watchScene = Events.Lines(w, "Step")
    if #cfg.watchScene == 0 then
        cfg.watchScene = { { kind = "Fade", value = "2" }, { kind = "Card", value = "You keep watch until dawn." } }
    end
    local h = ini["Hunt"] or {}
    cfg.huntMin = math.max(0, math.floor(tonumber(h.Min or "") or cfg.huntMin))
    cfg.huntMax = math.max(cfg.huntMin, math.floor(tonumber(h.Max or "") or cfg.huntMax))
    cfg.pileLow = tonumber(h.PileLow or "") or cfg.pileLow
    cfg.pilePerPrey = tonumber(h.PilePerPrey or "") or cfg.pilePerPrey
    cfg.huntingGround = (h.HuntingGround or "1") ~= "0"
    local gs = ini["Gather"] or {}
    cfg.gatherCount = math.max(1, tonumber(gs.Count or "") or cfg.gatherCount)
    cfg.gatherReach = tonumber(gs.Reach or "") or cfg.gatherReach
    cfg.gatherMinDist = tonumber(gs.MinDistance or "") or cfg.gatherMinDist
    cfg.gatherMaxRank = (gs.MaxRank or "") ~= "" and gs.MaxRank or cfg.gatherMaxRank
    local p = ini["Patrol"] or {}
    cfg.patrolPoints = math.max(0, math.floor(tonumber(p.Points or "") or cfg.patrolPoints))
    cfg.reach = tonumber(p.Reach or "") or cfg.reach
    cfg.companions = math.max(0, math.floor(tonumber(p.Companions or "") or cfg.companions))
    cfg.minDist = tonumber(p.MinDistance or "") or cfg.minDist
    cfg.maxDist = tonumber(p.MaxDistance or "") or cfg.maxDist
    local t = ini["Train"] or {}
    cfg.train = (t.On or "1") ~= "0"
    cfg.trainMaxRank = (t.MaxRank or "") ~= "" and t.MaxRank or cfg.trainMaxRank
    cfg.trainBond = tonumber(t.Bond or "") or cfg.trainBond
    local s = ini["Standing"] or {}
    cfg.standingDone = tonumber(s.Done or "") or cfg.standingDone
    cfg.standingMissed = tonumber(s.Missed or "") or cfg.standingMissed
    local tk2 = ini["Talk"] or {}
    cfg.talk = { key = (tk2.Key or "") ~= "" and tk2.Key or "STR_DIALOGUE_NOTHING_CONTEXT_1",
                 report = tk2.Report or "Good work. The clan is better for it - rest a while.",
                 busy = tk2.Busy or "Shouldn't you be out on your {TASKNAME}? The clan is counting on you." }
    -- the clan's events (clanevents.ini)
    local ev = WaCa.ReadContent(c.modDir .. "/config/clanevents.ini", "clanevents") or {}
    for section, sec in pairs(ev) do
        local name = section:match("^Event%.(.+)$")
        if name and (sec.When or "") ~= "" and sec.Off ~= "1" then
            table.insert(cfg.clanEvents, { name = name, when = sec.When, chance = tonumber(sec.Chance or "") or 100,
                day = tonumber(sec.Day or ""), every = tonumber(sec.Every or ""), only = tonumber(sec.OnlyDay or ""),
                once = (sec.Once or "0") == "1", require = sec.Require, order = tonumber(sec.Order or ""),
                steps = Events.Lines(sec, "Step") })
        end
    end
    table.sort(cfg.clanEvents, function(a, b) return a.name < b.name end)
    -- (WHEN = EVENT:<name> - a clan event on something that happens rather than a third: WaCa Clan Life's ice
    -- "FellThroughIce", Hunting's "HuntCaught", any mod's event - a story pack reacts with data alone. Library exercise
    -- 2026-10-31: a fall through the ice had no way into a pack's scene)
    local onEvent = {}
    for _, e in ipairs(cfg.clanEvents) do
        local ev = e.when:match("^Event:%s*(.+)$")
        if ev then onEvent[ev] = onEvent[ev] or {} table.insert(onEvent[ev], e) end
    end
    for ev, list in pairs(onEvent) do
        WaCa.On(ev, function()
            ExecuteInGameThread(function()
                for _, e in ipairs(list) do
                    if not (e.once and eventsDone[e.name]) and Events.Check(e.require) then
                        local lever = eventLever(e)
                        if lever >= 1 or (lever == 0 and math.random() * 100 < e.chance) then
                            log("duties: %s - the event %s", ev, e.name)
                            if e.once then eventsDone[e.name] = true end
                            Events.Run(e.steps, function() end, {})
                        end
                    end
                end
            end)
        end)
    end
    pcall(function() cfg.restKey = (WaCa.ReadIni(c.modDir .. "/config/timeskip.ini") or {}).TimeSkip.RestKey end)
    cfg.restKey = cfg.restKey or ""
    Events.Provide("Standing", function() return standing end)
    -- (the fresh-kill pile, 0-100: the clan's hunger for stories and murmurs - Pile < 30)
    Events.Provide("Pile", function() return pileValue() end)
    log("duties: %s (%d clan events)", cfg.on and "on" or "off", #cfg.clanEvents)
    if not cfg.on then return end
    if not DayNight.Drive(cfg.hours.Morning) then
        log("duties: the clan loop needs the day / night cycle (daynight.ini On = 1) - off")
        return
    end
    -- the first world of a session: the camp and the loop after the world has streamed in (spawning earlier crashed)
    local armed = false
    WaCa.On("ScreenShown", function(screen)
        local name = screen:GetClass():GetFName():ToString()
        if name == "WBP_GuiPopupCombat_C" then inFight = true end
        if name == "WBP_GuiHudCombatOver_C" then fightOver() end
        if armed or not name:find("^WBP_GuiHudGame") then return end
        armed = true
        ExecuteInGameThreadWithDelay(30000, function()
            ready = true
            findCamp()
            startWhenFree()
        end)
    end)
    -- (the day waits while a conversation or cutscene is up: a new game opens with the story's intro, and the first
    -- task's card came in the middle of the leader's speech - VM 2026-10-28)
    WaCa.On("ScreenHidden", function()
        if waitingToStart then ExecuteInGameThreadWithDelay(1000, startWhenFree) end
    end)
    -- the turn-ins: the game's own fresh-kill contribution (its achievements manager hears of every one), and a talk
    -- with the deputy (the dialogue screen's NpcRef is the cat talked to)
    WaCa.Watch("OnContributeFreshKill", "/Script/Wrc.WrcAchievementsManager", "WaCaPileContribution", "post")
    WaCa.On("WaCaPileContribution", function() turnedIn("Pile") end)
    -- sleeping: your cat uses a nest (the game's own sleep spot) at night - the night passes
    WaCa.Watch("OnInteracted", "/Script/SwtAdventure.SwtAdventureInteractableActor", "WaCaInteracted", "post")
    WaCa.On("WaCaInteracted", function(actor)
        if not isNest(actor) then return end
        local night = today and (today.stage == "sleep" or (today.task and today.task.kind == "Sleep"))
        log("duties: your cat lies down in a nest%s", night and " - the night passes" or " (not night yet: a nap)")
        if night then sleepNow() end
    end)
    -- (a line left swapped by an earlier run of this mod: the game's own back)
    local kept = WaCa.Latest("clanlife.talkOriginal")
    if kept and kept.key and kept.text and WaCa.GetText(kept.key) ~= kept.text then WaCa.SetText(kept.key, kept.text) end
    -- the deputy's own words (the game has only "nothing new for you" for a cat whose story has nothing to say): while
    -- a talk with the deputy is open, that line is the clan loop's - your report, or a reminder of your task
    WaCa.On("ScreenShown", function(screen)
        local ok, npc = pcall(function() return screen.NpcRef end)
        if ok and npc and npc:IsValid() then setTalk(talkLine(npc)) end
    end)
    WaCa.On("ScreenHidden", function(screen)
        local ok, npc = pcall(function() return screen.NpcRef end)
        if ok and npc then setTalk(nil) end
    end)
    WaCa.On("ScreenShown", function(screen)
        local how = today and today.stage == "turnin" and today.turnIn
        if not how or how == "Pile" or how == "None" then return end
        local ok, npc = pcall(function() return screen.NpcRef end)
        if not (ok and npc and npc:IsValid()) then return end
        local t = today.task
        if how == "Partner" then
            if t and t.path and pathOf(npc) == t.path then turnedIn("Partner") end
        else
            local role = npc.narrativeRole and roleName(npc.narrativeRole) or ""
            if role:find(how .. "$") then turnedIn(how) end
        end
    end)
    WaCa.Watch("OnListenCommand", "/Script/SwtEngine.SwtScreen", "WaCaDutiesCommand", "pre", "Command")
    WaCa.On("WaCaDutiesCommand", function(_, command)
        if tonumber(command) ~= PLAYER_INTERACT then return end
        local ok, err = pcall(meetingInteract)
        if not ok then log("duties: the meeting place failed (%s)", tostring(err)) end
    end)
    WaCa.On("KeyDown", function(_, name)
        if tostring(name) ~= cfg.reportKey then return end
        local ok, err = pcall(reportKey)
        if not ok then log("duties: the report key failed (%s)", tostring(err)) end
    end)
    WaCa.Watch("EndCombat", "/Script/SwtAdventure.SwtAdventureCombatManager", "WaCaFightEnd", "post")
    WaCa.On("WaCaFightEnd", function() fightOver() end)
    WaCa.On("AreaOverlap", function(_, area, other, entering)
        local fn = areas[tostring(area):gsub("^%S+ ", "")]
        if not fn then return end
        local pawn = pc() and pc().Pawn
        if not (pawn and tostring(other):gsub("^%S+ ", "") == pathOf(pawn)) then return end
        fn(entering == "1")
    end)
    WaCa.On("DayEnded", function() pendingBlackout = verdict() end)
    WaCa.On("DayStarted", function(n) if ready then newDay(n, "dawn") end end)
    -- the day at a glance (clan.status) after every step of the loop and every bit of progress
    for _, e in ipairs({ "ClanThird", "ClanNight", "TaskAssigned", "TaskDone", "TaskTurnedIn", "ClanThirdEnded",
                         "DutiesJudged", "HuntCaught", "CampEntered", "CampLeft" }) do
        WaCa.On(e, statusSoon)
    end
    WaCa.Watch("BlendProgress", "/Script/SwtAdventure.SwtAdventureExplorationSenseComponent", "WaCaDutySense", "post")
    WaCa.On("WaCaDutySense", function() where() end)
    -- the game's zones: the cat walked into a zone (its trigger's own overlap, with the actor that entered)
    WaCa.Watch("OnOverlapBegin", "/Script/Wrc.WrcZoneNameTrigger", "WaCaZoneEnter", "post", "OtherActor")
    WaCa.On("WaCaZoneEnter", function(trigger, other)
        local pawn = pc() and pc().Pawn
        local ok, mine = pcall(function() return other:GetAddress() == pawn:GetAddress() end)
        if not (ok and mine and camp.code) then return end
        local code = trigger.ZoneCode:ToString()
        if not camp.zoneSeen then log("duties: zones report (%s)", code) end
        camp.zoneSeen = true
        local inside = code == camp.code
        if inside ~= camp.inside then onCamp(inside) end
    end)
    -- the player's own footsteps (the step notify hands over the stepping mesh - the notify is shared by all cats)
    local steps = 0
    WaCa.Watch("Received_Notify", "/Game/Gameplay/Blueprints/BP_AnimStepNotify.BP_AnimStepNotify_C", "CatStep", "pre", "MeshComp")
    -- (every cat's steps arrive here: the player's cat's address is kept, not looked up per step; the look is a few
    -- distance checks - on EVERY step: a walk is only a couple of steps on a slow machine, and every 4th step kept
    -- landing on the same side of a teleport, VM 2026-10-28)
    local me
    WaCa.On("CatStep", function(_, mesh)
        local ok, owner = pcall(function() return mesh:GetOwner():GetAddress() end)
        if not ok then return end
        if owner ~= me then
            local pawn = pc() and pc().Pawn
            me = pawn and pawn:GetAddress() or me
            if owner ~= me then return end
        end
        steps = steps + 1
        if steps % cfg.stepEvery == 0 then where() end
    end)
    WaCa.On("HuntCaught", function()
        local t = today and today.task
        if not (t and t.kind == "Hunt") then return end
        t.got = t.got + 1
        local pile = pileComponent()
        local now = pile and cfg.pilePerPrey > 0 and WaCaNative_AddResource and WaCaNative_AddResource(pile:GetAddress(), cfg.pilePerPrey)
        log("duties: prey caught (%d of %d)%s", t.got, t.need, now and string.format(" - fresh-kill pile %.0f", now) or "")
        if t.got == t.need then taskDone(t) end
    end)
    -- standing + the one-time clan events live with the save (written when the game saves)
    WaCa.On("GameSaved", function()
        local slot = WaCa.CurrentSlot()
        if slot and restoredFor ~= slot then
            restoredFor = slot
            local data = WaCa.ReadIni(sidecar() or "") or {}
            standing = tonumber((data["Standing"] or {}).Value or "") or 0
            eventsDone = {}
            for k, v in pairs(data["EventsHeld"] or {}) do if k ~= "__order" and v == "1" then eventsDone[k] = true end end
        end
        local path = sidecar()
        if path then
            local held = { __order = {} }
            for k in pairs(eventsDone) do held[k] = "1" table.insert(held.__order, k) end
            WaCa.WriteIni(path, { Standing = { Value = tostring(standing), __order = { "Value" } }, EventsHeld = held,
                __order = { "Standing", "EventsHeld" } }, "; WaCa Clan Life - your cat's standing in the clan (duties.ini)")
        end
    end)
end

return Duties
