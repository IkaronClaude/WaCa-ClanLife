-- THE CAMP'S WALKING CATS ARE ITS NAMED CATS (operator 2026-10-29: "there are some unnamed cats walking around camp,
-- I'd like to ensure that they are the same as named cat and any named cat can, at times, walk around like that
-- (unless they're super important key characters / shops / etc.)").
-- The game walks a few nameless cats round each camp (BP_WalkingNPC_Character_Base_C, its AI on paths) beside the
-- camp's named cats (its quest cats, placed - most of them parked). Each third of the day the walkers wear named cats
-- in turn: a walker takes a named cat's look and name (its FCatCustomData, the look rebuilt), and that cat's placed
-- self is hidden meanwhile - nobody is ever twice in camp. Whose turn: the ones that walked longest ago first; the
-- story's lever: the story variable Walk:<Name> - 1 they walk at the next turn, -1 never (config/walkers.ini Never
-- too).
-- Never the key cats: story characters (TheAgingLeader, Cloudtail ...), the clan's offices (leader, deputy, medicine
-- cat), its services (gossip, fresh-kill, the move teacher, side quests, skirmish, online friends, races,
-- deliveries), queens and kits, StarClan. Only cats with no story part (the fillers) or a plain <Clan>Warrior /
-- <Clan>Elder / <Clan>Apprentice part.
local Walkers = {}

local WaCa, log, Events
local cfg = { on = false, never = {} }
local wearing = {}          -- walker path -> { named = named cat path, name = text, hidden = { was hidden, collision } }
local lastWalked = {}       -- named cat name -> the turn it last walked
local turn = 0
local waiting = false

local CUSTOM_KEYS = {
    "ClanType", "Role", "CombatStats", "BodyOffset", "FaceOffset", "FurOffset", "TailOffset", "EarOffset", "EyeOffset",
    "WhiskerOffset", "BodyValue", "FaceValue", "FurValue", "EyeValue", "WhiskerValue", "TailIdx", "EarIdx", "FurIdx",
    "FurColorIdx", "Pattern01ColorIdx", "Pattern02ColorIdx", "PatternIdx", "MarkingIdx", "EyeLeftColorIdx",
    "EyeRightColorIdx", "bOverrideColors", "Design", "PrefixNameId", "SuffixNameId", "Gender", "CatSize",
    "AccesoryNeckId", "AccesoryPawId", "AccesoryHeadId", "AccesoryBodyId", "AccesoryNeckVar", "AccesoryPawVar",
    "AccesoryHeadVar", "AccesoryBodyVar", "ScarEyeId", "ScarEarId", "ScarBodyId", "ScarChestId",
}

local function enumName(path, value, cache)
    if not cache[1] then
        cache[1] = {}
        pcall(function()
            StaticFindObject(path):ForEachName(function(n, v) cache[1][v] = n:ToString():gsub("^.*::", "") end)
        end)
    end
    return cache[1][value]
end
local roleCache, clanCache = {}, {}

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

-- may this named cat walk? (the rules above)
local function mayWalk(a, myClan)
    local role = enumName("/Script/SwtQuest.ENarrativeRole", a.narrativeRole, roleCache) or ""
    local plain = role == "None" or role == "" or role:match("^%a+Clan(Warrior)$") or role:match("^%a+Clan(Elder)$")
        or role:match("^%a+Clan(Apprentice)$")
    if not plain then return false, role end
    local clan = enumName("/Script/SwtQuest.EClanType", a.ClanType, clanCache)
    if myClan and clan and clan ~= myClan then return false, "clan " .. tostring(clan) end
    local name = nameOf(a)
    if not name then return false, "no name" end
    if cfg.never[name] or storyVar("Walk:" .. name) <= -1 then return false, "kept home (Never / Walk = -1)" end
    return true, role, name
end

local function copyLook(from, to)
    local src, dst = from.MeshCustomizationComponent.CustomData, to.MeshCustomizationComponent.CustomData
    for _, k in ipairs(CUSTOM_KEYS) do
        pcall(function()
            local v = src[k]
            if type(v) == "userdata" and v.ToString then v = v:ToString() end
            dst[k] = v
        end)
    end
    return WaCa.RebuildLook(to.MeshCustomizationComponent)
end

local function hide(a, on, was)
    pcall(function()
        if on then
            was = { hidden = a.bHidden, collision = a:GetActorEnableCollision() }
            a:SetActorHiddenInGame(true)
            a:SetActorEnableCollision(false)
        else
            a:SetActorHiddenInGame(was and was.hidden or false)
            a:SetActorEnableCollision(was == nil or was.collision ~= false)
        end
    end)
    return was
end

-- a turn: every walker wears the named cat whose turn it is
local generation = 0       -- a newer turn cancels a deferred older one (they ran back to back: VM 2026-10-29)

function Walkers.Turn(why, gen)
    if not cfg.on then return end
    if gen and gen ~= generation then return end
    -- (not while a scene has cats staged - the meal, sharing tongues: the turn comes once they're let go)
    local okS, busy = pcall(function() return Events.Staging() end)
    if okS and busy then
        if not waiting then log("walkers: the turn (%s) waits - a scene is on", tostring(why)) end
        waiting = true
        if not gen then generation = generation + 1 end
        local mine = generation
        ExecuteInGameThreadWithDelay(10000, function() pcall(Walkers.Turn, why, mine) end)
        return
    end
    waiting = false
    generation = generation + 1
    local myClan = WaCa.PlayerClan and WaCa.PlayerClan() or nil
    local walkers = {}
    for _, c in ipairs(FindAllOf("SwtAdventureWalkingNPC") or {}) do
        pcall(function() if c:IsValid() and c.MeshCustomizationComponent:IsValid() then walkers[#walkers + 1] = c end end)
    end
    if #walkers == 0 then return end
    -- the named cats that may walk, by name
    local named, kept = {}, 0
    local seen = {}
    for _, a in ipairs(FindAllOf("SwtAdventureQuestActor") or {}) do
        pcall(function()
            if not (a:IsValid() and a.MeshCustomizationComponent:IsValid()) then return end
            local ok, why2, name = mayWalk(a, myClan)
            if ok and not seen[name] then
                seen[name] = true
                named[#named + 1] = { actor = a, name = name, path = pathOf(a) }
            elseif not ok then
                kept = kept + 1
            end
        end)
    end
    -- the cats walking now go back home first
    for path, w in pairs(wearing) do
        local a = StaticFindObject(w.named)
        if a and a:IsValid() then hide(a, false, w.hidden) end
        wearing[path] = nil
    end
    if #named == 0 then
        log("walkers: no named cat of your clan may walk (%d kept home)", kept)
        return
    end
    -- whose turn: Walk = 1 first, then the ones that walked longest ago (never = first), then by name
    turn = turn + 1
    table.sort(named, function(x, y)
        local fx, fy = storyVar("Walk:" .. x.name) >= 1, storyVar("Walk:" .. y.name) >= 1
        if fx ~= fy then return fx end
        local lx, ly = lastWalked[x.name] or 0, lastWalked[y.name] or 0
        if lx ~= ly then return lx < ly end
        return x.name < y.name
    end)
    local lines = {}
    for i, c in ipairs(walkers) do
        local n = named[i]
        if not n then break end
        local ok, err = pcall(function()
            local rebuilt = copyLook(n.actor, c)
            local was = hide(n.actor, true)
            wearing[pathOf(c)] = { named = n.path, name = n.name, hidden = was }
            lastWalked[n.name] = turn
            lines[#lines + 1] = n.name .. (rebuilt and "" or " (look not rebuilt)")
        end)
        if not ok then log("walkers: %s couldn't take a walker (%s)", n.name, tostring(err)) end
    end
    log("walkers: turn %d (%s) - %d walking: %s; %d named cats may walk, %d kept home", turn, why or "?", #lines,
        table.concat(lines, ", "), #named, kept)
    WaCa.Emit("CampWalkersChanged", turn)
end

function Walkers.On() return cfg.on end

function Walkers.Init(c)
    WaCa, log, Events = c.WaCa, c.log, c.Events
    local ini = WaCa.ReadContent(c.modDir .. "/config/walkers.ini", "walkers") or {}
    local w = ini["Walkers"] or {}
    cfg.on = c.part("Walkers", w.On)
    for name in (w.Never or ""):gmatch("[^,]+") do
        name = name:match("^%s*(.-)%s*$")
        if name ~= "" then cfg.never[name] = true end
    end
    log("walkers: %s", cfg.on and "on - the camp's walking cats are its named cats, in turns" or "off")
    if not cfg.on then return end
    -- a turn once the world is up (its walkers spawned), and at every third of the clan's day
    local upFor
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
