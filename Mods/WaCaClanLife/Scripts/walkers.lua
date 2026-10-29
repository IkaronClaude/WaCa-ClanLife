-- THE CAMP'S NAMED CATS MOVE ABOUT (operator 2026-10-29: "I want the named cats to be able to do the patrolling /
-- walking / moving stuff the unnamed cats do ... they should be the same type of object"; "remove walkers, move named
-- cats"; "not all cats should walk, and ideally which walk should change ... the important cats (special chat role,
-- e.g. trainer cat, medicine cat) should stay close to where they sit - let them idle cycle a bit, e.g. move over to a
-- nearby spot ... and they stop when spoken to").
--   - The game's nameless walking cats (BP_WalkingNPC_Character_Base_C) are taken out: hidden, no collision, their AI
--     stopped. (More named camp cats can make up for them later.)
--   - The camp's named cats (its quest cats - the ones the game shows, of your clan) move in turns, each third of the
--     day a few of them, the ones that moved longest ago first:
--       ROAMERS - plain warriors, apprentices, elders and cats with no story part: a trip across camp to one of its
--         places (a den's front, the fresh-kill pile, the meeting place, another cat's spot), a while there, then home.
--       HOMEBODIES - every cat with a part (the trainer, the medicine cat, gossip, fresh-kill, the leader, the deputy,
--         queens, kits, story cats): never far from their spot - over to a nearby spot (1.5-3.5 m), a while, back.
--     The game's own walk animation plays while a cat moves (its body's single-node animation, then back to its own
--     animation blueprint); the move is swept - a cat that meets a rock or a den wall turns back.
--   - Nobody moves while a conversation, a menu or a staged scene is up - a cat spoken to stops, and the game turns it
--     to you; at a turn's end every cat is home again.
--   - The story's lever: the story variable Walk:<Name> - 1 that cat moves at the next turn, -1 it never moves
--     (walkers.ini Never too).
local Walkers = {}

local WaCa, log, Events, Duties
local cfg = { on = false, never = {}, roamers = 3, homebodies = 2, speed = 110, near = { 150, 350 }, stay = { 8, 20 },
              far = { 500, 2500 } }
local WALK = "/Game/Art/Characters/CatMaster/Animations/A_CatMaster_Walk_1.A_CatMaster_Walk_1"
local movers = {}           -- named cat path -> { home, homeRot, legs = { {X,Y,Z} ... }, leg, state, wait, kind, name }
local lastMoved = {}        -- name -> the turn it last moved
local turn = 0
local generation = 0
local roleCache, clanCache, giverCache = {}, {}, {}
local hiddenWalkers = {}
local talkingSince          -- os.time() a conversation began (nil: none) - every mover holds while it's on

-- (DIAGNOSTIC, temporary: a flushed breadcrumb before every engine call - a crash in the game's own code named no
-- caller, VM 2026-10-29. walkers.ini Trace = 1.)
local traceFile
local function crumb(op, who)
    if not traceFile then return end
    traceFile:write(string.format("%.3f %s %s\n", os.clock(), op, tostring(who or "")))
    traceFile:flush()
end

local function enumName(path, value, cache)
    if not cache[1] then
        cache[1] = {}
        pcall(function()
            StaticFindObject(path):ForEachName(function(n, v) cache[1][v] = n:ToString():gsub("^.*::", "") end)
        end)
    end
    return cache[1][value]
end

local function pathOf(o) return (o:GetFullName():gsub("^%S+ ", "")) end

local function nameOf(cat)
    local name
    pcall(function()
        local cd = cat.MeshCustomizationComponent.CustomData
        name = WaCa.GetText(cd.PrefixNameId:ToString() .. cd.SuffixNameId:ToString())
    end)
    return (name and name ~= "") and name or nil
end

local function storyVar(name)
    local ok, v = pcall(function() return Events.Var(name) end)
    return ok and tonumber(v) or 0
end

local statics
local function gameNow()
    statics = statics or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local ok, t = pcall(function()
        for _, c in ipairs(FindAllOf("SwtPlayerController") or {}) do
            if c:IsValid() and c.Pawn and c.Pawn:IsValid() then crumb("GetTimeSeconds") return statics:GetTimeSeconds(c.Pawn) end
        end
    end)
    return (ok and t) or os.time()
end

-- which kind of mover a named cat is (nil: it doesn't move - another clan, StarClan, a rogue, kept home)
local function kindOf(a, myClan)
    local role = enumName("/Script/SwtQuest.ENarrativeRole", a.narrativeRole, roleCache) or ""
    if role:find("StarClan") or role:find("Rogue") or role:find("Spirit") then return nil end
    local clan = enumName("/Script/SwtQuest.EClanType", a.ClanType, clanCache)
    if myClan and clan and clan ~= myClan then return nil end
    local name = nameOf(a)
    if not name or cfg.never[name] or storyVar("Walk:" .. name) <= -1 then return nil end
    local plain = role == "None" or role == "" or role:match("^%a+Clan(Warrior)$") or role:match("^%a+Clan(Elder)$")
        or role:match("^%a+Clan(Apprentice)$")
    local giver = enumName("/Script/SwtQuest.EGiverRole", a.GiverRole, giverCache) or ""
    if plain and giver ~= "Leader" and giver ~= "Deputy" and giver ~= "MedicineCat" and giver ~= "Queen"
        and giver ~= "Kit" then return "roamer", name end
    return "homebody", name
end

-- a cat in play: one the game has drawn this session (seen), or draws now. Hidden is no proof of out of range: beside
-- the parked fillers (a DisableRequester on the hide sphere) some never draw at all - an online-only giver stood
-- unseen 1.5 m from your cat (VM 2026-10-29) - so the turn takes only cats the game was seen drawing
local seen = {}             -- quest actor path -> true once its body was drawn
local function drawn(a)
    local ok, yes = pcall(function() return not a.bHidden and a.SkeletalMeshComponent:IsVisible() end)
    return ok and yes
end
local inWorld = false       -- the game's HUD is up (not the menus, not a level loading)
local function look()
    if not inWorld or WaCa.MenuShowing() ~= false then return end
    crumb("look")
    for _, a in ipairs(FindAllOf("SwtAdventureQuestActor") or {}) do
        pcall(function() if a:IsValid() and drawn(a) then seen[pathOf(a)] = true end end)
    end
end
local function shown(a)
    if a.bHidden then return false end
    return seen[pathOf(a)] == true or drawn(a)
end

-- the camp's places a roamer goes to: dens' fronts, the fresh-kill pile, the meeting place, other cats' spots
local function campPlaces(homes)
    local out = {}
    pcall(function()
        local camp = Duties and Duties.Camp and Duties.Camp()
        if camp and camp.middle then out[#out + 1] = { X = camp.middle.X, Y = camp.middle.Y, Z = camp.middle.Z } end
    end)
    for _, d in ipairs(FindAllOf("WrcHousingDoorActor") or {}) do
        pcall(function()
            if d.bIsExit then return end
            local q = d:K2_GetActorLocation()
            out[#out + 1] = { X = q.X, Y = q.Y, Z = q.Z }
        end)
    end
    for _, f in ipairs(FindAllOf("BP_Quest_Giver_FreshKill_C") or {}) do
        pcall(function() local q = f:K2_GetActorLocation() out[#out + 1] = { X = q.X, Y = q.Y, Z = q.Z } end)
    end
    for _, h in ipairs(homes) do out[#out + 1] = h end
    return out
end

-- THE GROUND: a cat walks on it - its height above the ground kept from its home (a straight line at its home's height
-- buried Lionstar in his hillside: nameplate, no body - VM 2026-10-29). Terrain and rocks only (world static objects),
-- not the cats about; from knee height down (from 3 m up it found the branches overhead and put him in a tree - a cat
-- moves a few cm a step, so knee height climbs any slope).
local kismet
local function groundAt(a, x, y, z)
    kismet = kismet or StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local hit = {}
    local ok, yes = pcall(function()
        crumb("LineTrace", pathOf(a))
        return kismet:LineTraceSingleForObjects(a, { X = x, Y = y, Z = z + 50 }, { X = x, Y = y, Z = z - 400 }, { 0 },
            false, { a }, 0, hit, true, { R = 0, G = 0, B = 0, A = 0 }, { R = 0, G = 0, B = 0, A = 0 }, 0)
    end)
    if not (ok and yes) then return nil end
    local gz
    pcall(function() gz = hit.ImpactPoint.Z end)
    if not gz then pcall(function() gz = hit.Location.Z end) end
    return gz
end
local function onGround(m, a, x, y, z)
    if m.lift == nil then
        local g = groundAt(a, m.home.X, m.home.Y, m.home.Z)
        m.lift = g and (m.home.Z - g) or false
        if not g then log("walkers: %s - no ground found under its home; it walks level", m.name) end
    end
    if not m.lift then return z end
    local g = groundAt(a, x, y, z)
    return g and (g + m.lift) or z
end

local function playWalk(a, on)
    pcall(function()
        local mesh = a.SkeletalMeshComponent
        if on then
            crumb("LoadAsset")
            local anim = WaCa.LoadAsset(WALK)
            crumb("PlayAnimation", pathOf(a))
            if anim then mesh:PlayAnimation(anim, true) end
        else
            crumb("SetAnimationMode", pathOf(a))
            mesh:SetAnimationMode(0, true)                 -- (its own animation blueprint again: idle)
        end
    end)
end

-- a cat sent home now (a turn's end): straight there
local function sendHome(path, m)
    local a = StaticFindObject(path)
    if a and a:IsValid() then
        crumb("SetLocRot home", path)
        pcall(function() a:K2_SetActorLocationAndRotation(m.home, m.homeRot, false, {}, true) end)
        playWalk(a, false)
    end
    movers[path] = nil
end

-- one tick: every mover a step on (game seconds), or waiting
local lastTick
local function tick()
    if not inWorld or not next(movers) then lastTick = nil return end
    local now = gameNow()
    local dt = lastTick and math.max(0, math.min(1, now - lastTick)) or 0
    lastTick = now
    local menu = WaCa.InMenu and WaCa.InMenu()
    if talkingSince and os.time() - talkingSince > 300 then
        log("walkers: no end of the conversation seen in 5 min - moving again")
        talkingSince = nil
    end
    menu = menu or talkingSince ~= nil
    local paused = menu
    pcall(function() paused = paused or Events.Staging() end)
    for path, m in pairs(movers) do
        local a = StaticFindObject(path)
        if not (a and a:IsValid()) then
            movers[path] = nil
        elseif paused and not m.staged then
            -- (a scene's cats walk on through its cards and fades - the scene's popup held them all, 7 of 9 set down
            -- short of their seats: VM 2026-10-29)
            if m.state == "walk" then playWalk(a, false) m.state = "held" end
        elseif m.state == "hold" then
            -- (staged in a scene: seated, facing its group, until it is let go)
        else
            if m.state == "held" then m.state = "walk" playWalk(a, true) end
            if m.state == "wait" then
                m.wait = m.wait - dt
                if m.wait <= 0 then
                    if m.leg > #m.legs then
                        movers[path] = nil
                    else
                        m.state = "walk"
                        playWalk(a, true)
                        local q = a:K2_GetActorLocation()
                        local t = m.legs[m.leg]
                        log("walkers: %s sets off%s (%.0f m)", m.name, m.leg == #m.legs and " home" or "",
                            math.sqrt((t.X - q.X) ^ 2 + (t.Y - q.Y) ^ 2) / 100)
                        -- (other mods: a named cat sets off - its name, its actor's path, home or away)
                        pcall(WaCa.Emit, "WalkerMoves", m.name, path, m.leg == #m.legs and "home" or "away")
                    end
                end
            elseif m.state == "walk" then
                local target = m.legs[m.leg]
                local q = a:K2_GetActorLocation()
                local dx, dy = target.X - q.X, target.Y - q.Y
                local dist = math.sqrt(dx * dx + dy * dy)
                local step = (m.speed or cfg.speed) * dt
                if m.staged then
                    m.report = (m.report or 0) + dt
                    if m.report >= 2 then
                        m.report = 0
                        log("walkers: %s to its seat: %.1f m to go (step %.0f cm, dt %.2f)", m.name, dist / 100, step, dt)
                    end
                end
                if dist <= math.max(step, 5) and m.staged then
                    pcall(function()
                        a:K2_SetActorLocationAndRotation({ X = target.X, Y = target.Y, Z = target.Z },
                            { pitch = 0, Yaw = m.faceYaw or 0, Roll = 0 }, false, {}, true)
                    end)
                    m.state, m.arrived = "hold", true
                    playWalk(a, false)
                    log("walkers: %s is in its seat", m.name)
                elseif dist <= math.max(step, 5) then
                    local tz = onGround(m, a, target.X, target.Y, target.Z)
                    crumb("SetLoc arrive", path)
                    pcall(function() a:K2_SetActorLocation({ X = target.X, Y = target.Y, Z = tz }, false, {}, true) end)
                    m.leg = m.leg + 1
                    m.state = "wait"
                    m.wait = (m.leg > #m.legs) and 0 or (cfg.stay[1] + math.random() * (cfg.stay[2] - cfg.stay[1]))
                    playWalk(a, false)
                    if m.leg > #m.legs then
                        crumb("SetRot home", path)
                        pcall(function() a:K2_SetActorRotation(m.homeRot, true) end)
                        log("walkers: %s is home again", m.name)
                    else
                        local z = a:K2_GetActorLocation().Z
                        log("walkers: %s is there - staying %.0f s (%.0f above its home, ground %s)", m.name, m.wait,
                            z - m.home.Z, m.lift and "followed" or "not found")
                    end
                elseif step > 0 then
                    local f = step / dist
                    local yaw = math.deg(math.atan(dy, dx))
                    local moved = true
                    local nx, ny = q.X + dx * f, q.Y + dy * f
                    local nz = onGround(m, a, nx, ny, q.Z + (target.Z - q.Z) * f)
                    -- (a scene's cats don't sweep: walking into a tight ring of seats they bumped into the circle's
                    -- other cats and stalled - 7 of 9 short, VM 2026-10-29; roaming cats keep the sweep for rocks / walls)
                    crumb("SetLocRot step", path)
                    pcall(function()
                        moved = a:K2_SetActorLocationAndRotation({ X = nx, Y = ny, Z = nz },
                            { pitch = 0, Yaw = yaw, Roll = 0 }, not m.staged, {}, false)
                    end)
                    if moved == false then
                        -- (a rock, a den wall: this leg ends - home it is)
                        m.blocked = (m.blocked or 0) + 1
                        if m.blocked > 3 then
                            m.blocked = 0
                            m.leg = #m.legs
                            if not m.toldBlocked then
                                m.toldBlocked = true
                                log("walkers: %s met something on the way - back home", m.name)
                            end
                        end
                    end
                end
            end
        end
    end
end

-- the game's nameless walking cats out of the camp
local function removeWalkers()
    local n = 0
    for _, c in ipairs(FindAllOf("SwtAdventureWalkingNPC") or {}) do
        pcall(function()
            local key = c:GetAddress()
            if hiddenWalkers[key] then return end
            crumb("StopLogic", key)
            pcall(function() c.Controller.BrainComponent:StopLogic("WaCa: the named cats move instead") end)
            crumb("DisableMovement", key)
            pcall(function() c.CharacterMovement:DisableMovement() end)
            crumb("SetActorHiddenInGame", key)
            c:SetActorHiddenInGame(true)
            crumb("SetActorEnableCollision", key)
            c:SetActorEnableCollision(false)
            hiddenWalkers[key] = true
            n = n + 1
        end)
    end
    if n > 0 then log("walkers: %d nameless walking cat(s) taken out - the named cats move instead", n) end
end

-- a turn: who moves now
function Walkers.Turn(why, gen)
    if not cfg.on then return end
    if gen and gen ~= generation then return end
    -- (not before the world is up: the session's first turn ran while the level loaded - the nameless cats taken out
    -- half-built - and the game crashed, VM 2026-10-29)
    local busy = not inWorld or (WaCa.InMenu and WaCa.InMenu())
    pcall(function() busy = busy or Events.Staging() end)
    if busy then
        if not gen then generation = generation + 1 end
        local mine = generation
        ExecuteInGameThreadWithDelay(10000, function() pcall(Walkers.Turn, why, mine) end)
        return
    end
    generation = generation + 1
    crumb("turn begins")
    removeWalkers()
    for path, m in pairs(movers) do sendHome(path, m) end           -- (the last turn's movers home first)
    -- (a cat left on the walk animation by a mod reload mid-walk - its walk forgotten: idle again where it stands)
    local stray = 0
    for _, q in ipairs(FindAllOf("SwtAdventureQuestActor") or {}) do
        pcall(function()
            if q:IsValid() and q.SkeletalMeshComponent:GetAnimationMode() == 1 then
                playWalk(q, false)
                stray = stray + 1
            end
        end)
    end
    if stray > 0 then log("walkers: %d cat(s) left walking by an earlier run - idle again", stray) end
    local myClan = WaCa.PlayerClan and WaCa.PlayerClan() or nil
    local roamers, homebodies, homes = {}, {}, {}
    local p
    pcall(function()
        for _, c in ipairs(FindAllOf("SwtPlayerController") or {}) do
            if c:IsValid() and c.Pawn and c.Pawn:IsValid() then p = c.Pawn:K2_GetActorLocation() end
        end
    end)
    -- (the camp's cats - round its middle - and any near your cat: in a den, the turn only saw the den's cats)
    local mid
    pcall(function() local camp = Duties.Camp() mid = camp and camp.middle end)
    for _, a in ipairs(FindAllOf("SwtAdventureQuestActor") or {}) do
        pcall(function()
            if not (a:IsValid() and shown(a)) then return end
            local q = a:K2_GetActorLocation()
            local nearMe = p and (q.X - p.X) ^ 2 + (q.Y - p.Y) ^ 2 <= 8000 ^ 2
            local inCamp = mid and (q.X - mid.X) ^ 2 + (q.Y - mid.Y) ^ 2 <= 7000 ^ 2
            if not (nearMe or inCamp) then return end
            local kind, name = kindOf(a, myClan)
            if not kind then return end
            local e = { actor = a, name = name, path = pathOf(a), home = { X = q.X, Y = q.Y, Z = q.Z } }
            homes[#homes + 1] = e.home
            if kind == "roamer" then roamers[#roamers + 1] = e else homebodies[#homebodies + 1] = e end
        end)
    end
    turn = turn + 1
    local function order(list)
        table.sort(list, function(x, y)
            local fx, fy = storyVar("Walk:" .. x.name) >= 1, storyVar("Walk:" .. y.name) >= 1
            if fx ~= fy then return fx end
            local lx, ly = lastMoved[x.name] or 0, lastMoved[y.name] or 0
            if lx ~= ly then return lx < ly end
            return x.name < y.name
        end)
    end
    order(roamers)
    order(homebodies)
    local places = campPlaces(homes)
    local lines = {}
    local function start(e, kind)
        local a = e.actor
        local r = a:K2_GetActorRotation()
        local legs = {}
        if kind == "roamer" then
            local options = {}
            for _, pl in ipairs(places) do
                local d = math.sqrt((pl.X - e.home.X) ^ 2 + (pl.Y - e.home.Y) ^ 2)
                if d >= cfg.far[1] and d <= cfg.far[2] then options[#options + 1] = pl end
            end
            if #options == 0 then return false end
            local pl = options[math.random(#options)]
            local ang = math.random() * 2 * math.pi                 -- (a step short of the place, to one side)
            legs[1] = { X = pl.X + math.cos(ang) * 120, Y = pl.Y + math.sin(ang) * 120, Z = pl.Z }
        else
            local ang = math.random() * 2 * math.pi
            local d = cfg.near[1] + math.random() * (cfg.near[2] - cfg.near[1])
            legs[1] = { X = e.home.X + math.cos(ang) * d, Y = e.home.Y + math.sin(ang) * d, Z = e.home.Z }
        end
        legs[2] = { X = e.home.X, Y = e.home.Y, Z = e.home.Z }
        movers[e.path] = { home = e.home, homeRot = { pitch = r.pitch, Yaw = r.Yaw, Roll = r.Roll }, legs = legs, leg = 1,
                           state = "wait", wait = math.random() * 6, kind = kind, name = e.name }
        lastMoved[e.name] = turn
        lines[#lines + 1] = e.name .. (kind == "homebody" and " (near its spot)" or "")
        return true
    end
    local n, h = 0, 0
    for _, e in ipairs(roamers) do
        if n >= cfg.roamers then break end
        if start(e, "roamer") then n = n + 1 end
    end
    for _, e in ipairs(homebodies) do
        if h >= cfg.homebodies then break end
        if start(e, "homebody") then h = h + 1 end
    end
    log("walkers: turn %d (%s) - moving: %s; %d roamers, %d homebodies seen in camp", turn, tostring(why),
        #lines > 0 and table.concat(lines, ", ") or "nobody", #roamers, #homebodies)
end

function Walkers.On() return cfg.on end

-- SPOKEN TO: a conversation holds every mover where it is; the cat spoken to (the mover nearest your cat, within 5 m)
-- ends its trip there - after the talk it stays a while, then walks home
local function talkBegins(cat)
    talkingSince = os.time()
    log("walkers: a conversation begins%s - every cat holds", cat and (" with " .. (nameOf(cat) or "?")) or "")
    -- (the cat the game says is spoken to: that one; else the mover nearest your cat)
    if cat then
        local path = pathOf(cat)
        local m = movers[path]
        if m and not m.staged then
            playWalk(cat, false)
            local q = cat:K2_GetActorLocation()
            m.legs = { { X = q.X, Y = q.Y, Z = q.Z }, m.home }
            m.leg, m.state, m.wait = 2, "wait", cfg.stay[1]
            log("walkers: %s is spoken to - it stops; home after the talk", m.name)
        end
        return
    end
    local p
    pcall(function()
        for _, c in ipairs(FindAllOf("SwtPlayerController") or {}) do
            if c:IsValid() and c.Pawn and c.Pawn:IsValid() then p = c.Pawn:K2_GetActorLocation() end
        end
    end)
    if not p then return end
    local best, bestD
    for path, m in pairs(movers) do
        if not m.staged then
            local a = StaticFindObject(path)
            if a and a:IsValid() then
                local q = a:K2_GetActorLocation()
                local d = math.sqrt((q.X - p.X) ^ 2 + (q.Y - p.Y) ^ 2)
                if d <= 500 and (not bestD or d < bestD) then best, bestD = path, d end
            end
        end
    end
    if not best then return end
    local m, a = movers[best], StaticFindObject(best)
    playWalk(a, false)
    local q = a:K2_GetActorLocation()
    -- (its trip ends here: the leg it was on becomes where it stands, the way home next)
    m.legs = { { X = q.X, Y = q.Y, Z = q.Z }, m.home }
    m.leg, m.state = 2, "wait"
    m.wait = cfg.stay[1]
    log("walkers: %s is spoken to - it stops (%.1f m from your cat); home after the talk", m.name, bestD / 100)
end

local function talkEnds(why)
    if not talkingSince then return end
    talkingSince = nil
    log("walkers: the conversation is over (%s) - moving again", why)
end

-- THE EVENING'S SCENES (events.lua Groups): a named cat walked to a seat and held there, facing its group; let go, it
-- walks home
function Walkers.Stage(a, spot, faceYaw, speed)
    local path = pathOf(a)
    local m = movers[path]
    local q, r = a:K2_GetActorLocation(), a:K2_GetActorRotation()
    movers[path] = { home = m and m.home or { X = q.X, Y = q.Y, Z = q.Z },
                     homeRot = m and m.homeRot or { pitch = r.pitch, Yaw = r.Yaw, Roll = r.Roll },
                     legs = { { X = spot.X, Y = spot.Y, Z = spot.Z } }, leg = 1, state = "walk", staged = true, speed = speed,
                     faceYaw = faceYaw, name = nameOf(a) or "?" }
    playWalk(a, true)
    log("walkers: %s walks to its seat (%.1f m)", movers[path].name,
        math.sqrt((spot.X - q.X) ^ 2 + (spot.Y - q.Y) ^ 2) / 100)
end
function Walkers.Staged(a)
    local m = movers[pathOf(a)]
    return m ~= nil and m.arrived == true
end
function Walkers.Seat(a)                -- (not there in time: set down in its seat)
    local m = movers[pathOf(a)]
    if not m or not m.staged then return end
    local spot = m.legs[1]
    pcall(function()
        a:K2_SetActorLocationAndRotation({ X = spot.X, Y = spot.Y, Z = spot.Z }, { pitch = 0, Yaw = m.faceYaw or 0, Roll = 0 },
            false, {}, true)
    end)
    m.state, m.arrived = "hold", true
    playWalk(a, false)
end
function Walkers.Unstage(a)
    local path = pathOf(a)
    local m = movers[path]
    if not m then return end
    m.staged, m.arrived = false, false
    m.legs, m.leg, m.state = { m.home }, 1, "walk"
    playWalk(a, true)
end

function Walkers.Init(c)
    WaCa, log, Events, Duties = c.WaCa, c.log, c.Events, c.Duties
    local ini = WaCa.ReadContent(c.modDir .. "/config/walkers.ini", "walkers") or {}
    local w = ini["Walkers"] or {}
    cfg.on = c.part("Walkers", w.On)
    for name in (w.Never or ""):gmatch("[^,]+") do
        name = name:match("^%s*(.-)%s*$")
        if name ~= "" then cfg.never[name] = true end
    end
    cfg.roamers = tonumber(w.Roamers or "") or cfg.roamers
    cfg.homebodies = tonumber(w.Homebodies or "") or cfg.homebodies
    cfg.speed = tonumber(w.Speed or "") or cfg.speed
    if w.Trace == "1" then
        traceFile = io.open(os.getenv("LOCALAPPDATA") .. "/Wrc/Saved/walkers_trace.txt", "w")
        log("walkers: tracing engine calls to Saved/walkers_trace.txt (diagnostic)")
    end
    log("walkers: %s", cfg.on and "on - the camp's named cats move about, in turns" or "off")
    if not cfg.on then return end
    local function loop()
        local ok, err = pcall(tick)
        if not ok then log("walkers: a step failed (%s)", tostring(err)) end
        ExecuteInGameThreadWithDelay(50, loop)
    end
    ExecuteInGameThreadWithDelay(1000, loop)
    local function lookLoop()
        pcall(look)
        ExecuteInGameThreadWithDelay(5000, lookLoop)
    end
    ExecuteInGameThreadWithDelay(2000, lookLoop)
    local upFor
    -- (the world up / going: the actor sweeps only while it's up - a sweep of every quest actor during a level load
    -- crashed the game, VM 2026-10-29)
    WaCa.On("ScreenShown", function(screen)
        local cls = screen:GetClass():GetFName():ToString()
        if cls:find("^WBP_GuiHudGame") then inWorld = true
        elseif cls:find("Loader") or cls:find("MainMenu") or cls:find("SelectYourCat") or cls:find("Transition") then
            inWorld = false
            movers = {}                                     -- (their actors go with the level)
        end
    end)
    WaCa.On("ScreenShown", function(screen)
        if not screen:GetClass():GetFName():ToString():find("^WBP_GuiHudGame") then return end
        local slot = WaCa.CurrentSlot()
        if upFor == slot then return end
        upFor = slot
        ExecuteInGameThreadWithDelay(30000, function()
            local ok, err = pcall(Walkers.Turn, "the world is up")
            if not ok then log("walkers: the turn failed (%s)", tostring(err)) end
        end)
    end)
    -- (talking to a cat opens the game's quest-giver dialogue screen, WBP_QuestGiver_Dialogue*, its NpcRef the cat
    -- spoken to; closed, the talk is over)
    WaCa.On("ScreenShown", function(screen)
        local cls = screen:GetClass():GetFName():ToString()
        if not cls:find("^WBP_QuestGiver_Dialogue") then return end
        local cat
        pcall(function() cat = screen.NpcRef end)
        pcall(talkBegins, (cat and cat:IsValid()) and cat or nil)
    end)
    WaCa.On("ScreenHidden", function(screen)
        if screen:GetClass():GetFName():ToString():find("^WBP_QuestGiver_Dialogue") then talkEnds("its dialogue closed") end
    end)
    -- (the sequencer's dialogue as a fallback. QuestBaseActor:OnDialogSetActive was dropped while chasing a boot crash
    -- - suspected, not proven (the crash was a turn during the level load); the dialogue screen covers it)
    WaCa.On("DialogueStarted", function() if not talkingSince then pcall(talkBegins) end end)
    WaCa.On("SequenceEnded", function() talkEnds("its sequence ended") end)
    WaCa.On("SequenceFinished", function() talkEnds("its sequence finished") end)
    -- (other mods: send a named cat somewhere now - it walks there, stays a while and walks home: actor path, X, Y, Z)
    WaCa.On("WalkerWalkTo", function(path, x, y, z)
        ExecuteInGameThread(function()
            local a = StaticFindObject(tostring(path))
            if not (a and a:IsValid()) then log("walkers: walk-to - no cat at %s", tostring(path)) return end
            local q, r = a:K2_GetActorLocation(), a:K2_GetActorRotation()
            local old = movers[pathOf(a)]
            local home = old and old.home or { X = q.X, Y = q.Y, Z = q.Z }
            movers[pathOf(a)] = { home = home, homeRot = old and old.homeRot or { pitch = r.pitch, Yaw = r.Yaw, Roll = r.Roll },
                                  legs = { { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }, home }, leg = 1,
                                  state = "wait", wait = 0, kind = "asked", name = nameOf(a) or "?" }
            log("walkers: %s is sent to %.0f %.0f", movers[pathOf(a)].name, tonumber(x), tonumber(y))
        end)
    end)
    -- (a turn now - other mods, the test harness)
    WaCa.On("WaCaWalkersTurn", function()
        ExecuteInGameThread(function() pcall(Walkers.Turn, "asked") end)
    end)
    for _, e in ipairs({ "ClanThird", "ClanNight" }) do
        WaCa.On(e, function(_, third)
            ExecuteInGameThread(function()
                local ok, err = pcall(Walkers.Turn, tostring(third))
                if not ok then log("walkers: the turn failed (%s)", tostring(err)) end
            end)
        end)
    end
end

return Walkers
