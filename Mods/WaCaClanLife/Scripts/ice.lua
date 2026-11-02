-- FROZEN WATER IN LEAF-BARE (tickets.md, operator 2026-10-31: "let the lake and / or some parts of the river freeze,
-- changing the terrain that can be walked"). The game's water is flat planes (MI_WC_Water_*) with no collision; in
-- leaf-bare the chosen ones become ice: solid to cats (the lake too - its mesh made to collide on its own triangles) (the Pawn channel blocked - VM: the cat stands on the surface,
-- not the riverbed 2.5 m below) and frozen to look at (their own water material, still: no flow, no ripples, pale and
-- nearly opaque, frost-white foam at the edges). Which: weather.ini [Ice] Lake = 1 (the big lake surfaces), River = %
-- of the river planes - the same stretches every winter (picked by the plane, not by chance). Thawed again when the
-- season turns. Events: IceFrozen(n) / IceThawed(n); other mods: WaCa.Emit("Freeze", true / false).
local Ice = {}

local WaCa, log
local cfg = { on = true, season = "Leaf-bare", lake = true, river = 50, lakeSize = 10000, thin = 15, thinSteps = 6,
              refreeze = 60, crackLine = "The ice cracks beneath your paws!" }
local frozen = {}                   -- plane path -> { material = path, collision = int }
local isFrozen = false
local forced                        -- true / false: frozen / thawed whatever the season (a story, another mod)
local ICE_SCALARS = {
    ["Opacity"] = 0.85, ["Global Translucency"] = 0.5, ["Roughness"] = 0.35, ["Normal Overall Speed"] = 0,
    ["Dots Overall Speed"] = 0, ["Foam Distortion Overall Speed"] = 0, ["Foam Speed"] = 0, ["Foam DF Texture Speed"] = 0,
    ["Ripples Speed"] = 0, ["Ripple Count"] = 0, ["Caustic Strength"] = 0, ["Foam Opacity"] = 0.6, ["Speed S"] = 0,
    ["Normal Intensity"] = 0.03, ["sparks emissive intensity"] = 2000,
}
local ICE_VECTORS = {
    ["Absorption"] = { R = 0.55, G = 0.68, B = 0.78, A = 1 }, ["Foam Color"] = { R = 0.85, G = 0.9, B = 0.95, A = 1 },
}

local function pathOf(o) return (o:GetFullName():gsub("^%S+ ", "")) end

-- can this water surface carry a cat once solid? (its mesh has simple shapes, or uses its own triangles as collision -
-- the river pieces; the map-wide lake plane has neither: VM 2026-10-31, a cat sank through it)
local function walkable(c)
    local ok, yes = pcall(function()
        local b = c.StaticMesh.BodySetup
        local a = b.AggGeom
        local n = #a.BoxElems + #a.ConvexElems + #a.SphylElems + #a.SphereElems
        return n > 0 or b.CollisionTraceFlag == 3
    end)
    return ok and yes
end

-- A SURFACE THAT CAN'T CARRY A CAT (the lake - one map-wide plane with only its triangles, no simple shapes): its mesh
-- is told to collide on its own triangles while frozen (BodySetup CollisionTraceFlag 3, the body rebuilt by switching
-- collision off and on - not by swapping the mesh: SetStaticMesh(nil) crashed the game). VM 2026-10-31: the cat stands
-- on the lake at its surface. The mesh's own setting comes back with the thaw.
local traceFlags = {}               -- mesh path -> its CollisionTraceFlag before
local function solidify(c)
    local sm = c.StaticMesh
    local key = pathOf(sm)
    if traceFlags[key] == nil then traceFlags[key] = sm.BodySetup.CollisionTraceFlag end
    sm.BodySetup.CollisionTraceFlag = 3
    c:SetCollisionEnabled(0)
end
local function unsolidify(c)
    pcall(function()
        local sm = c.StaticMesh
        local was = traceFlags[pathOf(sm)]
        if was ~= nil then sm.BodySetup.CollisionTraceFlag = was end
    end)
end

-- a stable pick per plane: the same river stretches freeze every winter
local function picked(path, percent)
    local h = 0
    for i = 1, #path do h = (h * 31 + path:byte(i)) % 1000003 end
    return (h % 100) < percent
end

local function waterPlanes()
    local out = {}
    local k = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    for _, c in ipairs(FindAllOf("StaticMeshComponent") or {}) do
        pcall(function()
            if not c:IsValid() then return end
            local m = c:GetMaterial(0)
            local name = m and m:IsValid() and m:GetFName():ToString() or ""
            if not name:find("^MI_WC_Water") and not (frozen[pathOf(c)]) then return end
            local o, e, r = {}, {}, {}
            k:GetComponentBounds(c, o, e, r)
            out[#out + 1] = { comp = c, path = pathOf(c), lake = math.max(e.X, e.Y) >= cfg.lakeSize, flat = e.Z < 120,
                              walkable = walkable(c) }
        end)
    end
    return out
end

local function freezeOne(p)
    local c = p.comp
    local ok = pcall(function()
        local m = c:GetMaterial(0)
        frozen[p.path] = { material = pathOf(m), collision = c:GetCollisionEnabled() }
        local mid = c:CreateDynamicMaterialInstance(0, m, FName("WaCaIce"))
        for k, v in pairs(ICE_SCALARS) do mid:SetScalarParameterValue(FName(k), v) end
        for k, v in pairs(ICE_VECTORS) do mid:SetVectorParameterValue(FName(k), v) end
        if not p.walkable then solidify(c) end                    -- (the lake: its own triangles carry the cat)
        c:SetCollisionEnabled(0)
        c:SetCollisionResponseToAllChannels(0)
        c:SetCollisionResponseToChannel(2, 2)                      -- (the Pawn channel: blocked - cats walk on it)
        c:SetCollisionEnabled(3)                                   -- (query and physics - the body built now)
    end)
    return ok
end

local function thawOne(path, was)
    local c = StaticFindObject(path)
    if not (c and c:IsValid()) then return false end
    return pcall(function()
        local m = StaticFindObject(was.material)
        if m and m:IsValid() then c:SetMaterial(0, m) end
        unsolidify(c)
        c:SetCollisionEnabled(0)
        c:SetCollisionResponseToChannel(2, 0)
        c:SetCollisionEnabled(was.collision or 0)
    end)
end

-- the player's cat, and the frozen plane it stands on (its path) if any
local function playerOn()
    local pawn
    for _, c in ipairs(FindAllOf("SwtPlayerController") or {}) do
        pcall(function() if c:IsValid() and c.Player and c.Pawn and c.Pawn:IsValid() then pawn = c.Pawn end end)
    end
    if not pawn then return nil end
    local on
    pcall(function()
        local comp = pawn.CharacterMovement.CurrentFloor.HitResult.Component
        if tostring(comp):match("^FWeakObjectPtr") then comp = comp:Get() end
        if comp and comp:IsValid() and frozen[pathOf(comp)] then on = pathOf(comp) end
    end)
    return pawn, on
end

-- ground under the cat's feet (through the ice), within 20 m - nil over a hole in the world
local function groundBelow(pawn)
    local z
    pcall(function()
        local k = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        local p = pawn:K2_GetActorLocation()
        local feet = p.Z - pawn.CapsuleComponent:GetScaledCapsuleHalfHeight()
        local hit = {}
        local ok, yes = pcall(function()
            return k:LineTraceSingleForObjects(pawn, { X = p.X, Y = p.Y, Z = feet - 10 }, { X = p.X, Y = p.Y, Z = feet - 2000 }, { 0 },
                false, { pawn }, 0, hit, true, { R = 0, G = 0, B = 0, A = 0 }, { R = 0, G = 0, B = 0, A = 0 }, 0)
        end)
        if ok and yes then z = hit.ImpactPoint.Z end
    end)
    return z
end

-- freeze what the season and [Ice] say (again when new stretches stream in), or thaw all
function Ice.Apply(why)
    local season
    pcall(function() season = require("weather").Season() end)
    -- (not "forced ~= nil and forced or ...": a forced false fell through to the season - VM 2026-10-31)
    local want
    if forced ~= nil then want = forced else want = season == cfg.season end
    want = cfg.on and want
    if want then
        local n, lakes, rivers = 0, 0, 0
        for _, p in ipairs(waterPlanes()) do
            if not frozen[p.path] and p.flat and ((p.lake and cfg.lake) or (not p.lake and picked(p.path, cfg.river))) then
                if freezeOne(p) then
                    n = n + 1
                    if not Ice.sample and not p.lake then Ice.sample = p.path end
                    if p.lake then lakes = lakes + 1 else rivers = rivers + 1 end
                end
            end
        end
        if n > 0 or not isFrozen then
            log("ice: %d water surface(s) frozen (%d lake, %d river; %s)", n, lakes, rivers, why)
            WaCa.Emit("IceFrozen", n)
        end
        isFrozen = true
    elseif isFrozen then
        -- (the ice under your cat: through it onto the bed when there is ground below - else it holds till the cat
        -- steps off: water can lie over a hole in the world, VM 2026-10-31)
        local pawn, on = playerOn()
        local keep
        if on and not groundBelow(pawn) then keep = on end
        local n = 0
        for path, was in pairs(frozen) do
            if path ~= keep and thawOne(path, was) then n = n + 1 frozen[path] = nil end
        end
        isFrozen = keep ~= nil
        if n > 0 or keep ~= Ice.held then
            log("ice: %d water surface(s) thawed (%s)%s", n, why, keep and " - the ice under your cat holds (no ground below)" or "")
            WaCa.Emit("IceThawed", n)
        end
        Ice.held = keep
        if keep then
            ExecuteInGameThreadWithDelay(5000, function() if not isFrozen or forced or false then return end Ice.Apply("the cat stepped off") end)
        end
    end
end

function Ice.Frozen() return isFrozen end

-- THIN ICE (the operator's "falling through ice"): ThinChance % of the frozen river stretches are thin - the same
-- ones every winter. ThinSteps footsteps on one and it gives way under the cat: that stretch is water again, the cat
-- drops in (wading takes over), a line on screen; it freezes over again after Refreeze seconds. Only where there is
-- ground below (never over a hole). Event FellThroughIce(stretch path) - a story's rescue / injury scene goes there.
local onThin = { path = nil, steps = 0 }
local cracked = {}
local function onStep(_, mesh)
    if not isFrozen or cfg.thin <= 0 then return end
    local pawn, on = playerOn()
    if not (pawn and mesh and mesh:IsValid()) then return end
    local ok, mine = pcall(function() return (WaCa.Live(mesh:GetOwner()) or error("no owner")):GetAddress() == pawn:GetAddress() end)
    if not (ok and mine) then return end
    if not on or cracked[on] or not picked(on .. "#thin", cfg.thin) then
        onThin.path, onThin.steps = nil, 0
        return
    end
    if onThin.path ~= on then onThin.path, onThin.steps = on, 0 end
    onThin.steps = onThin.steps + 1
    if onThin.steps < cfg.thinSteps or not groundBelow(pawn) then return end
    -- (it gives way)
    local c = StaticFindObject(on)
    if not (c and c:IsValid()) then return end
    pcall(function() c:SetCollisionResponseToChannel(2, 0) end)
    cracked[on] = true
    onThin.path, onThin.steps = nil, 0
    local where = on
    pcall(function() where = (WaCa.Live(c:GetOwner()) or error("no owner")):GetFName():ToString() end)
    log("ice: the thin ice gives way under your cat - %s", where)
    WaCa.Emit("ShowLine", cfg.crackLine, 4)
    WaCa.Emit("FellThroughIce", on)
    ExecuteInGameThreadWithDelay(math.floor(cfg.refreeze * 1000), function()
        cracked[on] = nil
        local again = StaticFindObject(on)
        if isFrozen and frozen[on] and again and again:IsValid() then
            pcall(function() again:SetCollisionResponseToChannel(2, 2) end)
            log("ice: the hole froze over again")
        end
    end)
end

function Ice.Init(c)
    WaCa, log = c.WaCa, c.log
    local ini = WaCa.ReadContent(c.modDir .. "/config/weather.ini", "weather") or {}
    local s = ini["Ice"] or {}
    cfg.on = c.part("Ice", s.On)
    cfg.season = (s.Season or "") ~= "" and s.Season or cfg.season
    cfg.lake = (s.Lake or "1") ~= "0"
    cfg.river = math.max(0, math.min(100, tonumber(s.River or "") or cfg.river))
    log("ice: %s (in %s: the lake %s, %d%% of the river)", cfg.on and "on" or "off", cfg.season, cfg.lake and "freezes" or "stays open",
        cfg.river)
    cfg.thin = math.max(0, math.min(100, tonumber(s.ThinChance or "") or cfg.thin))
    cfg.thinSteps = math.max(1, tonumber(s.ThinSteps or "") or cfg.thinSteps)
    cfg.refreeze = math.max(5, tonumber(s.Refreeze or "") or cfg.refreeze)
    cfg.crackLine = (s.CrackLine or "") ~= "" and s.CrackLine or cfg.crackLine
    if not cfg.on then return end
    WaCa.On("CatStep", onStep)
    WaCa.On("SeasonChanged", function() ExecuteInGameThread(function() Ice.Apply("the season turned") end) end)
    WaCa.On("HourChanged", function() if isFrozen then ExecuteInGameThread(function() Ice.Apply("new stretches about") end) end end)
    WaCa.On("ScreenShown", function(screen)
        local ok, cls = pcall(function() return screen:GetClass():GetFName():ToString() end)
        if ok and cls:find("^WBP_GuiHudGame") then ExecuteInGameThreadWithDelay(3000, function() Ice.Apply("the world is up") end) end
    end)
    -- (other mods / a story: freeze or thaw now - WaCa.Emit("Freeze", true / false / nil = the season's)
    WaCa.On("Freeze", function(on)
        if on == nil or on == "" then forced = nil else forced = (on == true or on == 1 or on == "1") end
        ExecuteInGameThread(function() Ice.Apply("asked") end)
    end)
end

return Ice
