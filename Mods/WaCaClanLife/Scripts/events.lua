-- Scenes (tickets.md 17 + 10, "show, don't tell") - the ONE place the mod plays cards, the game's conversations and
-- cinematics, fades, bonds and other mods' hooks, and the story's hook points (the clan loop: duties.lua; the story
-- as days: days.lua; hour-scheduled scenes: config/events.ini [Event.<Name>]).
--
-- A scene = steps run one after another, each waiting for its own end (written as config lines, or Lua tables):
--   Card: <text>                 the game's centre message, CardSeconds long ({DAY}, {THIRD}, {DEPUTY} ... filled)
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
local cfg = { cardSeconds = 6, dialogueMax = 300, startWait = 15 }
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

local function showCard(text, seconds)
    local ok, err = pcall(function()
        local class = WaCa.LoadAsset(CARD)
        local controller = pc()
        local w = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(controller, class, controller)
        w:AddToViewport(60)
        w.mcGuiTextInfo:SetText(FText(text))       -- after AddToViewport (its construct sets a string-table key)
        local name = (w:GetFullName():gsub("^%S+ ", ""))
        ExecuteInGameThreadWithDelay(math.floor(seconds * 1000), function()
            local o = StaticFindObject(name)
            if o and o:IsValid() then o:RemoveFromParent() end
        end)
    end)
    if not ok then log("events: card failed (%s)", tostring(err)) end
end

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
    local p = WaCa.GameProgress()
    local me = p and p["Gameplay.Combat.Character.Cat.Player"]
    return me and me.Customization and me.Customization:match("ClanType=(%w+)") or nil
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

-- --- the step runner ---

-- "Kind: value [@ who]" -> { kind, value, who }
function Events.Parse(line)
    local kind, rest = tostring(line):match("^%s*(%a+)%s*:%s*(.-)%s*$")
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
        showCard(fill(s.value, ctx), cfg.cardSeconds)
        after(cfg.cardSeconds, nextStep)
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
    Events.Provide("Rank", function() local p = WaCa.GameProgress() return p and tonumber(p.Rank) or 0 end)
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
