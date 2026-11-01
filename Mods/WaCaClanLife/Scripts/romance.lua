-- ROMANCE - A DRAFT (tickets.md 12; OFF by default: who can be a mate, the asking and when kits come are the
-- operator's / a story's to decide - this is one way, every rule in romance.ini). A story cat your cat has grown close
-- to (the game's own bond: the save's BondDialogues - "<Role>_Reward_CloseBond" once that bond's top reward came) can
-- be asked: next to it, the ask key (H). Your cat must be of MinRank or above and have no mate yet. Asked: a line from
-- the cat, the mate kept with the save (event MateChosen(name); story variable HasMate = 1). KitsAfter days later the
-- kits come (kits.lua - HaveKits(mate)).
local Romance = {}

local WaCa, log, Events
local cfg = { on = false, key = "H", radius = 400, minBond = "CloseBond", minRank = "Warrior", kitsAfter = 7,
              yes = "{NAME}: I was hoping you'd ask, {PLAYER}. Yes.",
              notClose = "{NAME} looks at you kindly - but you aren't that close yet.",
              tooYoung = "You're too young to take a mate." }
local BOND_LEVELS = { Neutral = 1, Friendly = 2, Friend = 3, CloseBond = 4 }
local mate = nil                -- { name, role, since (day), kits (bool) }
local restoredFor = nil
local day = 0

local function sidecar() return WaCa.SlotFile("WaCaRomance") end

local function playerPawn()
    for _, c in ipairs(FindAllOf("SwtPlayerController") or {}) do
        if c:IsValid() and c.Player and c.Pawn and c.Pawn:IsValid() then return c.Pawn end
    end
end

local roleNames = nil
local function roleName(v)
    if not roleNames then
        roleNames = {}
        pcall(function()
            StaticFindObject("/Script/SwtQuest.ENarrativeRole"):ForEachName(function(n, val)
                roleNames[val] = (n:ToString():gsub("^.*::", ""))
            end)
        end)
    end
    return roleNames[v]
end

-- the bond with a story role, as the game keeps it: the highest "<Role>_Reward_<Level>" this save has reached (0 = none)
local function bondLevel(role)
    local best = 0
    pcall(function()
        local list = WaCa.SaveCharacter().GameplayProgression.BondDialogues
        for _, entry in ipairs(list or {}) do
            local r, level = tostring(entry):match("^(.-)_Reward_(%w+)$")
            if r == role and (BOND_LEVELS[level] or 0) > best then best = BOND_LEVELS[level] end
        end
    end)
    return best
end

local function say(text, name)
    text = text:gsub("{NAME}", name or "?"):gsub("{PLAYER}", WaCa.PlayerName and WaCa.PlayerName() or "you")
    WaCa.Emit("ShowLine", text)
end

local function keep()
    local path = sidecar()
    if not path or restoredFor ~= WaCa.CurrentSlot() then return end        -- (never over a mate it didn't read)
    local data = { __order = {} }
    if mate then
        data.Mate = { Name = mate.name, Role = mate.role or "", Since = tostring(mate.since or 0),
                      Kits = mate.kits and "1" or "0", __order = { "Name", "Role", "Since", "Kits" } }
        data.__order = { "Mate" }
    end
    WaCa.WriteIni(path, data, "; WaCa Clan Life - this save's mate (romance.lua, a draft)")
end

local function restore()
    local slot = WaCa.CurrentSlot()
    if not slot or restoredFor == slot then return end
    restoredFor = slot
    mate = nil
    local m = (WaCa.ReadIni(sidecar() or "") or {}).Mate
    if m and (m.Name or "") ~= "" then
        mate = { name = m.Name, role = m.Role, since = tonumber(m.Since or "") or 0, kits = m.Kits == "1" }
        log("romance: your cat's mate is %s (since day %d%s)", mate.name, mate.since, mate.kits and ", kits had" or "")
    end
end

-- the ask key next to a story cat
local function ask()
    local pawn = playerPawn()
    if not pawn then return end
    pcall(restore)
    if mate then return end                                -- (one mate)
    local p = pawn:K2_GetActorLocation()
    local yaw = math.rad(pawn:K2_GetActorRotation().Yaw)
    local fx, fy = math.cos(yaw), math.sin(yaw)
    -- (the cat your cat FACES within the radius, else the nearest: the party cat that follows 0.8 m behind was always
    -- the nearest - VM 2026-11-01, Nightheart asked instead of Toadfrost)
    local best, bd, faced, fd
    for _, a in ipairs(FindAllOf("QuestBaseActor") or {}) do
        pcall(function()
            if not a:IsValid() or a.bHidden or not a.narrativeRole or a.narrativeRole <= 0 then return end
            local q = a:K2_GetActorLocation()
            local dx, dy = q.X - p.X, q.Y - p.Y
            local d = dx * dx + dy * dy
            if d > cfg.radius * cfg.radius then return end
            if not bd or d < bd then best, bd = a, d end
            local len = math.sqrt(d)
            if len > 1 and (dx * fx + dy * fy) / len >= 0.5 and (not fd or d < fd) then faced, fd = a, d end
        end)
    end
    best = faced or best
    if not best then return end
    local name = WaCa.CatName(best) or "?"
    local role = roleName(best.narrativeRole) or ""
    local rank, need = WaCa.PlayerRank and WaCa.PlayerRank() or nil, nil
    pcall(function()
        StaticFindObject("/Script/SwtQuest.ECharacterRank"):ForEachName(function(n, v)
            if n:ToString():gsub("^.*::", "") == cfg.minRank then need = v end
        end)
    end)
    if need and rank and rank < need then
        say(cfg.tooYoung, name)
        log("romance: %s asked - your cat's rank %s is under %s", name, tostring(rank), cfg.minRank)
        return
    end
    local bond = bondLevel(role)
    if bond < (BOND_LEVELS[cfg.minBond] or 4) then
        say(cfg.notClose, name)
        log("romance: %s (%s) asked - the bond is %d, %s needs %d", name, role, bond, cfg.minBond, BOND_LEVELS[cfg.minBond] or 4)
        return
    end
    mate = { name = name, role = role, since = day, kits = false }
    say(cfg.yes, name)
    log("romance: %s (%s) is your cat's mate from day %d - kits after %d days", name, role, day, cfg.kitsAfter)
    pcall(function() Events.SetVar("HasMate", 1) end)
    WaCa.Emit("MateChosen", name)
end

function Romance.Mate() return mate and mate.name or nil end

function Romance.Init(c)
    WaCa, log, Events = c.WaCa, c.log, c.Events
    local ini = WaCa.ReadContent(c.modDir .. "/config/romance.ini", "romance") or {}
    local r = ini["Romance"] or {}
    cfg.on = c.part("Romance", r.On)
    cfg.key = (r.AskKey or "") ~= "" and r.AskKey or cfg.key
    if cfg.on then cfg.key = WaCa.ModKey("ClanLife", "AskMate", cfg.key, "ask a cat to be your mate") end
    cfg.radius = tonumber(r.Radius or "") or cfg.radius
    cfg.minBond = BOND_LEVELS[r.MinBond or ""] and r.MinBond or cfg.minBond
    cfg.minRank = (r.MinRank or "") ~= "" and r.MinRank or cfg.minRank
    cfg.kitsAfter = tonumber(r.KitsAfter or "") or cfg.kitsAfter
    for _, k in ipairs({ "Yes", "NotClose", "TooYoung" }) do
        local key = k:sub(1, 1):lower() .. k:sub(2)
        if (r[k] or "") ~= "" then cfg[key] = r[k] end
    end
    log("romance: %s (ask key %s, bond %s, rank %s+, kits after %d days)", cfg.on and "on (a draft)" or "off", cfg.key,
        cfg.minBond, cfg.minRank, cfg.kitsAfter)
    if not cfg.on then return end
    WaCa.On("KeyDown", function(_, name)
        if name ~= cfg.key or WaCa.InMenu() then return end
        local ok, err = pcall(ask)
        if not ok then log("romance: the asking failed (%s)", tostring(err)) end
    end)
    WaCa.On("DayStarted", function(n)
        day = tonumber(n) or day
        pcall(restore)
        if mate and not mate.kits and cfg.kitsAfter >= 0 and day - (mate.since or day) >= cfg.kitsAfter then
            mate.kits = true
            log("romance: day %d - %d days with %s: the kits come", day, cfg.kitsAfter, mate.name)
            WaCa.Emit("HaveKits", mate.name)
        end
    end)
    WaCa.On("DayRestored", function(n) day = tonumber(n) or day end)
    WaCa.On("GameSaved", function()
        restore()
        keep()
    end)
end

return Romance
