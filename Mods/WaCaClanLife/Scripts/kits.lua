-- KITS OF YOUR OWN (tickets.md 12, romance + kits - the groundwork, not the story: who can be a mate, the asking, when
-- kits come and how they grow up are the story's to decide). Kits.Born(mate[, count]) - your cat's kits with a clanmate:
-- each kit's look blended from the two parents' (WaCa Core's BlendLooks - each trait from one parent, a name of its
-- own), kit-sized; they live by your clan's NURSERY (the game's own den: the WrcHousingDoorActor titled Nursery of your
-- clan - its door in camp), placed there whenever the world is up. Kept with the save (a sidecar written when the
-- game saves, like the time of day) - a birth the game never saved is gone with that save, as anything else.
-- Other mods / a story: WaCa.Emit("HaveKits", mate[, count]); event KitsBorn(mate, names) after.
-- A NEWCOMER (library exercise 2026-11-03: a pack could rename / restyle a cat of the save, never bring a new one in):
-- WaCa.Emit("Newcomer", "<a clanmate's name>") - a grown cat that takes after that clanmate (its look blended with
-- itself: each trait from it, a new prefix from the game's own unused ones, the clanmate's suffix and rank), full size,
-- placed about the camp's middle, kept with the save like the kits; event NewcomerJoined(name, like) after. Works with
-- [Kits] On = 0 (that switch is for births).
local Kits = {}

local WaCa, log
local cfg = { on = true, countMin = 1, countMax = 3, spread = 160, apprenticeAfter = 0, apprenticeScale = 0.8, newcomerRing = 500 }
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

-- TALKING TO THEM (operator 2026-11-04: Nightkit said a line walking past but couldn't be talked to): the game's
-- Interact prompt at each kit / newcomer (WaCa Core's InteractSpot); interacting, it meows and says its next line -
-- lines.ini [Talk.Kit] for kits (Who = their rank: Kit, Apprentice), [Talk.Newcomer] for newcomers; {PLAYER} {NAME}
local talkSpots = {}            -- kit name -> its interact spot
local function talkTo(name)
    local kit
    for _, k in ipairs(kits) do if k.name == name then kit = k end end
    if not kit then return end
    local section = kit.adult and "Talk.Newcomer" or "Talk.Kit"
    local ini = WaCa.ReadContent(cfg.modDir .. "/config/lines.ini", "lines") or {}
    local lines = {}
    for i = 1, 99 do
        local l = (ini[section] or {})["Line" .. i]
        if l and l ~= "" then lines[#lines + 1] = l end
    end
    local Events, Lines = require("events"), require("lines")
    local line = #lines > 0 and Lines.Pick(section .. "." .. name, lines, Events.Var("Day")) or nil
    pcall(function() Events.Run({ { kind = "Pose", value = "Meow", who = name } }) end)
    if not line then log("kits: %s - nothing to say (lines.ini [%s] has no lines)", name, section) return end
    line = line:gsub("{PLAYER}", WaCa.PlayerName and WaCa.PlayerName() or "you"):gsub("{NAME}", name)
    log("kits: you talk to %s: %s", name, line)
    WaCa.SayOrShow(name, line)
end

-- the kits by the nursery: a half ring in front of its door, facing the camp
local function place()
    if #kits == 0 then return end
    local door = nursery()
    local camp
    pcall(function() camp = require("duties").Camp().middle end)
    if not door then
        log("kits: no nursery of your clan in this world - the kits stay unseen")
        door = camp
        if not door then return end
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
    -- (a kit already standing there from before a reload of Clan Life - the paths kept in memory are gone with it: it
    -- is taken up again, not spawned twice)
    -- (by name, anywhere: a newcomer stands about the camp, not by the nursery - it was spawned a second time after a
    -- reload when only the nursery was looked at, VM 2026-11-03; the names are this save's own kits' / newcomers')
    local ours = {}
    for _, kit in ipairs(kits) do ours[kit.name] = true end
    local standing = {}
    for _, c in ipairs(FindAllOf("BP_WrcSK_Customization_Cat_C") or {}) do
        pcall(function()
            if c:IsValid() and not c.bHidden then
                local nm = WaCa.CatName(c) or ""
                if ours[nm] then
                    standing[nm] = standing[nm] or {}
                    table.insert(standing[nm], pathOf(c))
                end
            end
        end)
    end
    for i, kit in ipairs(kits) do
        -- (the plate's rank line: the game's text for the role the cat's look carries (Role=Kit -> STR_GIVER_ROLE_KIT);
        -- else, for a newcomer, the clanmate's own plate's)
        -- (what it IS here: a kit, a grown kit = an apprentice, a newcomer = its look's rank - kits born before BlendLooks
        -- set Role = Kit carry their parent's "Warrior" in the look, VM 2026-11-03)
        local is = kit.adult and tostring(kit.look):match("Role=(%w+)") or (kit.grown and "Apprentice" or "Kit")
        if not kit.role and WaCa.RoleText then kit.role = WaCa.RoleText(is) end
        if kit.adult and not kit.role and kit.like and WaCa.PlateRole then kit.role = WaCa.PlateRole(kit.like) end
        if not spawned[kit.name] and standing[kit.name] then
            -- (one kept; copies more reloads left behind - before this was fixed each one spawned the kits again - go)
            local list = standing[kit.name]
            spawned[kit.name] = list[1]
            -- (its plate again: a reload of Core / Clan Life takes the widget's owner script with it)
            pcall(WaCa.Nameplate, StaticFindObject(list[1]), kit.name, kit.role)
            for j = 2, #list do
                local extra = StaticFindObject(list[j])
                if extra and extra:IsValid() then WaCa.Despawn(extra) end
            end
            log("kits: %s was there already (from before a reload) - kept%s", kit.name,
                #list > 1 and string.format(", %d extra cop(ies) removed", #list - 1) or "")
        end
        local a = spawned[kit.name] and StaticFindObject(spawned[kit.name])
        if not (a and a:IsValid()) and kit.adult then
            -- (a newcomer: in a ring about the camp's middle, full size - not by the nursery)
            local mid = camp or door
            local ang = math.rad(i * 47)
            local x, y = mid.X + math.cos(ang) * cfg.newcomerRing, mid.Y + math.sin(ang) * cfg.newcomerRing
            local cat = WaCa.SpawnCat(kit.look, { X = x, Y = y, Z = groundUnder(x, y, mid.Z) }, math.deg(ang) + 180, 1.0)
            if cat then
                pcall(WaCa.Nameplate, cat, kit.name, kit.role)
                spawned[kit.name] = pathOf(cat)
                placed[#placed + 1] = kit.name
            end
        elseif not (a and a:IsValid()) then
            -- (a half ring in front of the door: kit 1 straight out, the others to its sides)
            local side = (i % 2 == 0) and 1 or -1
            local turn = math.floor(i / 2) * 0.6 * side
            local ox = out.X * math.cos(turn) - out.Y * math.sin(turn)
            local oy = out.X * math.sin(turn) + out.Y * math.cos(turn)
            local x, y = door.X + ox * cfg.spread, door.Y + oy * cfg.spread
            local z = groundUnder(x, y, door.Z)
            local scale = kit.grown and cfg.apprenticeScale or select(3, WaCa.BlendLooks(kit.look, kit.look))
            local cat = WaCa.SpawnCat(kit.look, { X = x, Y = y, Z = z }, face + (i - 1) * 25 * side, scale)
            if cat then
                pcall(WaCa.Nameplate, cat, kit.name, kit.role, 60)
                spawned[kit.name] = pathOf(cat)
                placed[#placed + 1] = kit.name
            end
        end
    end
    if #placed > 0 then log("kits: %s placed (kits by the nursery, newcomers about the camp)", table.concat(placed, ", ")) end
    -- (and each can be talked to - see talkTo)
    for _, kit in ipairs(kits) do
        local a = spawned[kit.name] and StaticFindObject(spawned[kit.name])
        if a and a:IsValid() and not (talkSpots[kit.name] and StaticFindObject(talkSpots[kit.name].path)) and WaCa.InteractSpot then
            local name = kit.name
            talkSpots[name] = WaCa.InteractSpot(a:K2_GetActorLocation(), function() talkTo(name) end, { reach = 220 })
        end
    end
end

local function keep()
    local path = sidecar()
    -- (only over this slot's kits as read: a read that failed must never be saved over the kits it missed)
    if not path or restoredFor ~= WaCa.CurrentSlot() then return end
    local data = { __order = {} }
    for i, kit in ipairs(kits) do
        local key = "Kit" .. i
        data[key] = { Name = kit.name, Mate = kit.mate or "", Born = tostring(kit.born or 0), Grown = kit.grown and "1" or "0",
                      Adult = kit.adult and "1" or "0", Like = kit.like or "", Role = kit.role or "",
                      CastAs = kit.castAs or "", Look = kit.look,
                      __order = { "Name", "Mate", "Born", "Grown", "Adult", "Like", "Role", "CastAs", "Look" } }
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
            kits[#kits + 1] = { name = k.Name, look = k.Look, mate = k.Mate, born = tonumber(k.Born or "") or 0,
                                grown = k.Grown == "1", adult = k.Adult == "1", like = (k.Like or "") ~= "" and k.Like or nil,
                                role = (k.Role or "") ~= "" and k.Role or nil,
                                castAs = (k.CastAs or "") ~= "" and k.CastAs or nil }
        end
        i = i + 1
    end
    -- (kits born before BlendLooks set Role = Kit carry their parent's rank in the look: set right - the next save keeps
    -- it; 2026-11-03)
    for _, kit in ipairs(kits) do
        if not kit.adult then
            local want = kit.grown and "Apprentice" or "Kit"
            local have = tostring(kit.look):match("Role=(%w+)")
            if have and have ~= want then
                kit.look = kit.look:gsub("Role=%w+", "Role=" .. want)
                kit.role = nil
                log("kits: %s's look said %s - %s now", kit.name, have, want)
            end
        end
    end
    if #kits > 0 then log("kits: %d of your own in this save", #kits) end
    -- (a newcomer that plays a story role: the role bound to it again - by its name, which only the save knows)
    for _, kit in ipairs(kits) do
        if kit.castAs then WaCa.Emit("NewcomerCast", kit.castAs, kit.name) end
    end
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

-- GROWING UP (ApprenticeAfter days, 0 = never - a draft, the story's to decide): a kit that old becomes an apprentice -
-- its name "...paw" (the game's own name texts), its look's role Apprentice, drawn bigger; placed again
local function growUp(today)
    if (cfg.apprenticeAfter or 0) <= 0 then return end
    local grew = {}
    for _, kit in ipairs(kits) do
        if not kit.grown and not kit.adult and today - (kit.born or today) >= cfg.apprenticeAfter then
            local prefix = kit.look:match('PrefixNameId="([^"]*)"') or ""
            local paw = prefix ~= "" and WaCa.GetText(prefix .. "_PAW") or ""
            kit.grown = true
            kit.role = nil                              -- (its plate's rank line read again: Apprentice now)
            kit.look = kit.look:gsub('SuffixNameId="[^"]*"', 'SuffixNameId="_PAW"'):gsub("Role=%w+", "Role=Apprentice")
            local old = kit.name
            if paw ~= "" then kit.name = paw end
            grew[#grew + 1] = old .. " -> " .. kit.name
            local a = spawned[old] and StaticFindObject(spawned[old])
            if a and a:IsValid() then WaCa.Despawn(a) end
            spawned[old] = nil
        end
    end
    if #grew > 0 then
        log("kits: grown into apprentices - %s", table.concat(grew, ", "))
        WaCa.Emit("KitsGrown", table.concat(grew, ","))
        place()
    end
end

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

-- a newcomer taking after the clanmate `like` - its name, or nil
-- castAs: a story role the newcomer plays ("S:apprentice") - a later scene / cutscene casts it by that role (library
-- exercise 2026-11-03: its name is made up when it joins, so a writer can't name it in [Cast])
function Kits.Newcomer(like, castAs)
    local look = like and lookOfMate(like)
    if not look then
        log("kits: newcomer - no clanmate '%s' to take after", tostring(like))
        return nil
    end
    local role = look:match("Role=(%w+)") or "Warrior"
    local suffix = look:match('SuffixNameId="([^"]*)"') or ""
    local used = {}
    for _, k in ipairs(kits) do used[k.name] = true end
    for _ = 1, 16 do
        local blended = WaCa.BlendLooks(look, look)
        local prefix = blended and blended:match('PrefixNameId="([^"]*)"') or ""
        local name = (prefix ~= "" and suffix ~= "") and WaCa.GetText(prefix .. suffix) or ""
        if name ~= "" and name ~= prefix .. suffix and not used[name] then
            local grown = blended:gsub('SuffixNameId="[^"]*"', 'SuffixNameId="' .. suffix .. '"'):gsub("Role=%w+", "Role=" .. role)
            -- (the rank line: the clanmate's own plate's - the game's word in the game's language)
            local plateRole = (WaCa.RoleText and WaCa.RoleText(role)) or (WaCa.PlateRole and WaCa.PlateRole(like)) or nil
            castAs = (castAs or "") ~= "" and castAs or nil
            kits[#kits + 1] = { name = name, look = grown, mate = "", grown = true, adult = true, like = like, role = plateRole,
                                castAs = castAs, born = DayNight and DayNight.Day and DayNight.Day() or 0 }
            log("kits: a newcomer joins the clan - %s (%s, taking after %s)%s", name, role, like,
                castAs and (" - plays " .. castAs) or "")
            place()
            if castAs then WaCa.Emit("NewcomerCast", castAs, name) end
            WaCa.Emit("NewcomerJoined", name, like)
            return name
        end
    end
    log("kits: newcomer - no free name for one taking after %s", like)
    return nil
end

function Kits.Init(c)
    WaCa, log, DayNight = c.WaCa, c.log, c.DayNight
    cfg.modDir = c.modDir
    local ini = WaCa.ReadContent(c.modDir .. "/config/kits.ini", "kits") or {}
    local k = ini["Kits"] or {}
    cfg.on = c.part("Kits", k.On)
    local lo, hi = (k.Count or ""):match("^%s*(%d+)%s*%-%s*(%d+)%s*$")
    if lo then cfg.countMin, cfg.countMax = tonumber(lo), math.max(tonumber(lo), tonumber(hi))
    elseif tonumber(k.Count or "") then cfg.countMin, cfg.countMax = tonumber(k.Count), tonumber(k.Count) end
    cfg.spread = tonumber(k.Spread or "") or cfg.spread
    cfg.apprenticeAfter = tonumber(k.ApprenticeAfter or "") or cfg.apprenticeAfter
    cfg.apprenticeScale = tonumber(k.ApprenticeScale or "") or cfg.apprenticeScale
    cfg.newcomerRing = tonumber(k.NewcomerRing or "") or cfg.newcomerRing
    log("kits: %s (%d-%d a litter, by the nursery)", cfg.on and "on" or "off", cfg.countMin, cfg.countMax)
    -- (newcomers whatever [Kits] On says - the save's kits / newcomers placed and kept the same way)
    WaCa.On("Newcomer", function(like, castAs)
        ExecuteInGameThread(function()
            pcall(restore)
            local ok, err = pcall(Kits.Newcomer, like, castAs)
            if not ok then log("kits: the newcomer failed (%s)", tostring(err)) end
        end)
    end)
    -- (kits off = the player wants none of their own: a story's / mod's HaveKits is declined - said so, never silently;
    -- library exercise 2026-11-05, time skips did nothing without a word when off)
    WaCa.On("HaveKits", function(mate, count)
        if not cfg.on then
            log("kits: HaveKits (%s) declined - kits are off (kits.ini On = 0)", tostring(mate))
            return
        end
        ExecuteInGameThread(function()
            local ok, err = pcall(Kits.Born, mate, count)
            if not ok then log("kits: the birth failed (%s)", tostring(err)) end
        end)
    end)
    WaCa.On("GameSaved", function()
        restore()
        keep()
    end)
    WaCa.On("DayStarted", function(n)
        ExecuteInGameThreadWithDelay(2000, function()
            pcall(restore)
            local ok, err = pcall(growUp, tonumber(n) or 0)
            if not ok then log("kits: growing up failed (%s)", tostring(err)) end
        end)
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
