-- THE STORY CHECK (tickets.md "Story packs: ... writer-friendly authoring": "clear errors (a story checker that lists
-- unknown roles / dialogue ids / broken conditions)"). Once the world is up, every story file - with every mod's
-- content added (WaCa.ReadContent) - is read the way the scene runner will read it, and what would go wrong in play is
-- listed NOW: a step kind the runner doesn't know (a typo: "Crad:"), a cutscene no mod defines, a role (S:<role>) no
-- [Cast] gives a cat, a condition that can't be read, a story variable that's tested but never set by any step (a
-- typo, or set only by another mod's code - a warning). Each problem goes to the log ("story check: ..."), the whole
-- list to Saved/WaCaStoryCheck.txt, and one line on screen when there is any. Config: clanlife.ini [StoryCheck] On.
local StoryCheck = {}

local WaCa, log, Events
local modDir

-- the scene runner's step kinds (events.lua's Run)
local KINDS = { Add = true, Bond = true, Card = true, Choice = true, Cutscene = true, Else = true, EndIf = true, Dialogue = true, Emit = true, Fade = true,
                FadeIn = true, Freeze = true, Gather = true, Groups = true, Hook = true, If = true, Lead = true, Pair = true,
                Part = true, Party = true, Pose = true, Release = true, Set = true, Wait = true }
-- (which keys of which files are scene steps / conditions)
local PHASES = { "Morning", "Noon", "Afternoon", "Evening", "Night" }

local function isStepKey(file, section, key)
    if file == "days" then
        for _, p in ipairs(PHASES) do
            if key:match("^" .. p .. "%d*$") or key:match("^" .. p .. "Start%d*$") or key:match("^" .. p .. "After%d*$") then
                return section:match("^Day%.") ~= nil
            end
        end
        return false
    end
    if file == "duties" then return key:match("^Start%d*$") or key:match("^Event%d*$") or key:match("^Step%d*$") end
    return key:match("^Step%d*$") ~= nil
end

-- every variable a condition names: "Day <= LostKit.Until, Pile >= 50" -> { Day, LostKit.Until, Pile }; bad = unreadable
local function condVars(text)
    local names, bad = {}, {}
    for cond in tostring(text or ""):gmatch("[^,]+") do
        local name, op, value = cond:match("^%s*([%w%.%_]+)%s*([<>=!]+)%s*(.-)%s*$")
        local okOp = op == "=" or op == "!=" or op == "<" or op == "<=" or op == ">" or op == ">="
        if name and okOp then
            -- (the right side is text unless a variable of that name exists - Weather = Rain - as the runner reads
            -- it; only the tested name has to be a variable)
            names[#names + 1] = name
        elseif cond:match("%S") then
            bad[#bad + 1] = cond:match("^%s*(.-)%s*$")
        end
    end
    return names, bad
end

-- variables our own Lua sets (Events.SetVar("Gathering.Chosen" ...)) - read from the scripts, not guessed
local function luaSetVars()
    local out = {}
    for _, f in ipairs({ "gathering", "duties", "days", "romance", "kits", "events", "weather", "daynight" }) do
        local h = io.open(modDir .. "/Scripts/" .. f .. ".lua", "r")
        if h then
            local src = h:read("*a")
            h:close()
            for name in src:gmatch('SetVar%(%s*"([%w%.%_]+)"') do out[name] = true end
        end
    end
    return out
end

function StoryCheck.Run()
    local problems, warnings = {}, {}
    local function problem(file, section, key, text) problems[#problems + 1] = string.format("%s.ini [%s] %s: %s", file, section, key, text) end
    local function warning(file, section, key, text) warnings[#warnings + 1] = string.format("%s.ini [%s] %s: %s", file, section, key, text) end
    local cutscenes = WaCa.Latest and WaCa.Latest("cutscenes.names")
    local known = {}
    for _, n in ipairs(type(cutscenes) == "table" and cutscenes or {}) do known[n] = true end
    local cast = Events.CastSpecs and Events.CastSpecs() or {}
    local set, tested = luaSetVars(), {}
    local files = { "clanevents", "days", "gatherings", "duties", "events", "lines", "start" }
    local loaded = {}
    for _, file in ipairs(files) do
        loaded[file] = WaCa.ReadContent(modDir .. "/config/" .. file .. ".ini", file) or {}
    end
    -- (pass 1: the steps - and what they set)
    for _, file in ipairs(files) do
        for section, t in pairs(loaded[file]) do
            if type(t) == "table" and section ~= "__order" then
                for _, key in ipairs(t.__order or {}) do
                    local v = t[key]
                    if type(v) == "string" and v ~= "" and v ~= "none" and isStepKey(file, section, key) then
                        local step = Events.Parse(v)
                        if not step then
                            problem(file, section, key, "can't read the step '" .. v .. "' (Kind: what)")
                        elseif not KINDS[step.kind] then
                            problem(file, section, key, "unknown step kind '" .. step.kind .. "' (known: Card, Cutscene, Set, Add, If, Bond, Emit, Hook, Wait, Fade ...)")
                        else
                            if step.kind == "Cutscene" and cutscenes and not known[step.value] then
                                problem(file, section, key, "no cutscene '" .. step.value .. "' (WaCa Cutscenes knows: " .. table.concat(cutscenes, ", ") .. ")")
                            end
                            if (step.kind == "Set" or step.kind == "Add" or step.kind == "Choice") then
                                local name = step.value:match("^%s*([%w%.%_]+)")
                                if name then set[name] = true end
                            end
                            if step.kind == "If" then tested[#tested + 1] = { file, section, key, step.value } end
                            for _, who in ipairs({ step.who, step.value }) do
                                local role = who and who:match("^(S:[%w_]+)")
                                if role and not cast[role] then
                                    problem(file, section, key, "the role " .. role .. " has no cat - give it one in [Cast] (events.ini / a pack's content/events.ini)")
                                end
                            end
                        end
                    elseif key == "Require" or key == "If" then
                        tested[#tested + 1] = { file, section, key, v }
                    end
                end
            end
        end
    end
    -- (lines.ini: whom the dialogue is for - a role the game has no filler lines for does nothing, silently; a murmur's
    -- S:<role> needs a cat in [Cast] - library exercise 2026-11-02)
    local okL, Lines = pcall(require, "lines")
    local roles = okL and Lines.FillerRoles and Lines.FillerRoles() or {}
    local anyRole = next(roles) ~= nil
    local roleList
    for section, t in pairs(loaded.lines or {}) do
        if type(t) == "table" and section ~= "__order" then
            local who = section:match("^Dialogue%.") and t.Who or section:match("^Lines%.([^.]+)")
            if who and who ~= "" and who ~= "All" and anyRole and not roles[who] then
                if not roleList then
                    roleList = {}
                    for r in pairs(roles) do roleList[#roleList + 1] = r end
                    table.sort(roleList)
                end
                problem("lines", section, section:match("^Dialogue%.") and "Who" or "(its name)",
                    "the game has no filler lines for '" .. who .. "' - it would say nothing (a role, not a cat's name; known: "
                    .. table.concat(roleList, ", ") .. ")")
            end
            local mw = section:match("^Murmur%.") and t.Who
            local role = mw and mw:match("^(S:[%w_]+)$")
            if role and not cast[role] then
                problem("lines", section, "Who", "the role " .. role .. " has no cat - give it one in [Cast]")
            end
        end
    end
    -- (story days written while story days are off - [Days] On = 0, the default - never play; a pack's writer
    -- wouldn't know: library exercise 2026-11-02)
    local okD, Days = pcall(require, "days")
    if okD and Days.IsOn and not Days.IsOn() then
        -- (a pack's own days only - Clan Life's examples are off with the rest)
        local modsDir = modDir:match("^(.*)[/\\][^/\\]+$")
        for _, mod in ipairs(modsDir and WaCa.EnabledMods(modsDir) or {}) do
            local ini = WaCa.ReadIni(modsDir .. "/" .. mod .. "/content/days.ini") or {}
            local nDays = 0
            for section in pairs(ini) do if tostring(section):match("^Day%.%d+$") then nDays = nDays + 1 end end
            if nDays > 0 then
                warning("days", "Days", "On", mod .. " writes " .. nDays .. " story day(s), but story days are off - they "
                    .. "won't play (Clan Life's config/days.ini [Days] On = 1, with the day / night cycle on)")
            end
        end
    end
    -- (a pack's own duties, [Duty.*] in duties.ini: each point a place that can be found, the chance's thirds, the
    -- turn-in - library exercise 2026-11-02: a misspelt den only showed in play, as 'free time instead')
    local dens
    pcall(function()
        dens = {}
        for _, d in ipairs(FindAllOf("WrcHousingDoorActor") or {}) do
            pcall(function() local n = d.ActorTitle:ToString() if not d.bIsExit and n ~= "" then dens[n:lower()] = true end end)
        end
        if not next(dens) then dens = nil end
    end)
    local THIRDS = { Morning = true, Noon = true, Afternoon = true, Evening = true, Night = true }
    local TURNINS = { Pile = true, Partner = true, None = true, Camp = true, Leader = true, Deputy = true,
                      MedicineCat = true, Elder = true, Queen = true, Warrior = true, Mentor = true }
    for section, t in pairs(loaded.duties or {}) do
        local name = type(t) == "table" and tostring(section):match("^Duty%.(.+)$")
        if name then
            if (t.Points or "") == "" then problem("duties", section, "Points", "no points - the duty has nowhere to go") end
            local i = 0
            for spec in tostring(t.Points or ""):gmatch("[^;]+") do
                i = i + 1
                spec = spec:match("^%s*(.-)%s*$")
                local den = spec:match("^Den:%s*(.+)$")
                local role = spec:match("^(S:[%w_]+)$")
                if den and dens and not dens[den:lower()] then
                    local known = {}
                    for d in pairs(dens) do known[#known + 1] = d end
                    table.sort(known)
                    problem("duties", section, "Points", "point " .. i .. ": no den '" .. den .. "' in this world (dens: " .. table.concat(known, ", ") .. ")")
                elseif role and not cast[role] then
                    problem("duties", section, "Points", "point " .. i .. ": the role " .. role .. " has no cat - give it one in [Cast]")
                end
            end
            for third in tostring(t.Chance or ""):gmatch("(%a+)%s*:") do
                if not THIRDS[third] then problem("duties", section, "Chance", "no third '" .. third .. "' (Morning, Noon, Evening, Night)") end
            end
            if (t.Chance or "") == "" then warning("duties", section, "Chance", "no Chance - the duty is only ever given when a story day or a test asks for it") end
            local ti = (loaded.duties["Task." .. name] or {}).TurnIn
            if ti and ti ~= "" and not TURNINS[ti] and not ti:match("^S:") then
                problem("duties", "Task." .. name, "TurnIn", "can't turn in to '" .. ti .. "' (Pile, Partner, None, or a role: Leader, Deputy, MedicineCat ...)")
            end
        end
    end
    -- (variables a cutscene sets - WaCa Cutscenes' Set: beat, library exercise 2026-11-02)
    pcall(function()
        local modsDir = modDir:match("^(.*)[/\\][^/\\]+$")
        local cs = modsDir and WaCa.ReadContent(modsDir .. "/WaCaCutscenes/config/cutscenes.ini", "cutscenes") or {}
        for section, t in pairs(cs) do
            if type(t) == "table" and tostring(section):match("^Cutscene%.") then
                for k, v in pairs(t) do
                    local name = tostring(k):match("^Beat%d+$") and tostring(v):match("^%s*[%d%.]+%s+Set:%s*([%w%.%_]+)")
                    if name then set[name] = true end
                end
            end
        end
    end)
    -- (pass 2: the conditions - readable, and every variable they test set somewhere)
    for _, e in ipairs(tested) do
        local names, bad = condVars(e[4])
        for _, b in ipairs(bad) do problem(e[1], e[2], e[3], "can't read the condition '" .. b .. "' (Name op value: Day >= 3)") end
        for _, n in ipairs(names) do
            if not (set[n] or Events.Has(n) or n:match("^Event:")) then
                warning(e[1], e[2], e[3], "the variable '" .. n .. "' is never set by a story step (a typo? or set by another mod's code)")
            end
        end
    end
    for _, p in ipairs(problems) do log("story check: PROBLEM %s", p) end
    for _, w in ipairs(warnings) do log("story check: warning %s", w) end
    log("story check: %d problem(s), %d warning(s) in the story files (%s)", #problems, #warnings,
        cutscenes and "cutscene names checked" or "WaCa Cutscenes not there - cutscene names not checked")
    pcall(function()
        local f = io.open(WaCa.SaveDir() .. "/../WaCaStoryCheck.txt", "w")
        if not f then return end
        f:write("WaCa Clan Life - story check\n\n")
        for _, p in ipairs(problems) do f:write("PROBLEM  ", p, "\n") end
        for _, w in ipairs(warnings) do f:write("warning  ", w, "\n") end
        if #problems + #warnings == 0 then f:write("No problems found.\n") end
        f:close()
    end)
    if #problems > 0 then
        WaCa.Emit("ShowLine", string.format("WaCa story check: %d problem(s) in the story files - see Saved/WaCaStoryCheck.txt", #problems))
    end
    return problems, warnings
end

-- WATCH WHILE WRITING ([StoryCheck] Watch = 1): the story files are read when Clan Life starts, so an edited pack did
-- nothing until the game restarted (library exercise 2026-11-01). With Watch on, every few seconds the story files
-- (Clan Life's own and every pack's content/) are compared with what was read; a change reloads Clan Life the way
-- UE4SS reloads an edited mod - its main.lua is rewritten as it is (same bytes, a new time), UE4SS sees the change.
-- (each story file and the mod that reads it - a change reloads exactly that mod: library exercise 2026-11-02, a
-- pack's roster.ini / roles.ini edited with Watch on did nothing till a restart; shapes / places weren't watched)
local WATCHED = { clanevents = "WaCaClanLife", days = "WaCaClanLife", gatherings = "WaCaClanLife",
                  duties = "WaCaClanLife", events = "WaCaClanLife", lines = "WaCaClanLife", start = "WaCaClanLife",
                  cutscenes = "WaCaCutscenes", shapes = "WaCaCutscenes", places = "WaCaCutscenes",
                  roster = "WaCaLooks", roles = "WaCaHunting" }
-- the story files' text, per mod that reads them
local function storyText()
    local modsDir = modDir:match("^(.*)[/\\][^/\\]+$")
    local parts = {}
    local function add(path, owner)
        local f = io.open(path, "rb")
        if f then
            parts[owner] = (parts[owner] or "") .. path .. "\0" .. f:read("*a") .. "\1"
            f:close()
        end
    end
    for n, owner in pairs(WATCHED) do add(modDir .. "/config/" .. n .. ".ini", owner) end
    for _, mod in ipairs(modsDir and WaCa.EnabledMods(modsDir) or {}) do
        for n, owner in pairs(WATCHED) do add(modsDir .. "/" .. mod .. "/content/" .. n .. ".ini", owner) end
    end
    return parts
end
local function watch(every)
    local seen = storyText()
    local looks = 0
    local function look()
        local now = storyText()
        looks = looks + 1
        if looks == 1 then
            local n = 0
            for _, t in pairs(now) do n = n + #t end
            log("story check: watch - first look (%d bytes of story files)", n)
        end
        local changed = {}
        for owner, t in pairs(now) do if seen[owner] ~= t then changed[#changed + 1] = owner end end
        for owner in pairs(seen) do if now[owner] == nil then changed[#changed + 1] = owner end end
        if #changed > 0 then
            seen = now
            table.sort(changed)
            log("story check: a story file changed - %s reload (Watch)", table.concat(changed, ", "))
            -- (each mod whose files changed is reloaded the way UE4SS reloads an edited mod; Clan Life last - this copy
            -- goes with it, and its watch with it)
            local modsDir = modDir:match("^(.*)[/\\][^/\\]+$") or modDir
            local paths, self = {}, false
            for _, owner in ipairs(changed) do
                if owner == "WaCaClanLife" then self = true
                else paths[#paths + 1] = modsDir .. "/" .. owner .. "/Scripts/main.lua" end
            end
            if self then paths[#paths + 1] = modDir .. "/Scripts/main.lua" end
            for _, path in ipairs(paths) do
                local f = io.open(path, "rb")
                local src = f and f:read("*a")
                if f then f:close() end
                if src then
                    local w = io.open(path, "wb")
                    if w then w:write(src) w:close() end
                end
            end
            if self then return end
        end
        ExecuteInGameThreadWithDelay(math.floor(every * 1000), look)
    end
    ExecuteInGameThreadWithDelay(math.floor(every * 1000), look)
    log("story check: watching the story files (every %d s - an edit reloads Clan Life)", every)
end

function StoryCheck.Init(c)
    WaCa, log, Events, modDir = c.WaCa, c.log, c.Events, c.modDir
    local ini = WaCa.ReadIni(modDir .. "/config/clanlife.ini") or {}
    local sc = ini["StoryCheck"] or {}
    if (sc.Watch or "0") == "1" then pcall(watch, math.max(2, tonumber(sc.WatchEvery or "") or 5)) end
    if (sc.On or "1") == "0" then return end
    local done = false
    -- (a reload with the world up - Watch reloads Clan Life on every story file save - brings no new HUD: the check runs
    -- on its own 15 s in; library exercise 2026-11-02, it ran only when a menu happened to close)
    if WaCa.CurrentSlot() then
        done = true
        ExecuteInGameThreadWithDelay(15000, function()
            local okRun, err = pcall(StoryCheck.Run)
            if not okRun then log("story check: failed (%s)", tostring(err)) end
        end)
    end
    WaCa.On("ScreenShown", function(screen)
        if done then return end
        local ok, hud = pcall(function() return screen:GetClass():GetFName():ToString():find("^WBP_GuiHudGame") ~= nil end)
        if not (ok and hud) then return end
        done = true
        -- (a while after the world: every mod has published what it knows - the cutscene names)
        ExecuteInGameThreadWithDelay(15000, function()
            local okRun, err = pcall(StoryCheck.Run)
            if not okRun then log("story check: failed (%s)", tostring(err)) end
        end)
    end)
end

return StoryCheck
