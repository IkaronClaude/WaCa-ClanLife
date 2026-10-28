-- Prey follows the world (tickets.md 22): how much of each prey kind is around depends on the season - leaf-bare has
-- few mice and almost no squirrels (they keep to their nests), greenleaf is full of them. config/weather.ini
-- [Season.<Name>] Prey = Mice=0.7, Squirrel=0.2, ... (the share of each kind that is about; 1 = all, the default).
-- The game's generators keep spawning their prey as before; each roaming prey (BP_Exploration_Character_Base_C of a
-- prey kind) is rolled once per season when it appears or the season changes: an absent one is hidden, can't be
-- touched and its AI rests - never destroyed, so the generators don't respawn it over and over - and comes back
-- when a later season's roll has it about. Prey also comes and goes during the day (tickets.md 23, the "random times"
-- part): every in-game hour a share of the creatures (PreyTurnover) roll again, so a spot empty in the morning may
-- have a mouse by noon - and a creature coming back appears at a random point of its home generator's area
-- (PreyRandomPlaces), not where it vanished.
local PreyWorld = {}

local WaCa, log, Weather
local abundance = {}             -- season -> { kind name -> share 0..1 }
local kinds                      -- ESwtQuestCharacterType value -> kind name (Weak* folded into its kind)
local rolled = {}                -- creature full name -> { season = s, about = bool }
local hidden = 0
local turnover = 0               -- share of creatures re-rolled each in-game hour
local randomPlaces = false      -- a creature coming back appears somewhere else in its area (PreyRandomPlaces)
local moved = 0

local function kindNames()
    if kinds then return kinds end
    kinds = {}
    pcall(function()
        StaticFindObject("/Script/SwtQuest.ESwtQuestCharacterType"):ForEachName(function(name, value)
            kinds[value] = (name:ToString():gsub("^.*::", ""):gsub("^Weak", ""))
        end)
    end)
    return kinds
end

-- "Mice=0.7, Squirrel=0.2" -> { Mice = 0.7, Squirrel = 0.2 }
local function shares(s)
    local out = {}
    for name, v in (s or ""):gmatch("([%w_]+)%s*=%s*([%d%.]+)") do out[name] = math.max(0, math.min(1, tonumber(v))) end
    return out
end

local function setAbout(creature, about)
    creature:SetActorHiddenInGame(not about)
    creature:SetActorEnableCollision(about)
    pcall(function()
        local brain = creature.Controller and creature.Controller:IsValid() and creature.Controller.BrainComponent
        if brain and brain:IsValid() then
            if about then brain:RestartLogic() else brain:StopLogic("WaCa: not this season") end
        end
    end)
end

-- a random point in the area of the generator nearest to the creature (its home: generators keep their prey near),
-- dropped from a little above so it lands on the ground
local function newPlace(creature)
    local at = creature:K2_GetActorLocation()
    local best, bestD
    for _, g in ipairs(FindAllOf("BP_Enemy_Generator_C") or {}) do
        if g:IsValid() then
            local p = g:K2_GetActorLocation()
            local d = (p.X - at.X) ^ 2 + (p.Y - at.Y) ^ 2
            if not bestD or d < bestD then best, bestD = g, d end
        end
    end
    if not best then return end
    local area = best.AreaComponent
    local c, e = area:K2_GetComponentLocation(), area:GetScaledBoxExtent()
    local x = c.X + (math.random() * 2 - 1) * e.X
    local y = c.Y + (math.random() * 2 - 1) * e.Y
    creature:K2_SetActorLocation({ X = x, Y = y, Z = math.max(at.Z, c.Z) + 150 }, false, {}, true)
    moved = moved + 1
end

-- roll (once per season) whether this creature is about, and show / hide it
local function apply(creature, reroll)
    local season = Weather.Season()
    local share = season and abundance[season] or nil
    local kind = kindNames()[creature.CharacterType]
    if not kind then return end
    local key = creature:GetFullName() .. "@" .. tostring(creature:GetAddress())   -- names get reused by new actors
    local r = rolled[key]
    local want = (share and share[kind]) or 1
    if r and r.season == season and not reroll then return end
    local about = want >= 1 or math.random() < want
    local was = r == nil or r.about
    rolled[key] = { season = season, about = about }
    if about ~= was then
        if about and randomPlaces then pcall(newPlace, creature) end
        setAbout(creature, about)
        hidden = hidden + (about and -1 or 1)
    end
end

local function applyAll(why, share)
    local n = 0
    for _, c in ipairs(FindAllOf("BP_Exploration_Character_Base_C") or {}) do
        if c:IsValid() and (not share or math.random() < share) then
            local ok = pcall(apply, c, share ~= nil)
            if ok then n = n + 1 end
        end
    end
    log("prey: %s - %d creatures checked, %d of them away this season (%d came back elsewhere so far)", why, n, hidden, moved)
end

function PreyWorld.Init(c)
    WaCa, log, Weather = c.WaCa, c.log, c.Weather
    local ini = WaCa.ReadIni(c.modDir .. "/config/weather.ini") or {}
    if ((ini["Seasons"] or {}).On or "0") ~= "1" then return end
    turnover = math.max(0, math.min(1, tonumber((ini["Seasons"] or {}).PreyTurnover or "") or 0.2))
    randomPlaces = ((ini["Seasons"] or {}).PreyRandomPlaces or "1") == "1"
    local any = false
    for section, sec in pairs(ini) do
        local season = section:match("^Season%.(.+)$")
        if season and (sec.Prey or "") ~= "" then
            abundance[season] = shares(sec.Prey)
            any = true
        end
    end
    if not any then return end
    WaCa.On("SeasonChanged", function() applyAll("a new season") end)
    if turnover > 0 then WaCa.On("HourChanged", function() applyAll("prey comes and goes", turnover) end) end
    WaCa.On("ScreenShown", function(screen)
        if screen:GetClass():GetFName():ToString():find("^WBP_GuiHudGame") then applyAll("the world is up") end
    end)
    -- prey the generators spawn later (respawns, new areas)
    WaCa.Watch("ReceiveBeginPlay",
        "/Game/Gameplay/Blueprints/Characters/ExplorationCharacters/BP_Exploration_Character_Base.BP_Exploration_Character_Base_C",
        "WaCaCreatureSpawned", "post")
    WaCa.On("WaCaCreatureSpawned", function(creature)
        local ok, err = pcall(apply, creature)
        if not ok then log("prey: a new creature couldn't be checked (%s)", tostring(err)) end
    end)
    log("prey: abundance by season on")
end

return PreyWorld
