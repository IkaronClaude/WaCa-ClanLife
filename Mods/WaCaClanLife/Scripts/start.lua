-- STORY PACK STARTS (tickets.md "Story packs: standalone starts", operator 2026-10-28: "a mod story played with a NEW
-- cat defines its entry point - e.g. a warrior start: level 8, warrior, main story day 13"). A pack's
-- content/start.ini [Start] says where a NEW cat's story begins:
--   Day = 13        the story day (days.ini) the cat starts on
--   Level = 8       the cat's level - reached through the game's own EXP, one level-up after another (its stats grow
--                   the game's way)
--   Name = Warrior  the creator asks for a warrior name (published as "story.start" for WaCa Looks' name box)
--   Step1 ...       scene steps run once at the start (Card, Set, Bond, Cutscene ...: the same as clan events)
-- Applied ONCE per cat, and only to a new one (level 1, no rank quest done, no start applied before): installing a
-- pack never changes a cat already being played. Not possible yet: a start RANK (the game's rank is its rank quests,
-- kept in native quest data) and a start party (the same - tickets.md "The party = who you're out with").
local Start = {}

local WaCa, log, Days, Events
local cfg = nil            -- the [Start] section, or nil
local doneFor = nil        -- the save slot the start was looked at for (once per session per cat)

local function sidecar() return WaCa.SlotFile("WaCaStart") end

-- the mod the start comes from (ReadContent's owner of its keys)
local function owner()
    local o = type(cfg.__owner) == "table" and cfg.__owner or {}
    for _, k in ipairs(cfg.__order or {}) do if o[k] then return o[k] end end
    return "WaCaClanLife"
end

local function levelComponent()
    for _, c in ipairs(FindAllOf("SwtPlayerController") or {}) do
        if c:IsValid() and c.Player and c.PlayerState and c.PlayerState:IsValid() then
            return c.PlayerState.LevelComponent
        end
    end
end

local function levelInfo()
    local lc = levelComponent()
    if not (lc and lc:IsValid() and WaCaNative_LevelInfo) then return nil end
    return WaCaNative_LevelInfo(lc:GetAddress())
end

-- one level-up at a time (the EXP the next level needs), a moment apart, until the start's level or the cap
local function levelTo(target, tries)
    local level, exp, next, cap = levelInfo()
    if not level then log("start: the cat's level can't be read - Level not applied") return end
    if level >= target or level >= cap or tries <= 0 then
        log("start: the cat is level %d (start Level %d)", level, target)
        return
    end
    local lc = levelComponent()
    WaCaNative_AddExperience(lc:GetAddress(), math.max(1, next - exp + 1))
    ExecuteInGameThreadWithDelay(1500, function() levelTo(target, tries - 1) end)
end

local function apply(why)
    local steps = {}
    for _, key in ipairs(cfg.__order or {}) do
        if key:match("^Step%d+$") and (cfg[key] or "") ~= "" then
            local step = Events.Parse(cfg[key])
            if step then steps[#steps + 1] = step else log("start: can't read %s '%s'", key, cfg[key]) end
        end
    end
    log("start: a new cat - the story pack start (%s): day %s, level %s, %d step(s) [%s]", owner(),
        tostring(cfg.Day or "-"), tostring(cfg.Level or "-"), #steps, why)
    if tonumber(cfg.Day or "") and Days and not Days.SetStory(tonumber(cfg.Day), "the story pack's start") then
        log("start: Day %s not applied - story days are off (clanlife.ini [Days] On)", tostring(cfg.Day))
    end
    if tonumber(cfg.Level or "") then levelTo(math.floor(tonumber(cfg.Level)), 100) end
    if #steps > 0 then Events.Run(steps) end
    local path = sidecar()
    if path then
        WaCa.WriteIni(path, { Start = { Applied = "1", Day = cfg.Day or "", Level = cfg.Level or "", __order = { "Applied", "Day", "Level" } },
            __order = { "Start" } }, "; WaCa Clan Life - this cat's story pack start was applied (start.ini) - never again")
    end
end

-- a new cat: level 1, no rank quest done, and no start applied to it before
local function check()
    local slot = WaCa.CurrentSlot()
    if not slot or doneFor == slot then return end
    local path = sidecar()
    local s = path and (WaCa.ReadIni(path) or {})["Start"]
    if s and s.Applied == "1" then doneFor = slot return end
    local level = levelInfo()
    local rank = WaCa.PlayerRank()
    if not level then
        -- (not in the world yet: asked again at the next screen - or WaCa Core too old to read a level: said once)
        if not WaCaNative_LevelInfo and not Start.warned then
            Start.warned = true
            log("start: WaCa Core can't read the cat's level (too old?) - the story pack start waits")
        end
        return
    end
    doneFor = slot
    if level > 1 or (rank and rank > 1) then
        log("start: a cat already played (level %d, rank %s) - the story pack start is for new cats only", level, tostring(rank))
        if path then
            WaCa.WriteIni(path, { Start = { Applied = "0", Skipped = "an existing cat", __order = { "Applied", "Skipped" } },
                __order = { "Start" } }, "; WaCa Clan Life - this cat existed before the story pack start (start.ini) - left as it was")
        end
        return
    end
    apply("level 1, rank " .. tostring(rank))
end

function Start.Init(c)
    WaCa, log, Days, Events = c.WaCa, c.log, c.Days, c.Events
    local ini = WaCa.ReadContent(c.modDir .. "/config/start.ini", "start") or {}
    cfg = ini["Start"]
    if not cfg or (cfg.Off or "") == "1" then return end
    log("start: a story pack start from %s (day %s, level %s, name %s)", owner(),
        tostring(cfg.Day or "-"), tostring(cfg.Level or "-"), tostring(cfg.Name or "-"))
    -- what the creator should ask for (WaCa Looks' name box: a warrior name for a warrior start)
    WaCa.Publish("story.start", { name = cfg.Name, day = tonumber(cfg.Day or ""), level = tonumber(cfg.Level or "") }, true)
    -- (a while after the HUD shows: the save of a new cat is written, the level readable)
    WaCa.On("ScreenShown", function(screen)
        local ok, hud = pcall(function() return screen:GetClass():GetFName():ToString():find("^WBP_GuiHudGame") ~= nil end)
        if not (ok and hud) then return end
        ExecuteInGameThreadWithDelay(8000, function()
            local okRun, err = pcall(check)
            if not okRun then log("start: failed (%s)", tostring(err)) end
        end)
    end)
end

return Start
