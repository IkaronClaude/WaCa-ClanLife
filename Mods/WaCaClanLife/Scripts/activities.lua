-- Clan activities (tickets.md 5), ambient part: clanmates near the player that stand still now and then sit, nap,
-- sniff around or play-fight - the game's own montages (ACharacter.PlayAnimMontage), which NPC cats play while their
-- AI runs (VM, 2026-10-27). config/activities.ini: [Ambient] On / Every / Radius, [Activity.<Name>] Montage / Weight
-- / Pair. One scheduled callback per Every seconds while the player is in the world (a schedule, not a state poll):
-- it starts when the gameplay HUD comes and stops when it goes.
local Activities = {}

local WaCa, log, modDir, DayNight
local cfg = { on = false, every = 20, radius = 3000, pairRadius = 2500, list = {}, total = 0 }
local running, generation = false, 0
local busyUntil = {}             -- cat name -> os.time() its activity ends

local function player()
    for _, c in ipairs(FindAllOf("SwtPlayerController") or {}) do
        if c:IsValid() and c.Player and c.Pawn and c.Pawn:IsValid() then return c.Pawn end
    end
end

-- clanmates (NPC cats, CharacterType Cat) near the player that stand still and aren't busy with an activity
local function idleCatsNear(pawn)
    local out = {}
    local catType
    pcall(function()
        StaticFindObject("/Script/SwtQuest.ESwtQuestCharacterType"):ForEachName(function(name, value)
            if name:ToString():gsub("^.*::", "") == "Cat" then catType = value end
        end)
    end)
    if not catType then return out end
    local at = pawn:K2_GetActorLocation()
    for _, c in ipairs(FindAllOf("BP_Exploration_Character_Base_C") or {}) do
        local ok, near = pcall(function()
            if not c:IsValid() or c.CharacterType ~= catType then return false end
            local p = c:K2_GetActorLocation()
            local v = c:GetVelocity()
            local d2 = (p.X - at.X) ^ 2 + (p.Y - at.Y) ^ 2
            -- not in the middle of an activity (NPC cats always run some montage of their own - only ours count)
            return d2 < cfg.radius * cfg.radius and (v.X * v.X + v.Y * v.Y) < 25 and (busyUntil[c:GetFName():ToString()] or 0) <= os.time()
        end)
        if ok and near then table.insert(out, c) end
        if not ok and not Activities.warned then
            Activities.warned = true
            log("activities: a clanmate couldn't be checked (%s)", tostring(near))
        end
    end
    return out
end

local function pick()
    local r = math.random() * cfg.total
    for _, a in ipairs(cfg.list) do
        r = r - a.weight
        if r <= 0 then return a end
    end
    return cfg.list[#cfg.list]
end

local function face(a, b)
    local pa, pb = a:K2_GetActorLocation(), b:K2_GetActorLocation()
    local yaw = math.deg(math.atan(pb.Y - pa.Y, pb.X - pa.X))
    a:K2_SetActorRotation({ pitch = 0, Yaw = yaw, Roll = 0 }, false)
end

local function once()
    local pawn = player()
    if not pawn then return end
    local cats = idleCatsNear(pawn)
    if #cats == 0 then return end
    local activity = pick()
    local montage = activity and LoadAsset(activity.montage)
    if not montage then
        log("activities: %s - its montage %s doesn't load", activity and activity.name or "?", activity and activity.montage or "?")
        return
    end
    local first = cats[math.random(#cats)]
    local function play(cat)
        busyUntil[cat:GetFName():ToString()] = os.time() + math.ceil(cat:PlayAnimMontage(montage, 1.0, FName("None")))
    end
    if not activity.pair then
        log("activities: %s - %s", first:GetFName():ToString(), activity.name)
        play(first)
        return
    end
    -- a pair: the nearest other idle clanmate within PairRadius; BOTH walk to the point between them (one AI move
    -- each - a single cat walking the whole way stopped short on the VM), and once they've had the time to get there
    -- (half the distance / walk speed, in game time - one callback, re-checked while they're still closing in), both
    -- face each other and play
    -- the nearest other idle clanmate within PairRadius (a straight-line neighbour across an obstacle can't arrive:
    -- the walk then stalls and the pair gives up below; the navigation path query returns nothing from Lua, VM)
    local partner, best
    local p = first:K2_GetActorLocation()
    for _, c in ipairs(cats) do
        if c ~= first then
            local q = c:K2_GetActorLocation()
            local d = (p.X - q.X) ^ 2 + (p.Y - q.Y) ^ 2
            if d < cfg.pairRadius * cfg.pairRadius and (not best or d < best) then partner, best = c, d end
        end
    end
    if not partner then return end                     -- nobody near enough to play with
    local q = partner:K2_GetActorLocation()
    local dist = math.sqrt(best)
    local mid = { X = (p.X + q.X) / 2, Y = (p.Y + q.Y) / 2, Z = (p.Z + q.Z) / 2 }
    local ux, uy = (q.X - p.X) / dist, (q.Y - p.Y) / dist
    local spots = { { X = mid.X - ux * 60, Y = mid.Y - uy * 60, Z = mid.Z }, { X = mid.X + ux * 60, Y = mid.Y + uy * 60, Z = mid.Z } }
    local speed = 300
    pcall(function() speed = math.max(50, partner.CharacterMovement.MaxWalkSpeed) end)
    local wait = math.ceil(dist / 2 / speed) + 1
    for _, cat in ipairs({ first, partner }) do busyUntil[cat:GetFName():ToString()] = os.time() + wait + 2 end
    -- their behaviour trees would override the walk (VM: 12 units in 5 game s): their AI logic pauses until the
    -- activity is over (restarted after the montage, or when they don't meet)
    local brains = {}
    local helper = StaticFindObject("/Script/AIModule.Default__AIBlueprintHelperLibrary")
    for i, cat in ipairs({ first, partner }) do
        pcall(function()
            local brain = cat:GetController().BrainComponent
            if brain and brain:IsValid() then
                brain:StopLogic("WaCa activity")
                table.insert(brains, (brain:GetFullName():gsub("^%S+ ", "")))
            end
        end)
        helper:SimpleMoveToLocation(cat:GetController(), spots[i])
    end
    local function resumeBrain()
        for _, path in ipairs(brains) do
            local br = StaticFindObject(path)
            if br and br:IsValid() then br:RestartLogic() end
        end
    end
    log("activities: %s and %s walk to meet (%.0f units apart) - %s", first:GetFName():ToString(), partner:GetFName():ToString(), dist, activity.name)
    local a, b = first:GetFullName():gsub("^%S+ ", ""), partner:GetFullName():gsub("^%S+ ", "")
    -- the walk takes `wait` GAME seconds; the delay below is wall time, so a slow frame rate (game time behind) gets
    -- a follow-up check while the partner is still closing in - at most 4, never on a cat that stopped approaching
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local t0, w0 = gs:GetTimeSeconds(first), os.time()
    local lastGap = dist
    local function check(tries)
        local ok, err = pcall(function()
            local c1, c2 = StaticFindObject(a), StaticFindObject(b)
            if not (c1 and c1:IsValid() and c2 and c2:IsValid()) then return end
            local l1, l2 = c1:K2_GetActorLocation(), c2:K2_GetActorLocation()
            local gap = math.sqrt((l1.X - l2.X) ^ 2 + (l1.Y - l2.Y) ^ 2)
            if gap > 300 then
                local gameElapsed = gs:GetTimeSeconds(c1) - t0
                if tries < 4 and gap < lastGap - 10 then
                    lastGap = gap
                    -- the rest of the walk in game seconds, as wall time at the frame rate measured so far
                    local wallPerGame = math.max(1, (os.time() - w0) / math.max(gameElapsed, 0.1))
                    local delay = math.max(1, gap / speed + 1) * wallPerGame
                    for _, cat in ipairs({ c1, c2 }) do busyUntil[cat:GetFName():ToString()] = os.time() + math.ceil(delay) + 2 end
                    log("activities: %s still on its way (%.0f units, %.1f game s so far) - checking again in %.0f s", c2:GetFName():ToString(), gap, gameElapsed, delay)
                    ExecuteInGameThreadWithDelay(math.floor(delay * 1000), function() check(tries + 1) end)
                    return
                end
                log("activities: %s didn't get to %s (%.0f units apart) - no %s", c2:GetFName():ToString(), c1:GetFName():ToString(), gap, activity.name)
                resumeBrain()
                return
            end
            face(c1, c2)
            face(c2, c1)
            play(c1)
            play(c2)
            log("activities: %s and %s - %s", c1:GetFName():ToString(), c2:GetFName():ToString(), activity.name)
            -- its AI back once the montage is over (its length in game time = wall time at the measured rate)
            local wallPerGame = math.max(1, (os.time() - w0) / math.max(gs:GetTimeSeconds(c1) - t0, 0.1))
            local len = (busyUntil[c2:GetFName():ToString()] or os.time()) - os.time()
            ExecuteInGameThreadWithDelay(math.floor(math.max(1, len) * wallPerGame * 1000), resumeBrain)
        end)
        if not ok then
            log("activities: pair failed (%s)", tostring(err))
            resumeBrain()
        end
    end
    ExecuteInGameThreadWithDelay(wait * 1000, function() check(0) end)
end

local function schedule(gen)
    ExecuteInGameThreadWithDelay(math.floor(cfg.every * 1000), function()
        if gen ~= generation or not running then return end
        local ok, err = pcall(once)
        if not ok then log("activities: failed (%s)", tostring(err)) end
        schedule(gen)
    end)
end

-- JOINABLE (tickets.md 5): next to a story cat (a quest NPC with a narrative role - the cats the game keeps bonds
-- with) the Join key makes both do an activity together; when it's over the bond grows the game's own way
-- (WaCaNative_AddBond -> its AddPersonalBonding: saved, ranks up like a dialogue answer), at most PerDay times per
-- cat and day. [Join] in activities.ini.
local join = { on = false, key = "G", radius = 400, bond = 2, perDay = 1, montage = nil, done = {} }
local roleNames

local function roleName(value)
    if not roleNames then
        roleNames = {}
        pcall(function()
            StaticFindObject("/Script/SwtQuest.ENarrativeRole"):ForEachName(function(n, v) roleNames[v] = n:ToString():gsub("^.*::", "") end)
        end)
    end
    return roleNames[value] or tostring(value)
end

-- the story cat nearest to the player's cat within Radius, and its role
local function storyCatNear(pawn)
    local at, best, bd = pawn:K2_GetActorLocation(), nil, nil
    for _, a in ipairs(FindAllOf("QuestBaseActor") or {}) do
        pcall(function()
            if a:IsValid() and not a.bHidden and a.narrativeRole and a.narrativeRole > 0 then
                local p = a:K2_GetActorLocation()
                local d = math.sqrt((p.X - at.X) ^ 2 + (p.Y - at.Y) ^ 2)
                if d <= join.radius and (not bd or d < bd) then best, bd = a, d end
            end
        end)
    end
    return best, bd
end

-- a montage on any cat: a character plays it itself, a quest NPC through its skeletal mesh's anim instance
local function playOn(actor, montage)
    local ok, len = pcall(function() return actor:PlayAnimMontage(montage, 1.0, FName("None")) end)
    if ok and len and len > 0 then return len end
    local skel = StaticFindObject("/Script/Engine.SkeletalMeshComponent")
    local comps = actor:K2_GetComponentsByClass(skel)
    for i = 1, #comps do
        local c = comps[i]
        c = (c.get and c:get()) or c
        local inst = c:IsValid() and c:GetAnimInstance()
        if inst and inst:IsValid() then
            local l = inst:Montage_Play(montage, 1.0, 0, 0.0, true)
            if l and l > 0 then return l end
        end
    end
    return 0
end

local function joinNow()
    local pawn = player()
    if not pawn or WaCa.InMenu() then return end
    local cat, dist = storyCatNear(pawn)
    if not cat then
        log("activities: no story cat close enough to join (within %d)", join.radius)
        return
    end
    local role = cat.narrativeRole
    local day = (DayNight and DayNight.Day()) or 0
    local key = role .. "@" .. day
    if (join.done[key] or 0) >= join.perDay then
        log("activities: you've spent time with %s today already", roleName(role))
        return
    end
    local montage = LoadAsset(join.montage) or WaCa.LoadAsset(join.montage)
    if not montage then
        log("activities: the join montage %s doesn't load", tostring(join.montage))
        return
    end
    face(pawn, cat)
    pcall(function() face(cat, pawn) end)
    local len = math.max(playOn(pawn, montage), playOn(cat, montage), 2)
    join.done[key] = (join.done[key] or 0) + 1
    log("activities: your cat and %s (%.0f away) spend time together (%.1f s)", roleName(role), dist, len)
    ExecuteInGameThreadWithDelay(math.floor(len * 1000), function()
        local ok = WaCaNative_AddBond and WaCaNative_AddBond(role, join.bond)
        log("activities: bond with %s %s%d%s", roleName(role), join.bond >= 0 and "+" or "", join.bond,
            ok and "" or " - FAILED (the game's bonding function wasn't found)")
    end)
end

function Activities.Init(c)
    WaCa, log, modDir, DayNight = c.WaCa, c.log, c.modDir, c.DayNight
    local ini = WaCa.ReadIni(modDir .. "/config/activities.ini") or {}
    local j = ini["Join"] or {}
    join.on = (j.On or "0") == "1"
    join.key = (j.Key or "") ~= "" and j.Key or join.key
    join.radius = tonumber(j.Radius or "") or join.radius
    join.bond = math.floor(tonumber(j.Bond or "") or join.bond)
    join.perDay = math.max(1, math.floor(tonumber(j.PerDay or "") or join.perDay))
    join.montage = (j.Montage or "") ~= "" and j.Montage or
        "/Game/Art/Characters/CatMaster/Animations/Montages/AM_CatMaster_SimpleSit.AM_CatMaster_SimpleSit"
    log("activities: joining %s (key %s, bond +%d, %d per cat and day)", join.on and "on" or "off", join.key, join.bond, join.perDay)
    if join.on then
        WaCa.On("KeyDown", function(_, name)
            if tostring(name) == join.key then
                local ok, err = pcall(joinNow)
                if not ok then log("activities: joining failed (%s)", tostring(err)) end
            end
        end)
    end
    local amb = ini["Ambient"] or {}
    cfg.on = (amb.On or "0") == "1"
    cfg.every = math.max(2, tonumber(amb.Every or "") or cfg.every)
    cfg.radius = tonumber(amb.Radius or "") or cfg.radius
    cfg.pairRadius = tonumber(amb.PairRadius or "") or cfg.pairRadius
    for section, keys in pairs(ini) do
        local name = section:match("^Activity%.(.+)$")
        if name and keys.Montage then
            local a = { name = name, montage = keys.Montage, weight = tonumber(keys.Weight or "") or 1, pair = keys.Pair == "1" }
            table.insert(cfg.list, a)
            cfg.total = cfg.total + a.weight
        end
    end
    table.sort(cfg.list, function(a, b) return a.name < b.name end)
    log("activities: ambient %s (%d activities, every %d s)", cfg.on and "on" or "off", #cfg.list, cfg.every)
    if not cfg.on or #cfg.list == 0 then return end
    WaCa.On("ScreenShown", function(screen)
        if running or not screen:GetClass():GetFName():ToString():find("^WBP_GuiHudGame") then return end
        running = true
        generation = generation + 1
        schedule(generation)
    end)
    WaCa.On("ScreenHidden", function(screen)
        if not screen:GetClass():GetFName():ToString():find("^WBP_GuiHudGame") then return end
        running = false
    end)
end

return Activities
