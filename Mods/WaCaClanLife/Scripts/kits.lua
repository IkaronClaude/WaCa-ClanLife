-- KITS OF YOUR OWN (tickets.md 12, romance + kits - the groundwork, not the story: who can be a mate, the asking, when
-- kits come and how they grow up are the story's to decide). Kits.Born(mate[, count]) - your cat's kits with a clanmate:
-- each kit's look blended from the two parents' (WaCa Core's BlendLooks - each trait from one parent, a name of its
-- own), kit-sized; they live by your clan's NURSERY (the game's own den: the WrcHousingDoorActor titled Nursery of your
-- clan - its door in camp), placed there whenever the world is up. Kept with the save (a sidecar written when the
-- game saves, like the time of day) - a birth the game never saved is gone with that save, as anything else.
-- Other mods / a story: WaCa.Emit("HaveKits", mate[, count]); event KitsBorn(mate, names) after.
local Kits = {}

local WaCa, log
local cfg = { on = true, countMin = 1, countMax = 3, spread = 160 }
local kits = {}                 -- { name, look, mate, born (day) }
local spawned = {}              -- kit name -> actor path
local restoredFor = nil
local DayNight

local function sidecar() return WaCa.SlotFile("WaCaKits") end

local function pathOf(o) return (o:GetFullName():gsub("^%S+ ", "")) end

local function playerPawn()
    for _, c in ipairs(FindAllOf("SwtPlayerController") or {}) do
        if c:IsValid() and c.Player and c.Pawn and c.Pawn:IsValid() then return c.Pawn end
    end
end

-- the clan's nursery door in camp, and the way out of it (toward the camp's middle when known)
local function nursery()
    local clan = WaCa.PlayerClan and WaCa.PlayerClan() or nil
    local clans = {}
    pcall(function()
        StaticFindObject("/Script/SwtQuest.EClanType"):ForEachName(function(n, v) clans[v] = (n:ToString():gsub("^.*::", "")) end)
    end)
    for _, door in ipairs(FindAllOf("WrcHousingDoorActor") or {}) do
        local found
        pcall(function()
            if not door:IsValid() or door.bIsExit then return end
            if clan and clans[door.Clan] ~= clan then return end
            -- (the game's den name - STR_DEN_NURSERY; its English title "Nursery" as the fallback)
            local title = door.ActorTitle:ToString()
            if title == WaCa.GetText("STR_DEN_NURSERY") or title == "Nursery" then found = door:K2_GetActorLocation() end
        end)
        if found then return found end
    end
end

local function groundUnder(x, y, z)
    local k = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local hit, c0 = {}, { R = 0, G = 0, B = 0, A = 0 }
    local ctx = FindFirstOf("PlayerController")
    local ok, yes = pcall(function()
        return k:LineTraceSingleForObjects(ctx, { X = x, Y = y, Z = z + 150 }, { X = x, Y = y, Z = z - 600 }, { 0 }, false,
            {}, 0, hit, true, c0, c0, 0)
    end)
    if ok and yes then return hit.ImpactPoint.Z end
    return z
end

-- the kits by the nursery: a half ring in front of its door, facing the camp
local function place()
    if not cfg.on or #kits == 0 then return end
    local door = nursery()
    if not door then
        log("kits: no nursery of your clan in this world - the kits stay unseen")
        return
    end
    local out = { X = 0, Y = 1 }
    pcall(function()
        local mid = require("duties").Camp().middle
        local dx, dy = mid.X - door.X, mid.Y - door.Y
        local len = math.sqrt(dx * dx + dy * dy)
        if len > 1 then out = { X = dx / len, Y = dy / len } end
    end)
    local face = math.deg(math.atan(out.Y, out.X))
    local placed = {}
    for i, kit in ipairs(kits) do
        local a = spawned[kit.name] and StaticFindObject(spawned[kit.name])
        if not (a and a:IsValid()) then
            -- (a half ring in front of the door: kit 1 straight out, the others to its sides)
            local side = (i % 2 == 0) and 1 or -1
            local turn = math.floor(i / 2) * 0.6 * side
            local ox = out.X * math.cos(turn) - out.Y * math.sin(turn)
            local oy = out.X * math.sin(turn) + out.Y * math.cos(turn)
            local x, y = door.X + ox * cfg.spread, door.Y + oy * cfg.spread
            local z = groundUnder(x, y, door.Z)
            local _, _, scale = WaCa.BlendLooks(kit.look, kit.look)
            local cat = WaCa.SpawnCat(kit.look, { X = x, Y = y, Z = z }, face + (i - 1) * 25 * side, scale)
            if cat then
                spawned[kit.name] = pathOf(cat)
                placed[#placed + 1] = kit.name
            end
        end
    end
    if #placed > 0 then log("kits: %s by the nursery", table.concat(placed, ", ")) end
end

local function keep()
    local path = sidecar()
    -- (only over this slot's kits as read: a read that failed must never be saved over the kits it missed)
    if not path or restoredFor ~= WaCa.CurrentSlot() then return end
    local data = { __order = {} }
    for i, kit in ipairs(kits) do
        local key = "Kit" .. i
        data[key] = { Name = kit.name, Mate = kit.mate or "", Born = tostring(kit.born or 0), Look = kit.look,
                      __order = { "Name", "Mate", "Born", "Look" } }
        data.__order[#data.__order + 1] = key
    end
    WaCa.WriteIni(path, data, "; WaCa Clan Life - this save's own kits (kits.lua)")
end

local function restore()
    local slot = WaCa.CurrentSlot()
    if not slot or restoredFor == slot then return end
    restoredFor = slot
    for _, p in pairs(spawned) do
        local a = StaticFindObject(p)
        if a and a:IsValid() then WaCa.Despawn(a) end
    end
    spawned, kits = {}, {}
    -- (by number: the ini reader keeps no section order - VM 2026-11-01, read as none, then saved as none)
    local data = WaCa.ReadIni(sidecar() or "") or {}
    local i = 1
    while data["Kit" .. i] do
        local k = data["Kit" .. i]
        if (k.Look or "") ~= "" then
            kits[#kits + 1] = { name = k.Name, look = k.Look, mate = k.Mate, born = tonumber(k.Born or "") or 0 }
        end
        i = i + 1
    end
    if #kits > 0 then log("kits: %d of your own in this save", #kits) end
end

-- the mate's look: the clanmate in the world by name, else the save's story cat of that name
local function lookOfMate(mate)
    for _, a in ipairs(FindAllOf("SwtAdventureQuestActor") or {}) do
        local look
        pcall(function() if a:IsValid() and WaCa.CatName(a) == mate then look = WaCa.LookOf(a) end end)
        if look then return look end
    end
    for _, c in ipairs(WaCa.StoryCats()) do
        if c.name == mate then return c.look end
    end
end

function Kits.List() return kits end

-- your cat's kits with mate (a clanmate's name): count of them (else Count's range) - returns their names
function Kits.Born(mate, count)
    local mine = WaCa.LookOf(playerPawn())
    local theirs = mate and lookOfMate(mate)
    if not (mine and theirs) then
        log("kits: no look for %s - no kits", not mine and "your cat" or tostring(mate))
        return {}
    end
    count = math.max(1, math.floor(tonumber(count) or math.random(cfg.countMin, cfg.countMax)))
    local used = {}
    for _, k in ipairs(kits) do used[k.name] = true end
    local names = {}
    for _ = 1, count do
        -- (a name no kit of this save has: BlendLooks picks a prefix at random - a few tries)
        for _ = 1, 12 do
            local look, name = WaCa.BlendLooks(mine, theirs)
            if name and name ~= "" and not used[name] then
                used[name] = true
                kits[#kits + 1] = { name = name, look = look, mate = mate,
                                    born = DayNight and DayNight.Day and DayNight.Day() or 0 }
                names[#names + 1] = name
                break
            end
        end
    end
    log("kits: %d born to your cat and %s - %s", #names, mate, table.concat(names, ", "))
    place()
    WaCa.Emit("KitsBorn", mate, table.concat(names, ","))
    return names
end

function Kits.Init(c)
    WaCa, log, DayNight = c.WaCa, c.log, c.DayNight
    local ini = WaCa.ReadContent(c.modDir .. "/config/kits.ini", "kits") or {}
    local k = ini["Kits"] or {}
    cfg.on = c.part("Kits", k.On)
    local lo, hi = (k.Count or ""):match("^%s*(%d+)%s*%-%s*(%d+)%s*$")
    if lo then cfg.countMin, cfg.countMax = tonumber(lo), math.max(tonumber(lo), tonumber(hi))
    elseif tonumber(k.Count or "") then cfg.countMin, cfg.countMax = tonumber(k.Count), tonumber(k.Count) end
    cfg.spread = tonumber(k.Spread or "") or cfg.spread
    log("kits: %s (%d-%d a litter, by the nursery)", cfg.on and "on" or "off", cfg.countMin, cfg.countMax)
    if not cfg.on then return end
    WaCa.On("HaveKits", function(mate, count)
        ExecuteInGameThread(function()
            local ok, err = pcall(Kits.Born, mate, count)
            if not ok then log("kits: the birth failed (%s)", tostring(err)) end
        end)
    end)
    WaCa.On("GameSaved", function()
        restore()
        keep()
    end)
    WaCa.On("ScreenShown", function(screen)
        local ok, hud = pcall(function() return screen:GetClass():GetFName():ToString():find("^WBP_GuiHudGame") ~= nil end)
        if not (ok and hud) then return end
        ExecuteInGameThreadWithDelay(3000, function()
            pcall(restore)
            pcall(place)
        end)
    end)
end

return Kits
