-- Scenes (tickets.md 17 + 10, "show, don't tell") - the ONE place the mod plays cards, the game's conversations and
-- cinematics, fades, bonds and other mods' hooks, and the story's hook points (the clan loop: duties.lua; the story
-- as days: days.lua; hour-scheduled scenes: config/events.ini [Event.<Name>]).
--
-- A scene = steps run one after another, each waiting for its own end (written as config lines, or Lua tables):
--   Card: <text>                 the game's centre message, CardSeconds long ({DAY}, {THIRD}, {DEPUTY} ... filled);
--                                cards queue - never two at once
--   Gather: <n> [@ Here|Pile]    the n nearest clanmates come and stand in a ring around your cat / the fresh-kill pile
--   Pose: <pose> [@ Gathered|Player|All|<who>]   an animation: Sit, Lie, Sleep, Eat, Sniff, Meow, Play, Groom (the
--                                game's montages) or a montage path
--   Release                      the gathered cats go back to their own lives
--   Dialogue: <id> [@ <who>]     one of the game's own conversations / cinematics (SwtQuestSequencerManager:
--                                PlaySequenceDialogue; the ids: events-dialogues.txt) with <who>; waits until it is
--                                over (the sequencer reports its end / the dialogue screen closes)
--   Fade: <seconds> / FadeIn: <seconds>   the screen fades to black (and stays) / back - a time skip's cutscene
--   Wait: <seconds>              a pause
--   Bond: <points> [@ <who>]     the bond with a story cat grows (the game's own AddPersonalBonding)
--   Emit: <event>                WaCa.Emit(event, context) - another mod's WaCa.On handler runs here
--   Hook: <name>                 BLOCKING: every function registered with Events.Hook(name, fn) runs in turn as
--                                fn(context, continue) and calls continue() when its part is over (a mod's own
--                                cutscene, a minigame, a choice ...)
--   Set: <var> = <value>         a STORY VARIABLE (kept with the save): e.g. Set: LeaderAnger = 2
--   Add: <var> <number>          e.g. Add: LeaderFavour 3, Add: GatheringBan -1
--   If: <conditions>             the rest of the scene only if they hold: <var> <op> <value>[, ...], op = < <= = != >= >
--                                (e.g. If: LeaderFavour >= 5, Rank >= 2) - unset variables are 0
-- Story variables are also read by conditions elsewhere (clanevents.ini Require, gatherings.ini ...); built-in ones
-- come from the mod (Day, Standing, Rank ... - Events.Provide(name, fn)).
-- <who>: Deputy, Leader, MedicineCat, Teacher (the clan's move teacher), Nearest (the nearest clanmate; default), or
-- any story role (ENarrativeRole name). The player's clan's cat first.
-- The game's sequencer itself is open to every mod through WaCa events (WaCa.lua): SequenceStarted / SequenceFinished
-- (manager, sequence id), SequenceEnded, DialogueStarted (manager, dialogue id), DialogueNext.
-- Lua: Events.Run(steps, onDone, context), Events.Play(scene), Events.Hook(name, fn), Events.Who(name),
-- Events.Parse(line), Events.Lines(section, prefix), Events.Var(name), Events.SetVar(name, value),
-- Events.Check(conditions), Events.Provide(name, fn). WaCa event StoryVar(name, value) when one changes.
local Events = {}

local WaCa, log, modDir, DayNight
local CARD = "/Game/Art/UXD/Blueprints/Popups/WBP_GuiPopupCenterMessage.WBP_GuiPopupCenterMessage_C"
local cfg = { cardSeconds = 5, dialogueMax = 300, startWait = 15, gatherRadius = 6000, gatherRing = 260, gatherArc = 90,
              groupRadius = 90, groupFirstRow = 340, groupRowGap = 280, groupSpread = 220,
              walkIn = true, walkFrom = 700, walkReach = 80, walkSeconds = 12, walkSpeed = 150 }
local list = {}                  -- hour-scheduled scenes: { name, day, every, hour, steps, once }
local done = {}                  -- one-time scenes already played in this save
local restoredFor
local listed = false
local hooks = {}                 -- Hook: name -> { fn, ... }
local waiting                    -- the dialogue step waiting for its end: { started, done = fn }
local gen = 0

local function pc()
    for _, c in ipairs(FindAllOf("SwtPlayerController") or {}) do
        if c:IsValid() and c.Player then return c end
    end
end

-- Cards: ONE AT A TIME (operator 2026-10-28: the day's verdict and the morning's card came together and overlapped) -
-- every card of the mod goes through this queue; each shows for its seconds, then the next. onShown / onGone: when it
-- comes up / goes (a scene's Card step waits for its own card to go).
local cards = { queue = {}, showing = false }

local function nextCard()
    if not cards.queue[1] then
        cards.showing = false
        return
    end
    cards.showing = true
    -- (not over a conversation, a cutscene or a menu: the card waits for it)
    if WaCa.InMenu() then
        ExecuteInGameThreadWithDelay(1000, nextCard)
        return
    end
    local c = table.remove(cards.queue, 1)
    log("card: %s", tostring(c.text))
    local ok, err = pcall(function()
        local class = WaCa.LoadAsset(CARD)
        local controller = pc()
        local w = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(controller, class, controller)
        w:AddToViewport(60)
        w.mcGuiTextInfo:SetText(FText(c.text))     -- after AddToViewport (its construct sets a string-table key)
        c.name = (w:GetFullName():gsub("^%S+ ", ""))
    end)
    if not ok then log("events: card failed (%s)", tostring(err)) end
    ExecuteInGameThreadWithDelay(math.floor(c.seconds * 1000), function()
        local o = c.name and StaticFindObject(c.name)
        if o and o:IsValid() then o:RemoveFromParent() end
        if c.onGone then pcall(c.onGone) end
        nextCard()
    end)
end

function Events.Card(text, seconds, onGone)
    table.insert(cards.queue, { text = text, seconds = seconds or cfg.cardSeconds, onGone = onGone })
    if not cards.showing then nextCard() end
end

local function showCard(text, seconds, onGone) Events.Card(text, seconds, onGone) end

-- --- who: story cats by their part in the clan ---

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

local function clan()
    return WaCa.PlayerClan()          -- (the cat in the world's, else the save's)
end

-- the clanmate nearest to the player's cat (NPC cats: CharacterType Cat)
local function nearestClanmate(pawn)
    local catType
    pcall(function()
        StaticFindObject("/Script/SwtQuest.ESwtQuestCharacterType"):ForEachName(function(n, v)
            if n:ToString():gsub("^.*::", "") == "Cat" then catType = v end
        end)
    end)
    local at, best, bd = pawn:K2_GetActorLocation(), nil, nil
    for _, c in ipairs(FindAllOf("BP_Exploration_Character_Base_C") or {}) do
        pcall(function()
            if c:IsValid() and c.CharacterType == catType and not c.bHidden and c:GetAddress() ~= pawn:GetAddress() then
                local p = c:K2_GetActorLocation()
                local d = (p.X - at.X) ^ 2 + (p.Y - at.Y) ^ 2
                if not bd or d < bd then best, bd = c, d end
            end
        end)
    end
    return best
end

local ALIAS = { Teacher = "WarriorMoveLearn$" }

-- a story cat by its part ("Deputy" -> the player's clan's ThunderClanDeputy ...), or the nearest clanmate
-- ROLES are compound keys (operator 2026-10-28): "E:<name>" = one of the game's own (ENarrativeRole: E:RiverClanDeputy -
-- the game's story cat with that role; its tables, bonding, parties know it), "S:<name>" = a mod's own string role
-- (S:warrior_otterstream - bound to a real cat with Events.BindRole; only our layer knows it). A bare name = E.
local bound = {}             -- "S:name" -> the bound cat's object path

function Events.BindRole(key, cat)
    if type(cat) ~= "string" then cat = cat and (cat:GetFullName():gsub("^%S+ ", "")) end
    bound[key] = cat
    log("events: role %s = %s", key, tostring(cat))
    WaCa.Emit("RoleBound", key, cat)
end

function Events.Role(key)
    local kind, name = tostring(key):match("^([ES]):(.+)$")
    return kind or "E", name or key
end

function Events.Who(name)
    name = (name and name ~= "") and name or "Nearest"
    local pawn = pc() and pc().Pawn
    if name == "Nearest" then return pawn and nearestClanmate(pawn) or nil end
    local kind, role = Events.Role(name)
    if kind == "S" then
        local a = bound[name] and StaticFindObject(bound[name])
        return a and a:IsValid() and a or nil
    end
    name = role
    local pattern = ALIAS[name] or name
    local mine = clan()
    local fallback
    for _, a in ipairs(FindAllOf("QuestBaseActor") or {}) do
        local found
        pcall(function()
            local r = a:IsValid() and a.narrativeRole and roleName(a.narrativeRole)
            if r and (r == name or r:find(pattern)) then
                if r == name or (mine and r:find("^" .. mine)) then found = a else fallback = fallback or a end
            end
        end)
        if found then return found end
    end
    return fallback
end

-- --- staging: clanmates gathered around a place, poses (the game's own animation montages) ---

-- Gather: <n> [@ Here | Pile]   the n nearest clanmates come together in an arc facing your cat (Here, the default) or
--                                the clan's fresh-kill pile, facing its middle - a cut, like a cutscene: the screen
--                                fades, they are placed, it fades back in. The cats are the camp's walking cats - the
--                                game's own AI characters, which it shows once your cat is near (the camp's quest
--                                actors moved the same way never drew: VM 2026-10-28); their AI waits while they're
--                                gathered, so they don't pace off.
-- Pose: <pose> [@ Gathered | Player | All | <who>]   the cats play one of the game's animation montages: Sit, Lie
--                                (lying down to rest), Sleep, Eat, Sniff, Meow, Play, Groom - or a montage's object path
-- Release                        the screen fades and the gathered cats are back where they were
local POSES = {
    Sit = { "AM_CatMaster_SimpleSit" }, Lie = { "AM_Interact_Sleep_1" },
    Sleep = { "AM_Interact_Sleep_1", "AM_Interact_Sleep_2", "AM_Interact_Sleep_3" }, Eat = { "AM_Interact_Bite_1" },
    Sniff = { "AM_Interact_Sniffing" }, Meow = { "AM_Meow" }, Play = { "AM_Interact_Play" }, Groom = { "AM_Interact_Sharpen" },
}
local MONTAGES = "/Game/Art/Characters/CatMaster/Animations/Montages/"
local FADE = 0.8

local function montage(pose)
    local names = POSES[pose]
    local path = names and (MONTAGES .. names[math.random(#names)]) or pose
    if not path:find("%.") then path = path .. "." .. path:match("([^/]+)$") end
    local ok, m = pcall(WaCa.LoadAsset, path)
    return ok and m and m:IsValid() and m or nil
end

local function poseTargets(who, ctx)
    local out = {}
    local pawn = pc() and pc().Pawn
    who = who or "Gathered"
    if who == "Gathered" or who == "All" then
        for _, g in ipairs(ctx and ctx.gathered or {}) do
            local a = StaticFindObject(g.path)
            if a and a:IsValid() then table.insert(out, a) end
        end
    end
    if (who == "Player" or who == "All") and pawn then table.insert(out, pawn) end
    if #out == 0 and who ~= "Gathered" and who ~= "All" and who ~= "Player" then
        local a = Events.Who(who)
        if a then table.insert(out, a) end
    end
    return out
end

-- a montage on any cat: a Character plays it itself; placed scenery (the camp's quest actors) through its mesh
local meshClass
local function playMontage(cat, m)
    if pcall(function() cat:PlayAnimMontage(m, 1.0, FName("None")) end) then return true end
    meshClass = meshClass or StaticFindObject("/Script/Engine.SkeletalMeshComponent")
    return pcall(function()
        local mesh = cat:GetComponentByClass(meshClass)
        mesh:GetAnimInstance():Montage_Play(m, 1.0, 0, 0.0, true)
    end)
end

local function stopMontage(cat)
    if pcall(function() cat:StopAnimMontage(nil) end) then return end
    pcall(function()
        meshClass = meshClass or StaticFindObject("/Script/Engine.SkeletalMeshComponent")
        cat:GetComponentByClass(meshClass):GetAnimInstance():Montage_Stop(0.25, nil)
    end)
end

function Events.Pose(pose, who, ctx)
    local n = 0
    for _, cat in ipairs(poseTargets(who, ctx)) do
        local m = montage(pose)
        if m and playMontage(cat, m) then n = n + 1 end
    end
    log("events: pose %s - %d cat(s) (%s)", tostring(pose), n, tostring(who or "Gathered"))
end

local function placeOf(where)
    local pawn = pc() and pc().Pawn
    if not pawn then return nil end
    local at = pawn:K2_GetActorLocation()
    if where == "Pile" then
        local best, bd
        for _, a in ipairs(FindAllOf("BP_Quest_Giver_FreshKill_C") or {}) do
            pcall(function()
                local q = a:K2_GetActorLocation()
                local d = (q.X - at.X) ^ 2 + (q.Y - at.Y) ^ 2
                if not bd or d < bd then best, bd = q, d end
            end)
        end
        if best and bd < 6000 ^ 2 then return best end
    end
    return at
end

-- the clanmates near a place, nearest first: the camp's walking cats (BP_WalkingNPC_Character_Base_C - the game
-- walks them on its paths with its AI and hides them while your cat is far: VM 2026-10-28, all 6 near RiverClan's camp
-- were hidden at 24-48 m and shown, drawn and pacing again within a second of being moved in) and roaming clan cats.
-- (Not the camp's quest actors - the fillers, the deputy ...: the game parks most of them - 38 of 41 fillers had their
-- body switched off - and the ones moved never drew, though their bodies said visible.)
local function clanmatesNear(place, n, radius)
    local found = {}
    local function consider(a)
        local q = a:K2_GetActorLocation()
        local d = math.sqrt((q.X - place.X) ^ 2 + (q.Y - place.Y) ^ 2)
        if d > 1 and d <= radius then table.insert(found, { a, d }) end
    end
    for _, c in ipairs(FindAllOf("SwtAdventureWalkingNPC") or {}) do
        pcall(function() if c:IsValid() and not c.bHidden then consider(c) end end)
    end
    for _, c in ipairs(FindAllOf("BP_Exploration_Character_Base_C") or {}) do
        pcall(function() if c:IsValid() and c.CharacterType == 1 and not c.bHidden then consider(c) end end)
    end
    table.sort(found, function(a, b) return a[2] < b[2] end)
    local out = {}
    for i = 1, math.min(n, #found) do out[i] = found[i][1] end
    return out
end

-- a gathered cat stays put: its AI waits and its movement is off while it's staged (pausing the brain alone wasn't
-- enough - the cats paced 40-490 from a 260 ring: VM 2026-10-28), on again when it's let go. Returns what held.
local function holdAI(cat, on)
    local held = {}
    pcall(function()
        local ctl = cat.Controller
        if not (ctl and ctl:IsValid()) then return end
        if on then
            ctl:StopMovement()
            if pcall(function() ctl.BrainComponent:PauseLogic("WaCa gathering") end) then held[#held + 1] = "brain" end
        else
            pcall(function() ctl.BrainComponent:ResumeLogic("WaCa gathering") end)
        end
    end)
    pcall(function()
        local move = cat.CharacterMovement
        if not (move and move:IsValid()) then return end
        if on then
            move:StopMovementImmediately()
            move:DisableMovement()
            held[#held + 1] = "movement"
        else
            move:SetMovementMode(1, 0)                                  -- (walking)
        end
    end)
    return table.concat(held, "+")
end

local function fadeScreen(from, to, seconds)
    pcall(function()
        pc().PlayerCameraManager:StartCameraFade(from, to, seconds, { R = 0, G = 0, B = 0, A = 1 }, true, true)
    end)
end

function Events.Gather(n, where, ctx, done)
    local place = placeOf(where)
    if not place then return done() end
    local cats = clanmatesNear(place, n, cfg.gatherRadius)
    if #cats == 0 then
        log("events: gather - no walking clan cats within %.0f m of %.0f %.0f", cfg.gatherRadius / 100,
            place.X, place.Y)
        return done()
    end
    ctx.gathered, ctx.place = {}, place
    fadeScreen(0, 1, FADE)
    ExecuteInGameThreadWithDelay(math.floor(FADE * 1000) + 100, function()
        local held = {}
        -- (an arc in front of the camera, not a full ring: the game's camera sits ~1 m behind your cat, so a ring put
        -- two cats behind it, two off the sides and one hidden behind your cat - VM 2026-10-28)
        local facing = 0
        pcall(function() facing = pc().PlayerCameraManager:GetCameraRotation().Yaw end)
        for i, cat in ipairs(cats) do
            pcall(function()
                local step = #cats > 1 and (i - 1) / (#cats - 1) - 0.5 or 0
                local a = math.rad(facing + step * cfg.gatherArc)
                local spot = { X = place.X + math.cos(a) * cfg.gatherRing, Y = place.Y + math.sin(a) * cfg.gatherRing,
                               Z = place.Z + 20 }
                local yaw = math.deg(math.atan(place.Y - spot.Y, place.X - spot.X))
                -- (copied out: the returned structs are live views that don't keep the old values - the release put
                -- nobody back: VM 2026-10-28)
                local l, r = cat:K2_GetActorLocation(), cat:K2_GetActorRotation()  -- (FRotator: lower-case pitch in this build)
                table.insert(ctx.gathered, { path = (cat:GetFullName():gsub("^%S+ ", "")),
                                             loc = { X = l.X, Y = l.Y, Z = l.Z }, rot = { pitch = r.pitch, Yaw = r.Yaw, Roll = r.Roll } })
                cat:K2_SetActorLocationAndRotation(spot, { pitch = 0, Yaw = yaw, Roll = 0 }, false, {}, true)
                held[#held + 1] = holdAI(cat, true)
            end)
        end
        local names = {}
        for i, e in ipairs(ctx.gathered) do
            names[#names + 1] = (e.path:match("[^.:]+$") or e.path) .. " (held: " .. (held[i] ~= "" and held[i] or "nothing") .. ")"
        end
        log("events: gather - %d clanmate(s) around %s: %s", #ctx.gathered, where or "your cat", table.concat(names, ", "))
        fadeScreen(1, 0, FADE)
        ExecuteInGameThreadWithDelay(math.floor(FADE * 1000), done)
    end)
end

-- the staged cats back where they were (their poses stopped, their AI on again)
local function putBack(g)
    for _, e in ipairs(g or {}) do
        local a = StaticFindObject(e.path)
        if a and a:IsValid() then
            stopMontage(a)
            local ok, err = pcall(function() a:K2_SetActorLocationAndRotation(e.loc, e.rot, false, {}, true) end)
            if not ok then log("events: release - %s stays: %s", e.path, tostring(err)) end
            holdAI(a, false)
        end
    end
end

-- Groups: Tongues | Prey   the evening in camp (operator 2026-10-28): not one ring but small groups - sharing tongues in
--                          circles of 2-3, sharing prey in 2s and 3s with now and then a 4 around a big piece. Who sits
--                          with whom follows the cats' ties (config/relations.ini): cats with a tension never share a
--                          group, the leader only sits with its mate and / or the deputy (else apart), apprentices with
--                          apprentices first, then elders with elders, warriors with warriors. Your cat joins the
--                          group that suits it best, right where it stands; the others are placed in front of the
--                          camera (it sits ~1 m behind your cat), each group a small circle facing its own middle.
local ROLE_NAMES = { [1] = "Kit", [2] = "Apprentice", [3] = "Elder", [4] = "Warrior", [5] = "MedicineCat", [6] = "Queen",
                     [7] = "Deputy", [8] = "Leader" }
local RANK_ROLES = { [0] = "Apprentice", "Apprentice", "Warrior", "Deputy", "Leader" }
local relations = { mates = {}, tensions = {}, friends = {} }

local function tie(set, a, b)
    set[a] = set[a] or {}
    set[b] = set[b] or {}
    set[a][b], set[b][a] = true, true
end

local function readRelations(modDir)
    local ini = WaCa.ReadContent(modDir .. "/config/relations.ini", "relations") or {}
    local n = 0
    for section, set in pairs({ Mates = relations.mates, Tensions = relations.tensions, Friends = relations.friends }) do
        for a, list in pairs(ini[section] or {}) do
            if a ~= "__order" and a ~= "__mods" and type(list) == "string" then
                for b in list:gmatch("[^,]+") do
                    b = b:match("^%s*(.-)%s*$")
                    if b ~= "" then tie(set, a, b) n = n + 1 end
                end
            end
        end
    end
    return n
end

local clanNames
local function clanName(v)
    if not clanNames then
        clanNames = {}
        pcall(function()
            StaticFindObject("/Script/SwtQuest.EClanType"):ForEachName(function(n, x) clanNames[x] = n:ToString():gsub("^.*::", "") end)
        end)
    end
    return clanNames[v]
end

-- a camp cat as the groups see it: its name (the game's own: name ids -> STR_CAT_NAME<n><_SUFFIX>), role and clan
local function identity(cat)
    local who = { cat = cat }
    pcall(function()
        local cd = cat.MeshCustomizationComponent.CustomData
        who.role = ROLE_NAMES[cd.Role] or tostring(cd.Role)
        who.clan = clanName(cd.ClanType)
        local name = WaCa.GetText(cd.PrefixNameId:ToString() .. cd.SuffixNameId:ToString())
        if name ~= "" then who.name = name end
    end)
    who.name = who.name or (cat:GetFName():ToString())
    return who
end

local function getsOn(a, b)
    if relations.tensions[a.name] and relations.tensions[a.name][b.name] then return false end
    -- the leader: only its mate and / or the deputy
    for _, pair in ipairs({ { a, b }, { b, a } }) do
        local l, o = pair[1], pair[2]
        if l.role == "Leader" and not (o.role == "Deputy" or (relations.mates[l.name] and relations.mates[l.name][o.name])) then
            return false
        end
    end
    return true
end

local function liking(a, b)
    local s = 0
    if relations.mates[a.name] and relations.mates[a.name][b.name] then s = s + 5 end
    if relations.friends[a.name] and relations.friends[a.name][b.name] then s = s + 3 end
    if a.role == b.role then s = s + (a.role == "Apprentice" and 4 or 2) end
    if (a.role == "Kit" and b.role == "Queen") or (a.role == "Queen" and b.role == "Kit") then s = s + 3 end
    return s + math.random() * 0.5
end

-- the cats into groups of the kind's sizes; returns the groups (lists of identities) and the cats left apart
local function makeGroups(cats, kind)
    local pool, groups, apart = {}, {}, {}
    for _, c in ipairs(cats) do pool[#pool + 1] = c end
    -- (the most particular first: the player, the leader, then apprentices ...)
    local order = { Player = 0, Leader = 1, Apprentice = 2, Kit = 3, Elder = 4 }
    table.sort(pool, function(a, b)
        local x, y = a.player and 0 or (order[a.role] or 5), b.player and 0 or (order[b.role] or 5)
        if x ~= y then return x < y end
        return a.name < b.name
    end)
    local bigDone = false
    while #pool > 0 do
        local seed = table.remove(pool, 1)
        local size = (#pool + 1 >= 3 and math.random() < 0.5) and 3 or 2
        if kind == "Prey" and not bigDone and #pool + 1 >= 4 and math.random() < 0.35 then size, bigDone = 4, true end
        local g = { seed }
        while #g < size do
            local best, bestScore, bestI
            for i, c in ipairs(pool) do
                local ok = true
                for _, m in ipairs(g) do if not getsOn(c, m) then ok = false break end end
                if ok then
                    local s = 0
                    for _, m in ipairs(g) do s = s + liking(c, m) end
                    if not bestScore or s > bestScore then best, bestScore, bestI = c, s, i end
                end
            end
            if not best then break end
            table.remove(pool, bestI)
            g[#g + 1] = best
        end
        if #g >= 2 then groups[#groups + 1] = g else apart[#apart + 1] = seed end
    end
    -- (a cat left on its own by a tension joins another group with room - one of 3 at most, 4 for prey - where it
    -- gets on with everyone; the leader without its mate / deputy stays apart)
    local still = {}
    for _, c in ipairs(apart) do
        local home
        for _, g in ipairs(groups) do
            if #g < (kind == "Prey" and 4 or 3) then
                local ok = true
                for _, m in ipairs(g) do if not getsOn(c, m) then ok = false break end end
                if ok then home = g break end
            end
        end
        if home then home[#home + 1] = c else still[#still + 1] = c end
    end
    return groups, still
end

function Events.Groups(kind, where, ctx, done)
    kind = (kind == "Prey") and "Prey" or "Tongues"
    local pawn = pc() and pc().Pawn
    local place = placeOf(where)
    if not (pawn and place) then return done() end
    local myClan = WaCa.PlayerClan and WaCa.PlayerClan() or nil
    local cats = {}
    for _, c in ipairs(clanmatesNear(place, 40, cfg.gatherRadius)) do
        local who = identity(c)
        if not (myClan and who.clan and who.clan ~= myClan) then cats[#cats + 1] = who end
    end
    if #cats == 0 then
        log("events: groups - no walking clan cats within %.0f m", cfg.gatherRadius / 100)
        return done()
    end
    local rank = WaCa.PlayerRank and WaCa.PlayerRank() or 2
    local me = { cat = pawn, player = true, role = RANK_ROLES[rank] or "Warrior", name = "your cat" }
    pcall(function() local c = WaCa.SaveCharacter() if c and c.Name then me.name = c.Name end end)
    cats[#cats + 1] = me
    local groups, apart = makeGroups(cats, kind)
    -- (your cat's group first: it forms where your cat stands)
    table.sort(groups, function(a, b)
        local x, y = false, false
        for _, m in ipairs(a) do if m.player then x = true end end
        for _, m in ipairs(b) do if m.player then y = true end end
        return x and not y
    end)
    local lines = {}
    for i, g in ipairs(groups) do
        local names = {}
        for _, m in ipairs(g) do names[#names + 1] = m.name .. " (" .. m.role .. ")" end
        lines[#lines + 1] = i .. ": " .. table.concat(names, ", ")
    end
    local apartNames = {}
    for _, m in ipairs(apart) do apartNames[#apartNames + 1] = m.name .. " (" .. m.role .. ")" end
    log("events: groups (%s) - %d group(s): %s%s", kind, #groups, table.concat(lines, " | "),
        #apart > 0 and (" | apart: " .. table.concat(apartNames, ", ")) or "")
    local before = ctx.gathered
    ctx.gathered, ctx.place = {}, place
    fadeScreen(0, 1, FADE)
    local walking = {}
    ExecuteInGameThreadWithDelay(math.floor(FADE * 1000) + 100, function()
        -- (a scene of several group steps - the meal, then sharing tongues: the last step's cats go back first)
        if before and #before > 0 then
            putBack(before)
            pcall(function() stopMontage(pawn) end)
        end
        local facing = 0
        pcall(function() facing = pc().PlayerCameraManager:GetCameraRotation().Yaw end)
        local fwd, side = math.rad(facing), math.rad(facing + 90)
        local n, k = 0, 0
        for _, g in ipairs(groups) do
            -- the group's middle: your cat's group just ahead of it; the rest in rows further on, spread sideways
            local ahead, across
            local hasMe = false
            for _, m in ipairs(g) do if m.player then hasMe = true end end
            if hasMe then
                -- (beside your cat and a little ahead: straight ahead, its group hid behind your cat's own body from
                -- the camera right behind it - VM 2026-10-29)
                ahead, across = cfg.groupRadius * 0.5, cfg.groupRadius
            else
                k = k + 1
                local row = math.floor((k - 1) / 3)
                local col = (k - 1) % 3 - 1
                ahead = cfg.groupFirstRow + row * cfg.groupRowGap
                across = col * cfg.groupSpread * (1 + row * 0.5)
            end
            local mid = { X = place.X + math.cos(fwd) * ahead + math.cos(side) * across,
                          Y = place.Y + math.sin(fwd) * ahead + math.sin(side) * across, Z = place.Z }
            -- the members round the middle; your cat keeps its spot (the slot nearest the camera)
            local others = {}
            for _, m in ipairs(g) do if not m.player then others[#others + 1] = m end end
            local count = #g
            -- (round the circle from your cat's own place in it; another group from its side nearest the camera)
            local base = fwd + math.pi
            local radius = cfg.groupRadius
            if hasMe then
                base = math.atan(place.Y - mid.Y, place.X - mid.X)
                radius = math.sqrt((place.X - mid.X) ^ 2 + (place.Y - mid.Y) ^ 2)
            end
            for i, m in ipairs(others) do
                pcall(function()
                    local slot = hasMe and i or (i - 1)
                    local a = base + slot / count * 2 * math.pi
                    local spot = { X = mid.X + math.cos(a) * radius, Y = mid.Y + math.sin(a) * radius,
                                   Z = place.Z + 20 }
                    local yaw = math.deg(math.atan(mid.Y - spot.Y, mid.X - spot.X))
                    local cat = m.cat
                    local l, r = cat:K2_GetActorLocation(), cat:K2_GetActorRotation()
                    table.insert(ctx.gathered, { path = (cat:GetFullName():gsub("^%S+ ", "")),
                                                 loc = { X = l.X, Y = l.Y, Z = l.Z }, rot = { pitch = r.pitch, Yaw = r.Yaw, Roll = r.Roll } })
                    if cfg.walkIn then
                        -- (they walk in: set down a few metres out from their seat, inside the game's range so their AI
                        -- runs - from afar the game freezes them and a move order did nothing: VM 2026-10-28)
                        local dx, dy = spot.X - mid.X, spot.Y - mid.Y
                        local len = math.max(1, math.sqrt(dx * dx + dy * dy))
                        local from = { X = spot.X + dx / len * cfg.walkFrom, Y = spot.Y + dy / len * cfg.walkFrom, Z = spot.Z }
                        cat:K2_SetActorLocationAndRotation(from, { pitch = 0, Yaw = yaw, Roll = 0 }, false, {}, true)
                        walking[#walking + 1] = { cat = cat, spot = spot, yaw = yaw }
                    else
                        cat:K2_SetActorLocationAndRotation(spot, { pitch = 0, Yaw = yaw, Roll = 0 }, false, {}, true)
                        holdAI(cat, true)
                    end
                    n = n + 1
                end)
            end
            if hasMe then
                pcall(function()
                    local yaw = math.deg(math.atan(mid.Y - place.Y, mid.X - place.X))
                    pawn:K2_SetActorRotation({ pitch = 0, Yaw = yaw, Roll = 0 }, true)
                end)
            end
        end
        log("events: groups - %d clanmate(s) placed%s", n, cfg.walkIn and (", " .. #walking .. " walking in") or "")
        fadeScreen(1, 0, FADE)
        if #walking == 0 then
            ExecuteInGameThreadWithDelay(math.floor(FADE * 1000), done)
            return
        end
        -- the walk: each cat is walked to its seat by its own character movement - steered there each tick (an AI
        -- move order did nothing: these cats walk by the game's own move handler, not the navmesh - VM 2026-10-29);
        -- its behaviour tree paused so it doesn't wander off. Seated = turned to the middle and held. Who isn't there
        -- after WalkSeconds is set down in its seat.
        for _, w in ipairs(walking) do
            pcall(function() w.cat.Controller.BrainComponent:PauseLogic("WaCa gathering") end)
            pcall(function() w.cat.Controller:StopMovement() end)
            -- (the camp cats amble at 50 - a pace that took ~6 s for 3 m: they walk over at WalkSpeed, then back to
            -- their own - VM 2026-10-29)
            pcall(function()
                local m = w.cat.CharacterMovement
                m:SetMovementMode(1, 0)            -- (walking: a cat left held by an interrupted scene couldn't move)
                w.speed = m.MaxWalkSpeed
                m.MaxWalkSpeed = math.max(w.speed, cfg.walkSpeed)
            end)
        end
        local started = os.time()
        local waited, lastReport = 0, 0
        local function seat(w, snapped)
            w.seated = true
            pcall(function() if w.speed then w.cat.CharacterMovement.MaxWalkSpeed = w.speed end end)
            pcall(function()
                if snapped then
                    w.cat:K2_SetActorLocationAndRotation(w.spot, { pitch = 0, Yaw = w.yaw, Roll = 0 }, false, {}, true)
                else
                    w.cat:K2_SetActorRotation({ pitch = 0, Yaw = w.yaw, Roll = 0 }, true)
                end
            end)
            holdAI(w.cat, true)
        end
        local function check()
            waited = os.time() - started
            local left, walked = 0, 0
            for _, w in ipairs(walking) do
                if not w.seated then
                    local ok, d = pcall(function()
                        local q = w.cat:K2_GetActorLocation()
                        return math.sqrt((q.X - w.spot.X) ^ 2 + (q.Y - w.spot.Y) ^ 2)
                    end)
                    -- (blocked - by the circle's other cats or yours - for 3 s and 10 ticks (a slow frame rate counts in
                    -- ticks): the last step is a set-down; the cats got
                    -- 50-90% of the way and stalled there: VM 2026-10-29)
                    w.checks = (w.checks or 0) + 1
                    if ok and (not w.best or d < w.best - 10) then w.best, w.bestAt, w.bestCheck = d, waited, w.checks end
                    if ok and d <= cfg.walkReach then
                        seat(w, false)
                        walked = walked + 1
                    elseif ok and w.bestAt and waited - w.bestAt >= 3 and w.checks - w.bestCheck >= 10 then
                        seat(w, true)
                        w.short = true
                    else
                        left = left + 1
                        -- (its AI controller walks it: a straight move, no navmesh path - movement input does nothing on
                        -- these cats, and a pathfinding move order never started: VM 2026-10-29)
                        pcall(function()
                            local ctl = w.cat.Controller
                            -- (re-ordered every 5 ticks too: its own walk took it back off between orders - VM 2026-10-29)
                            if not w.ordered or ctl:GetMoveStatus() == 0 or (w.checks or 0) % 5 == 0 then
                                ctl:MoveToLocation(w.spot, cfg.walkReach * 0.5, false, false, false, false, nil, true)
                                w.ordered = true
                            end
                        end)
                    end
                end
            end
            if waited >= (lastReport or 0) + 10 then
                lastReport = waited
                local parts = {}
                for _, w in ipairs(walking) do
                    if not w.seated then
                        pcall(function()
                            local q = w.cat:K2_GetActorLocation()
                            parts[#parts + 1] = string.format("%.0f", math.sqrt((q.X - w.spot.X) ^ 2 + (q.Y - w.spot.Y) ^ 2))
                        end)
                    end
                end
                log("events: groups - walking in, %.0f s: still to go %s", waited, table.concat(parts, " "))
            end
            if left > 0 and waited < cfg.walkSeconds then
                ExecuteInGameThreadWithDelay(100, check)
                return
            end
            local arrived, short, snapped = 0, 0, 0
            for _, w in ipairs(walking) do
                if w.short then short = short + 1
                elseif w.seated then arrived = arrived + 1
                else seat(w, true) snapped = snapped + 1 end
            end
            log("events: groups - %d walked to their seats, %d walked most of the way (blocked, set down), %d set down after %.0f s",
                arrived, short, snapped, waited)
            done()
        end
        ExecuteInGameThreadWithDelay(500, check)
    end)
end

function Events.Release(ctx, done)
    local g = ctx and ctx.gathered
    if not (g and #g > 0) then
        if done then done() end
        return
    end
    fadeScreen(0, 1, FADE)
    ExecuteInGameThreadWithDelay(math.floor(FADE * 1000) + 100, function()
        putBack(g)
        pcall(function() stopMontage(pc().Pawn) end)
        ctx.gathered = nil
        log("events: release - the clanmates are back in their places")
        fadeScreen(1, 0, FADE)
        if done then ExecuteInGameThreadWithDelay(math.floor(FADE * 1000), done) end
    end)
end

-- --- the step runner ---

-- "Kind: value [@ who]" -> { kind, value, who }
function Events.Parse(line)
    local kind, rest = tostring(line):match("^%s*(%a+)%s*:%s*(.-)%s*$")
    -- (a step with nothing after it: "Release")
    if not kind then kind, rest = tostring(line):match("^%s*(%a+)%s*$"), "" end
    if not kind then return nil end
    local value, who = rest:match("^(.-)%s*@%s*(%S+)$")
    return { kind = kind, value = value or rest, who = who }
end

-- numbered lines of a config section: <Prefix>, <Prefix>1 ... <Prefix>9 -> steps
function Events.Lines(section, prefix)
    local out = {}
    if not section then return out end
    for _, key in ipairs({ prefix, prefix .. "1", prefix .. "2", prefix .. "3", prefix .. "4", prefix .. "5",
                           prefix .. "6", prefix .. "7", prefix .. "8", prefix .. "9" }) do
        local v = section[key]
        if v and v ~= "" then
            local s = Events.Parse(v)
            if s then table.insert(out, s) end
        end
    end
    return out
end

-- --- story variables ---

local vars = {}                  -- name -> number or text (kept with the save)
local providers = {}             -- built-in variables: name -> fn() (Day, Standing, Rank ...)

function Events.Provide(name, fn) providers[name] = fn end

function Events.Var(name)
    if providers[name] then
        local ok, v = pcall(providers[name])
        return ok and v or 0
    end
    local v = vars[name]
    if v == nil then return 0 end
    return v
end

function Events.SetVar(name, value)
    local n = tonumber(value)
    if n then value = n end
    if vars[name] == value then return end
    vars[name] = value
    log("events: %s = %s", name, tostring(value))
    WaCa.Emit("StoryVar", name, value)
end

local OPS = {
    ["="] = function(a, b) return a == b end, ["!="] = function(a, b) return a ~= b end,
    ["<"] = function(a, b) return a < b end, ["<="] = function(a, b) return a <= b end,
    [">"] = function(a, b) return a > b end, [">="] = function(a, b) return a >= b end,
}

-- "Var op value, Var op value" -> all hold (empty = true)
function Events.Check(text)
    for cond in tostring(text or ""):gmatch("[^,]+") do
        local name, op, value = cond:match("^%s*([%w%.%_]+)%s*([<>=!]+)%s*(.-)%s*$")
        if name and OPS[op] then
            local have, want = Events.Var(name), tonumber(value) or value
            if type(have) ~= type(want) then have, want = tostring(have), tostring(want) end
            local ok, r = pcall(OPS[op], have, want)
            if not (ok and r) then return false end
        elseif cond:match("%S") then
            log("events: can't read the condition '%s'", cond)
            return false
        end
    end
    return true
end

function Events.Hook(name, fn)
    hooks[name] = hooks[name] or {}
    table.insert(hooks[name], fn)
end

local function fill(text, ctx)
    return (tostring(text):gsub("{(%u+)}", function(k) return ctx and ctx[k] ~= nil and tostring(ctx[k]) or "{" .. k .. "}" end))
end

local function after(seconds, fn) ExecuteInGameThreadWithDelay(math.max(1, math.floor(seconds * 1000)), fn) end

local function fade(from, to, seconds)
    pcall(function()
        pc().PlayerCameraManager:StartCameraFade(from, to, seconds, { R = 0, G = 0, B = 0, A = 1 }, true, true)
    end)
end

-- the dialogue step's end (the sequencer's end / its screen closing - whichever first, once it started)
local function dialogueOver(why)
    local w = waiting
    if not (w and w.started) then return end
    waiting = nil
    log("events: the dialogue is over (%s)", why)
    w.done()
end

local function runStep(s, ctx, nextStep, stop)
    local k = s.kind
    if k == "Set" then
        local name, value = tostring(s.value):match("^%s*([%w%.%_]+)%s*=%s*(.-)%s*$")
        if name then Events.SetVar(name, value) end
        nextStep()
    elseif k == "Add" then
        local name, n = tostring(s.value):match("^%s*([%w%.%_]+)%s+([%-%+]?[%d%.]+)%s*$")
        if name then Events.SetVar(name, (tonumber(Events.Var(name)) or 0) + tonumber(n)) end
        nextStep()
    elseif k == "If" then
        if Events.Check(s.value) then nextStep() else stop() end
    elseif k == "Card" then
        showCard(fill(s.value, ctx), cfg.cardSeconds, nextStep)
    elseif k == "Gather" then
        Events.Gather(tonumber(s.value) or 5, s.who, ctx, nextStep)
    elseif k == "Groups" then
        Events.Groups(s.value, s.who, ctx, nextStep)
    elseif k == "Pose" then
        Events.Pose(s.value, s.who, ctx)
        nextStep()
    elseif k == "Release" then
        Events.Release(ctx, nextStep)
    elseif k == "Wait" then
        after(tonumber(s.value) or 1, nextStep)
    elseif k == "Fade" or k == "FadeIn" then
        local t = tonumber(s.value) or 1
        if k == "Fade" then fade(0, 1, t) else fade(1, 0, t) end
        after(t, nextStep)
    elseif k == "Bond" then
        local cat = Events.Who(s.who or "Nearest")
        -- (only a story cat has a role number; a generic clanmate's narrativeRole is not one - VM 2026-10-28)
        local role
        pcall(function() role = cat and cat.narrativeRole end)
        if type(role) ~= "number" then role = nil end
        local now = role and role > 0 and WaCaNative_AddBond and WaCaNative_AddBond(role, tonumber(s.value) or 1)
        log("events: bond +%s with %s%s", s.value, s.who or "Nearest", now and "" or " (not a story cat - no bond)")
        nextStep()
    elseif k == "Emit" then
        WaCa.Emit(s.value, ctx)
        nextStep()
    elseif k == "Hook" then
        local fns, i = hooks[s.value] or {}, 0
        local function nextHook()
            i = i + 1
            if i > #fns then return nextStep() end
            local ok, err = pcall(fns[i], ctx, nextHook)
            if not ok then
                log("events: hook %s failed (%s)", s.value, tostring(err))
                nextHook()
            end
        end
        nextHook()
    elseif k == "Dialogue" then
        local ok, err = pcall(function()
            local mgr = FindFirstOf("SwtQuestSequencerManager")
            local pawn = pc() and pc().Pawn
            local npc = Events.Who(s.who or "Nearest")
            if not (mgr and mgr:IsValid() and pawn and npc) then error("no sequencer manager / player / " .. tostring(s.who)) end
            gen = gen + 1
            local mine = gen
            waiting = { started = false, done = function() if mine == gen then nextStep() end end }
            mgr:PlaySequenceDialogue({ TagName = FName(s.value) }, npc, pawn, false, false)
            log("events: dialogue %s with %s", s.value, npc:GetFName():ToString())
            -- never started (a wrong id ...) / running far too long: on (a scene never blocks the loop)
            after(cfg.startWait, function()
                if waiting and mine == gen and not waiting.started then
                    log("events: dialogue %s never started - going on", s.value)
                    waiting = nil
                    nextStep()
                end
            end)
            after(cfg.dialogueMax, function()
                if waiting and mine == gen then
                    log("events: dialogue %s still running after %d s - going on", s.value, cfg.dialogueMax)
                    waiting = nil
                    nextStep()
                end
            end)
        end)
        if not ok then
            log("events: dialogue %s failed (%s)", tostring(s.value), tostring(err))
            nextStep()
        end
    else
        log("events: unknown step %s", tostring(k))
        nextStep()
    end
end

-- run the steps in order, then onDone - also when a step fails: a scene never blocks the loop
function Events.Run(steps, onDone, ctx)
    local i = 0
    local finished = false
    local function stop()
        if finished then return end
        finished = true
        if onDone then onDone() end
    end
    local function nextStep()
        if finished then return end
        i = i + 1
        local s = steps and steps[i]
        if not s then return stop() end
        if type(s) == "string" then s = Events.Parse(s) end
        if not s then return nextStep() end
        local ok, err = pcall(runStep, s, ctx, nextStep, stop)
        if not ok then
            log("events: step %d failed (%s)", i, tostring(err))
            nextStep()
        end
    end
    nextStep()
end

-- play a scene now (fire and forget): { card = text, dialogue = tag, seconds = n } or steps
function Events.Play(scene, onDone)
    local steps = {}
    if scene.card then table.insert(steps, { kind = "Card", value = scene.card }) end
    if scene.dialogue then table.insert(steps, { kind = "Dialogue", value = scene.dialogue, who = scene.who }) end
    for _, s in ipairs(scene) do table.insert(steps, s) end
    Events.Run(steps, onDone, scene.context)
end

-- --- hour-scheduled scenes (events.ini) ---

local function play(e, day)
    log("events: %s (day %d)", e.name, day)
    if e.once then done[e.name] = true end
    Events.Run(e.steps, nil, { DAY = day })
end

-- the scenes due at this hour of this day
local function due(hour, day)
    if WaCa.InMenu() then return end
    for _, e in ipairs(list) do
        local dayOk = (e.day and day == e.day) or (e.every and (day - (e.day or 1)) % e.every == 0 and day >= (e.day or 1))
            or (not e.day and not e.every)
        if dayOk and hour == e.hour and not done[e.name] then play(e, day) end
    end
end

-- the game's scripted conversations, for scene authors (from its own table - no game text in the mod)
local function listDialogues()
    if listed then return end
    listed = true
    pcall(function()
        local mgr = FindFirstOf("SwtQuestSequencerManager")
        local rows = {}
        mgr.DialoguesToUse:ForEachRow(function(name, row)
            local tag = "?"
            pcall(function() tag = row.SequenceDialogueId.TagName:ToString() end)
            table.insert(rows, tag)
        end)
        table.sort(rows)
        local f = io.open(modDir .. "/config/events-dialogues.txt", "w")
        if f then
            f:write("; the game's scripted conversations (Dialogue: <id> in scenes), listed from its own table\n")
            f:write(table.concat(rows, "\n") .. "\n")
            f:close()
        end
        log("events: %d dialogue ids listed in config/events-dialogues.txt", #rows)
    end)
end

local function sidecar() return WaCa.SlotFile("WaCaEvents") end

function Events.Init(c)
    WaCa, log, modDir, DayNight = c.WaCa, c.log, c.modDir, c.DayNight
    local ini = WaCa.ReadContent(modDir .. "/config/events.ini", "events") or {}
    local e = ini["Events"] or {}
    cfg.cardSeconds = tonumber(e.CardSeconds or "") or cfg.cardSeconds
    cfg.walkIn = (e.WalkIn or "1") ~= "0"
    cfg.walkFrom = tonumber(e.WalkFrom or "") or cfg.walkFrom
    cfg.walkSeconds = tonumber(e.WalkSeconds or "") or cfg.walkSeconds
    cfg.walkSpeed = tonumber(e.WalkSpeed or "") or cfg.walkSpeed
    log("events: %d tie(s) between clan cats (config/relations.ini)", readRelations(modDir))
    cfg.dialogueMax = tonumber(e.DialogueMaxSeconds or "") or cfg.dialogueMax
    -- the runner works with the hour schedule off too (the clan loop, the story): a dialogue's start and end from the
    -- game's sequencer (the WaCa events every mod can use) and its dialogue screens
    WaCa.On("DialogueStarted", function() if waiting then waiting.started = true end end)
    WaCa.On("SequenceStarted", function() if waiting then waiting.started = true end end)
    WaCa.On("SequenceFinished", function() dialogueOver("the sequence finished") end)
    WaCa.On("SequenceEnded", function() dialogueOver("the sequence ended") end)
    WaCa.On("ScreenShown", function(screen)
        local n = screen:GetClass():GetFName():ToString()
        if waiting and n:find("Dialog") then waiting.started = true end
        if n:find("^WBP_GuiHudGame") then listDialogues() end
    end)
    WaCa.On("ScreenHidden", function(screen)
        if waiting and screen:GetClass():GetFName():ToString():find("Dialog") then dialogueOver("its screen closed") end
    end)
    Events.Provide("Day", function() return DayNight and DayNight.Day() or 0 end)
    Events.Provide("Rank", function() return (WaCa.PlayerRank()) or 0 end)
    -- story variables live with the save (a sidecar, written when the game saves)
    local varsFor
    WaCa.On("GameSaved", function()
        local slot = WaCa.CurrentSlot()
        if slot and varsFor ~= slot then
            varsFor = slot
            vars = {}
            for k, v in pairs((WaCa.ReadIni(WaCa.SlotFile("WaCaStory") or "") or {})["Vars"] or {}) do
                if k ~= "__order" then vars[k] = tonumber(v) or v end
            end
        end
        local path = WaCa.SlotFile("WaCaStory")
        if path then
            local d = { __order = {} }
            for k, v in pairs(vars) do d[k] = tostring(v) table.insert(d.__order, k) end
            table.sort(d.__order)
            WaCa.WriteIni(path, { Vars = d, __order = { "Vars" } }, "; WaCa Clan Life - this save's story variables (events.lua)")
        end
    end)
    if (e.On or "0") ~= "1" then
        log("events: hour-scheduled scenes off (the runner is on)")
        return
    end
    for section, sec in pairs(ini) do
        local name = section:match("^Event%.(.+)$")
        if name and tonumber(sec.Hour or "") and sec.Off ~= "1" then
            local steps = {}
            if (sec.Card or "") ~= "" then table.insert(steps, { kind = "Card", value = sec.Card }) end
            if (sec.Dialogue or "") ~= "" then table.insert(steps, { kind = "Dialogue", value = sec.Dialogue }) end
            for _, s in ipairs(Events.Lines(sec, "Step")) do table.insert(steps, s) end
            table.insert(list, { name = name, day = tonumber(sec.Day or ""), every = tonumber(sec.Every or ""),
                hour = math.floor(tonumber(sec.Hour)), steps = steps, once = (sec.Once or "0") == "1" })
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    log("events: on (%d scenes)", #list)
    WaCa.On("HourChanged", function(hour, day) due(hour, day) end)
    -- one-time scenes played in this save: restored with the save, written when the game saves
    WaCa.On("GameSaved", function()
        local slot = WaCa.CurrentSlot()
        if slot and restoredFor ~= slot then
            restoredFor = slot
            done = {}
            for k, v in pairs((WaCa.ReadIni(sidecar() or "") or {})["Done"] or {}) do
                if k ~= "__order" and v == "1" then done[k] = true end
            end
        end
        local path = sidecar()
        if path then
            local d = { __order = {} }
            for k in pairs(done) do d[k] = "1" table.insert(d.__order, k) end
            WaCa.WriteIni(path, { Done = d, __order = { "Done" } }, "; WaCa Clan Life - one-time scenes played in this save (events.ini)")
        end
    end)
end

return Events
