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
--   Bond: <points> [@ <who>]     the bond with a story cat grows (the game's own AddPersonalBonding); with a mod's
--                                own role (S:<role>) the story variable Bond.<role>
--   Emit: <event>                WaCa.Emit(event, context) - another mod's WaCa.On handler runs here
--   Cutscene: <name>             a cutscene of WaCa Cutscenes (its own mod: cats on marks, beats, camera shots);
--                                waits until it is over (without that mod: goes straight on)
--   Hook: <name>                 BLOCKING: every function registered with Events.Hook(name, fn) runs in turn as
--                                fn(context, continue) and calls continue() when its part is over (a mod's own
--                                cutscene, a minigame, a choice ...); then ANOTHER mod's, if one announced it
--                                (hook.<name>): StoryHook(name) -> its StoryHookDone(name), at most HookWait s
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
local cfg = { cardSeconds = 5, choiceRoom = 1100, dialogueMax = 300, startWait = 15, gatherRadius = 6000, gatherRing = 260, gatherArc = 90, bigPreyChance = 25,
              groupRadius = 90, groupFirstRow = 340, groupRowGap = 280, groupSpread = 220,
              walkIn = true, walkFrom = 700, walkReach = 80, walkSeconds = 12, walkSpeed = 150 }
local list = {}                  -- hour-scheduled scenes: { name, day, every, hour, steps, once }
local done = {}                  -- one-time scenes already played in this save
local restoredFor
local listed = false
local hooks = {}                 -- Hook: name -> { fn, ... }
local waiting                    -- the dialogue step waiting for its end: { started, done = fn }
local cutsceneWait               -- the cutscene step waiting for its end: { name, state, done = fn }
local cutsceneOn = false         -- a cutscene (WaCa Cutscenes) is playing: cards wait for it
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
    if WaCa.InMenu() or cutsceneOn then
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

-- A CHOICE (library exercise 2026-11-02: a story couldn't ask the player anything - every branch was chance or a
-- variable set elsewhere): Choice: <variable> = <question>; <answer 1>; <answer 2> [; <answer 3>; <answer 4>] - the
-- question and its answers until one is picked; the variable gets the answer's number (kept with the save like any
-- story variable), the scene goes on (If: Shelter = 1 ...). A question "Name: ..." (one word before the colon) puts
-- Name on the speaker's plate.
-- THE GAME'S ANSWER MENU (operator 2026-11-03: "Game's answer menu"): the quest dialogue screen
-- (WBP_QuestGiver_Dialogue - its paragraph, speaker plate, answer buttons 1-4), made and filled by us. Its buttons
-- don't answer our input by themselves (VM: no hover / key / click reached them - the screen's own logic wants a
-- quest dialogue node), so the choosing is ours: the game's Up / Down / A commands (keyboard and pad), the number keys, the mouse (hover picks,
-- a click answers - WaCa.MouseOver on the drawn buttons); the game's own highlight (CanvasSelected) shows the pick.
-- The game shows the mouse cursor for it on its own (it is a screen). The centre card is the fallback.
local NUMBER_KEYS = { One = 1, Two = 2, Three = 3, Four = 4, NumPadOne = 1, NumPadTwo = 2, NumPadThree = 3, NumPadFour = 4 }
local DIALOGUE = "/Game/Art/UXD/Blueprints/QuestDialogs/WBP_QuestGiver_Dialogue.WBP_QuestGiver_Dialogue_C"
-- UP / DOWN / ANSWER BY THE GAME'S OWN COMMANDS (library sweep 2026-11-03: the gamepad entries this had could never
-- fire - WaCa's KeyDown comes from keyboard / mouse window messages only): the game turns every device into screen
-- commands (ECommands, OnListenCommand on its screens: the arrows / D-pad / stick -> Button_Up 1 / Button_Down 2, Enter /
-- the pad's A -> Button_A 5), so the game's own mapping - keyboard and pad alike - moves and answers. Number keys and the
-- mouse stay on KeyDown.
local CMD_MOVE = { ["1"] = -1, ["2"] = 1, ["15"] = -1, ["16"] = 1 }      -- Button_Up / Down, StickL_Up / Down
local CMD_PICK = { ["5"] = true }                                        -- Button_A
local commandDown = {}                  -- command -> true between its press and its release
local PICK_KEYS = { LeftMouseButton = true }
local pendingChoice
-- (A RELOAD MID-CHOICE - VM 2026-11-02: the card stayed on screen for good and the keys did nothing; the scene it was
-- in can't go on after a reload. The card's widget is kept in Saved/WaCaSceneChoice.ini while it is up; Clan Life
-- starting again takes it away.)
local function choicePath() return WaCa.SaveDir() .. "/../WaCaSceneChoice.ini" end
local function keepChoice(var, widget)
    pcall(WaCa.WriteIni, choicePath(), { Choice = { Var = var or "", Widget = widget or "", __order = { "Var", "Widget" } },
        __order = { "Choice" } }, "; WaCa Clan Life - a Choice on screen (taken away if Clan Life reloads)")
end
local function recoverChoice()
    local c = (WaCa.ReadIni(choicePath()) or {})["Choice"] or {}
    if (c.Widget or "") == "" then return end
    keepChoice(nil, nil)
    local w = WaCa.Live(StaticFindObject(c.Widget))
    if w then
        pcall(function() w:RemoveFromParent() end)
        log("events: a reload ended the Choice %s - its card taken away (the scene it was in is over)", tostring(c.Var))
    end
end
local function askChoice(value, done)
    local var, rest = tostring(value):match("^%s*([%w%.%_]+)%s*=%s*(.-)%s*$")
    local parts = {}
    -- (; between them - as a duty's points: | already parts a PlayScene's steps)
    for p in tostring(rest or ""):gmatch("[^;]+") do parts[#parts + 1] = p:match("^%s*(.-)%s*$") end
    if not var or #parts < 3 then
        log("events: Choice needs <variable> = <question>; <answer>; <answer> - got '%s'", tostring(value))
        return done()
    end
    local n = math.min(#parts, 5) - 1
    local speaker, question = parts[1]:match("^(%a[%w']*):%s+(.+)$")
    if not speaker then question = parts[1] end
    local w, menu
    local made, err = pcall(function()
        local controller = pc()
        w = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(controller, WaCa.LoadAsset(DIALOGUE), controller)
        w:AddToViewport(60)
        w.mcGuiTextParagraph:SetText(FText(question))
        w.mcGuiTextParagraph:SetVisibility(4)
        w.mcGuiDialogueTalker.mcGuiTextName:SetText(FText(speaker or ""))
        w.mcGuiDialogueTalker:SetVisibility(speaker and 4 or 1)
        pcall(function() w.mcGuiNext:SetVisibility(1) end)
        -- (the panel's big ring vignette darkened the whole screen without the game's own intro to set it: VM)
        pcall(function() w.mcGuiBaseVfx:SetVisibility(2) end)
        w.CanvasPanelDialog:SetVisibility(4)
        for i = 1, 4 do
            local b = w["mcButton" .. i]
            if i <= n then
                for _, t in ipairs({ "mcGuiTextNormal", "mcGuiTextSelected", "mcGuiTextOver" }) do
                    pcall(function() b[t]:SetText(FText(parts[i + 1])) end)
                end
                pcall(function() b.mcGuiTraitIcon:SetVisibility(1) end)
                b:SetVisibility(4)
            else
                b:SetVisibility(1)
            end
        end
        w:SetVisibility(3)
        menu = true
    end)
    if not made then
        -- (the card, as before: the question and numbered answers - the keys 1-4)
        log("events: Choice %s - the game's answer menu failed (%s), the card instead", var, tostring(err))
        pcall(function() if WaCa.Live(w) then w:RemoveFromParent() end end)
        local lines = { parts[1] }
        for i = 2, n + 1 do lines[#lines + 1] = string.format("%d - %s", i - 1, parts[i]) end
        w = nil
        pcall(function()
            local controller = pc()
            w = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(controller, WaCa.LoadAsset(CARD), controller)
            w:AddToViewport(60)
            w.mcGuiTextInfo:SetText(FText(table.concat(lines, "\n")))
        end)
    end
    pendingChoice = { var = var, n = n, widget = w and (w:GetFullName():gsub("^%S+ ", "")), done = done,
                      answers = parts, menu = menu, pick = 1 }
    keepChoice(var, pendingChoice.widget)
    log("events: Choice %s - %s (%d answers: %s)", var, parts[1], n, menu and "the game's answer menu" or "the card, keys 1-n")
    if menu then
        local mine = pendingChoice
        Events.ChoiceSelect(1)
        -- (the mouse: hovering an answer picks it - polled, the buttons take no hover of their own here)
        local function hover()
            if pendingChoice ~= mine then return end
            local card = WaCa.Live(mine.widget and StaticFindObject(mine.widget))
            if not card then return end
            for i = 1, mine.n do
                local over = false
                pcall(function() over = WaCa.MouseOver(card["mcButton" .. i]) end)
                if over then mine.hovered = i if mine.pick ~= i then Events.ChoiceSelect(i) end break end
                if i == mine.n then mine.hovered = nil end
            end
            ExecuteInGameThreadWithDelay(100, function() pcall(hover) end)
        end
        pcall(hover)
        return
    end
    -- (FITS THE SCREEN - four long answers ran off its foot, VM 2026-11-02: the card's text starts ~44% down and grows
    -- downward, ~ChoiceRoom HUD units free below it (of 2160). Its height is only known after a few drawn frames - the
    -- VM's measure lagged by seconds - so it is measured again every second while the choice is up, and the text
    -- shrunk from its top edge, never below 50%.)
    local mine = pendingChoice
    local lastScale
    local function fit()
        if pendingChoice ~= mine then return end
        local card = mine.widget and StaticFindObject(mine.widget)
        local text = WaCa.Live(card) and WaCa.Live(card.mcGuiTextInfo)
        if not text then return end
        local h = text:GetDesiredSize().Y
        local scale = h > cfg.choiceRoom and math.max(0.5, cfg.choiceRoom / h) or 1
        if scale ~= lastScale then
            text:SetRenderTransformPivot({ X = 0.5, Y = 0 })
            text:SetRenderScale({ X = scale, Y = scale })
            if scale < 1 then log("events: Choice %s - its text %.0f units high, shown at %.0f%%", var, h, scale * 100) end
            lastScale = scale
        end
        ExecuteInGameThreadWithDelay(1000, function() pcall(fit) end)
    end
    pcall(fit)
end
-- the answer picked now on the game's answer menu: its highlight (the game's own CanvasSelected) on that one only
function Events.ChoiceSelect(i)
    local c = pendingChoice
    if not (c and c.menu and i >= 1 and i <= c.n) then return end
    c.pick = i
    local card = WaCa.Live(c.widget and StaticFindObject(c.widget))
    if not card then return end
    for k = 1, c.n do
        pcall(function() card["mcButton" .. k].CanvasSelected:SetVisibility(k == i and 4 or 2) end)
    end
    log("events: Choice %s - on %d (%s)", c.var, i, c.answers[i + 1])
end
local function answerChoice(key)
    local c = pendingChoice
    if not c then return end
    key = tostring(key)
    local n = NUMBER_KEYS[key]
    if c.menu and PICK_KEYS[key] then
        -- (a click answers only over an answer - not anywhere on the screen)
        n = c.hovered
    end
    if not (n and n <= c.n) then return end
    pendingChoice = nil
    keepChoice(nil, nil)
    local w = c.widget and StaticFindObject(c.widget)
    if w and w:IsValid() then pcall(function() w:RemoveFromParent() end) end
    log("events: Choice %s - answer %d (%s)", c.var, n, c.answers[n + 1])
    Events.SetVar(c.var, n)
    -- (always said - SetVar says nothing when the value is the same as before: the same answer twice left a
    -- cutscene's Ask waiting, VM 2026-11-02)
    WaCa.Emit("ChoiceAnswered", c.var, n)
    c.done()
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
local castSpecs = {}         -- "S:name" -> who plays it (events.ini [Cast]: a cat's name, a part, E:<role>)
local castMissed = {}        -- "S:name" -> true once its miss was logged (the retries stay quiet)
local castRetrying = false
local newcomerWait = nil      -- { key = "S:role", go = fn }: a Newcomer step waiting for its role to be bound

-- a newcomer playing a story role (kits.lua): the role's cat is found by the newcomer's name from now on
local function newcomerCast(key, name)
    castSpecs[key] = name
    castMissed[key] = nil
    log("events: [Cast] %s = %s (a newcomer)", key, name)
    pcall(Events.Cast, key)
end

function Events.BindRole(key, cat)
    if type(cat) ~= "string" then cat = cat and (cat:GetFullName():gsub("^%S+ ", "")) end
    bound[key] = cat
    -- (the cat's name in the log - the object path told a writer nothing)
    local who = cat
    pcall(function() who = WaCa.CatName(StaticFindObject(cat)) or cat end)
    log("events: role %s = %s", key, tostring(who))
    WaCa.Emit("RoleBound", key, cat)
    local w = newcomerWait
    if w and w.key == key then newcomerWait = nil pcall(w.go) end
    -- (every bound role for other mods - WaCa Cutscenes casts S:<role> from it)
    WaCa.Publish("roles.cast", bound, true)
end

-- THE CAST (events.ini [Cast] - and a story pack's content/events.ini - library exercise 2026-10-30: a pack's own roles
-- without Lua): S:<role> = who plays it - a cat's name as the game shows it (Mossfeather - a WaCa Looks roster cat
-- too), a part of your clan (Leader, Deputy, MedicineCat ...) or E:<story role>. Bound when the world is up and
-- again at each third (the cat may not have been about); an unbound one is tried whenever a scene asks for it.
-- Events.Cast(key) binds one (true when it found its cat), Events.Cast() all of them.
function Events.Cast(only)
    local cats = WaCa.Cats and WaCa.Cats() or {}
    local any = false
    for key, spec in pairs(castSpecs) do
        -- (a cat brought in by the scenes - Rogue[:<Name>], Clan:<Clan>[.<Part>] - isn't looked for in the world: WaCa
        -- Cutscenes spawns it per scene, from the specs published as roles.specs)
        if spec:match("^Rogue") or spec:match("^Clan:") then
        elseif not only or key == only then
            local cat
            local ek, er = Events.Role(spec)
            if spec:match("^E:") or spec == "Leader" or spec == "Deputy" or spec == "MedicineCat" then
                cat = Events.Who(spec:match("^E:") and spec or er)
            else
                for _, c in ipairs(cats) do
                    if c.name:lower() == spec:lower() then cat = c.actor break end
                end
                -- (a cat that isn't drawn just now - far from your cat - is still in the world: WaCa Cats lists only
                -- the drawn ones, and the pack's herbalist went uncast for 2+ minutes after a load and missed a
                -- cutscene, VM 2026-11-02; the scenes bring an undrawn cat in themselves, as they do the Leader)
                if not cat then
                    for _, cls in ipairs({ "SwtAdventureQuestActor", "SwtAdventureWalkingNPC" }) do
                        for _, a in ipairs(FindAllOf(cls) or {}) do
                            pcall(function()
                                if not cat and a:IsValid() and (WaCa.CatName(a) or ""):lower() == spec:lower()
                                    and not a:GetClass():GetFName():ToString():find("Filler") then
                                    cat = a
                                end
                            end)
                        end
                    end
                end
            end
            if cat and cat:IsValid() then
                local path = (cat:GetFullName():gsub("^%S+ ", ""))
                if bound[key] ~= path then Events.BindRole(key, cat) end
                any = true
            elseif not only and not castMissed[key] then
                castMissed[key] = true
                -- (a misspelled name - "Nighthart" - was tried every 10 s for good, with no hint: the nearest name of the
                -- save's cats, when one is close; library pre-work 2026-11-03)
                local hint = ""
                pcall(function()
                    if spec:match("^E:") or spec:match("^%u%l+:") then return end
                    local best, bestD
                    local names = {}
                    for _, c in ipairs(WaCa.StoryCats() or {}) do if c.name then names[c.name] = true end end
                    for _, c in ipairs(cats) do if c.name then names[c.name] = true end end
                    for n in pairs(names) do
                        local a2, b2 = spec:lower(), n:lower()
                        local prev = {}
                        for j = 0, #b2 do prev[j] = j end
                        for i = 1, #a2 do
                            local cur = { [0] = i }
                            for j = 1, #b2 do
                                cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + ((a2:sub(i, i) == b2:sub(j, j)) and 0 or 1))
                            end
                            prev = cur
                        end
                        if not bestD or prev[#b2] < bestD then best, bestD = n, prev[#b2] end
                    end
                    if best and bestD > 0 and bestD <= 2 then hint = " - did you mean " .. best .. "?" end
                end)
                log("events: [Cast] %s = %s - no such cat about yet (tried again every 10 s till it is)%s", key, spec, hint)
            end
        end
    end
    -- (a cat of a camp you're far from isn't in the world yet - VM 2026-10-30: the pack's herbalist went uncast till the
    -- next third after the player walked into camp; so an unbound role is tried again while it is unbound)
    if not only and not castRetrying then
        for key in pairs(castSpecs) do
            local a = bound[key] and StaticFindObject(bound[key])
            if not (a and a:IsValid()) then
                castRetrying = true
                ExecuteInGameThreadWithDelay(10000, function() castRetrying = false; pcall(Events.Cast) end)
                break
            end
        end
    end
    return any
end

-- who plays each of the mods' own roles, as written ([Cast] S:<role> = ...) - the story check reads it
function Events.CastSpecs() return castSpecs end
-- (roles Clan Life casts ITSELF, in play - a pack may use them without a [Cast] line; the checkers count them as cast.
-- Library exercise 2026-11-05: ScentLesson's S:mentor gave four false 'has no cat' problems)
Events.BUILTIN_ROLES = { ["S:mentor"] = "your mentor (from the game's own text)" }

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
        if a and a:IsValid() then return a end
        -- (cast in events.ini [Cast] but not bound yet - its cat wasn't about: try now)
        if castSpecs[name] and Events.Cast(name) then
            a = StaticFindObject(bound[name])
            return a and a:IsValid() and a or nil
        end
        return nil
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
    if fallback then return fallback end
    -- (BY NAME - library exercise 2026-11-03: '@ Emberheart' found no cat; who resolved roles only. The world's cats by
    -- their name, a mod's spawned ones too - WaCa.Cats - the nearest of that name)
    if WaCa.Cats then
        local want = tostring(role or name):lower()
        for _, c in ipairs(WaCa.Cats()) do
            if c.name and c.name:lower() == want then return c.actor end
        end
    end
    return nil
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
    Dig = { "AM_Interact_Dig" },
}
local MONTAGES = "/Game/Art/Characters/CatMaster/Animations/Montages/"
local FADE = 0.8

-- (a pose with variants: each cat always the same one, by its name - nothing here is chance)
local function montage(pose, cat)
    local names = POSES[pose]
    local pick = 1
    if names and #names > 1 then
        local key = 0
        pcall(function() for ch in cat:GetFName():ToString():gmatch(".") do key = key + ch:byte() end end)
        pick = key % #names + 1
    end
    local path = names and (MONTAGES .. names[pick]) or pose
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
        for _, path in ipairs(ctx and ctx.anchors or {}) do
            local a = StaticFindObject(path)
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
    local mesh
    pcall(function() mesh = cat:GetComponentByClass(meshClass) end)
    return WaCa.PlayMontage(mesh, m) ~= nil               -- (null-safe: no anim instance, no mesh)
end

local function stopMontage(cat)
    if pcall(function() cat:StopAnimMontage(nil) end) then return end
    meshClass = meshClass or StaticFindObject("/Script/Engine.SkeletalMeshComponent")
    local mesh
    pcall(function() mesh = cat:GetComponentByClass(meshClass) end)
    WaCa.StopMontage(mesh)
end

function Events.Pose(pose, who, ctx)
    local n = 0
    for _, cat in ipairs(poseTargets(who, ctx)) do
        local m = montage(pose, cat)
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
            -- (its behaviour tree stopped - PauseLogic didn't: its own pacing kept overriding the walk-in, cats walked
            -- away from their seats at full speed; StopLogic stops it - VM 2026-10-29)
            if pcall(function() ctl.BrainComponent:StopLogic("WaCa gathering") end) then held[#held + 1] = "brain" end
        else
            pcall(function() ctl.BrainComponent:RestartLogic() end)
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

-- a scene has cats staged (a Groups / Gather step until its Release): other parts wait for it - walkers.lua's turn
-- changed the walkers' looks and names between the meal and sharing tongues (VM 2026-10-29). Declared
-- above Gather: below it, Gather's staging = true set a global and the walkers never waited (2026-11-04)
local staging = false
function Events.Staging() return staging end
local keepGathered  -- (defined with the reload code below; Gather above it called a nil global - the screen stayed
                    -- faded and the step never finished, 2026-11-04)

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
    staging = true
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
        keepGathered(ctx.gathered)
        fadeScreen(1, 0, FADE)
        ExecuteInGameThreadWithDelay(math.floor(FADE * 1000), done)
    end)
end

-- walkers.lua on: the camp's named cats move (its walker took the nameless walking cats out) - they come to the scenes
-- themselves, walked to their seats by it, instead of standing where they are
local function namedWalk()
    local ok, W = pcall(require, "walkers")
    return (ok and W and W.On and W.On()) and W or nil
end

-- the staged cats back where they were (their poses stopped, their AI on again; a cat shown only for the scene hidden
-- again)
local shownForScene = {}
local function putBack(g)
    for _, e in ipairs(g or {}) do
        local a = StaticFindObject(e.path)
        if a and a:IsValid() then
            stopMontage(a)
            if shownForScene[e.path] then
                shownForScene[e.path] = nil
                pcall(function() a.SkeletalMeshComponent:SetVisibility(false, true) end)
            end
            if e.walker then
                -- (a named cat walks home - walkers.lua)
                local W = namedWalk()
                if W then W.Unstage(a) end
            else
                local ok, err = pcall(function() a:K2_SetActorLocationAndRotation(e.loc, e.rot, false, {}, true) end)
                if not ok then log("events: release - %s stays: %s", e.path, tostring(err)) end
                holdAI(a, false)
            end
        end
    end
end

-- A RELOAD WHILE CATS ARE GATHERED (VM 2026-11-02: Clan Life reloaded mid-'Groups: Tongues' - six cats stayed in their
-- circles, their AI stopped, for good; the story check's Watch = 1 reloads Clan Life whenever a writer saves a story
-- file): the gathered cats - where they came from, whether the scene showed them - are kept in
-- Saved/WaCaSceneGathered.ini while a scene holds them; Clan Life starting again puts them back.
local function gatheredPath() return WaCa.SaveDir() .. "/../WaCaSceneGathered.ini" end
function keepGathered(g)
    local sec, order = {}, {}
    for i, e in ipairs(g or {}) do
        if e.loc then
            local k = "c" .. i
            sec[k] = string.format("%s|%.1f %.1f %.1f %.1f|%s", e.path, e.loc.X, e.loc.Y, e.loc.Z, e.rot and e.rot.Yaw or 0,
                shownForScene[e.path] and "shown" or "")
            order[#order + 1] = k
        end
    end
    sec.__order = order
    pcall(WaCa.WriteIni, gatheredPath(), { Gathered = sec, __order = { "Gathered" } },
        "; WaCa Clan Life - cats a scene has gathered (put back if Clan Life reloads)")
end
local function clearGathered()
    pcall(WaCa.WriteIni, gatheredPath(), { Gathered = { __order = {} }, __order = { "Gathered" } }, "; WaCa Clan Life - nobody gathered")
end
local function recoverGathered()
    local ini = WaCa.ReadIni(gatheredPath()) or {}
    local n = 0
    for k, v in pairs(ini["Gathered"] or {}) do
        local path, x, y, z, yaw, flags = tostring(v):match("^(.-)|(%S+) (%S+) (%S+) (%S+)|(.*)$")
        local a = k ~= "__order" and path and StaticFindObject(path)
        if a and a:IsValid() then
            pcall(function() stopMontage(a) end)
            pcall(function() a:K2_SetActorLocationAndRotation({ X = tonumber(x), Y = tonumber(y), Z = tonumber(z) },
                { pitch = 0, Yaw = tonumber(yaw), Roll = 0 }, false, {}, true) end)
            pcall(function() holdAI(a, false) end)
            if flags:find("shown") then pcall(function() a.SkeletalMeshComponent:SetVisibility(false, true) end) end
            n = n + 1
        end
    end
    clearGathered()
    if n > 0 then log("events: %d cat(s) still gathered by a scene before a reload - back in their places", n) end
end
function Events.RecoverGathered() pcall(recoverGathered) pcall(recoverChoice) end
-- (a fresh start - no world: the records are from a game that has ended; a widget / actor name in them could belong to
-- something else in this one)
function Events.ForgetRecords() pcall(clearGathered) pcall(keepChoice, nil, nil) end

-- Groups: Tongues | Prey   the evening in camp (operator 2026-10-28): not one ring but small groups - sharing tongues in
--                          circles of 2-3, sharing prey in 2s and 3s with now and then a 4 around a big piece. Who sits
--                          with whom follows the cats' ties (config/relations.ini): cats with a tension never share a
--                          group, the leader only sits with its mate and / or the deputy (else apart), apprentices with
--                          apprentices first, then elders with elders, warriors with warriors. Your cat joins the
--                          group that suits it best, right where it stands; the others are placed in front of the
--                          camera (it sits ~1 m behind your cat), each group a small circle facing its own middle.
-- (a cat's job by the game's own EGiverRole, read from the enum - the clan's jobs only, Kit .. Leader)
local ROLE_NAMES = {}
pcall(function()
    local clan = { Kit = true, Apprentice = true, Elder = true, Warrior = true, MedicineCat = true, Queen = true,
                   Deputy = true, Leader = true }
    StaticFindObject("/Script/SwtQuest.EGiverRole"):ForEachName(function(n, v)
        local name = n:ToString():gsub("^.*::", "")
        if clan[name] then ROLE_NAMES[v] = name end
    end)
end)
local RANK_ROLES = { [0] = "Apprentice", "Apprentice", "Warrior", "Deputy", "Leader" }
local relations = { mates = {}, tensions = {}, friends = {}, pairs = {} }

local function tie(set, a, b)
    set[a] = set[a] or {}
    set[b] = set[b] or {}
    set[a][b], set[b][a] = true, true
end

local function readRelations(modDir)
    local ini = WaCa.ReadContent(modDir .. "/config/relations.ini", "relations") or {}
    local n = 0
    for section, set in pairs({ Mates = relations.mates, Tensions = relations.tensions, Friends = relations.friends,
                                Pairs = relations.pairs }) do
        for a, list in pairs(ini[section] or {}) do
            if a ~= "__order" and a ~= "__mods" and type(list) == "string" then
                for raw in list:gmatch("[^,]+") do
                    local b = raw:match("^%s*(.-)%s*$")
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

-- THE CAMP CATS KEEP THEIR NAMES: the game rolls the walking camp cats' names anew at every load (VM 2026-10-29:
-- Oakpatch, Brookwhisker ... one load, Owlfeather, Rainpelt ... the next), so a tie by name (relations.ini) or a
-- story beat wouldn't hold. Each walking cat belongs to a placed spawn point (its move handler's SpawnPointRef -
-- BP_NPC_TargetPoint_C_66 ..., the same every load); the name it had there the first time is kept per save (the
-- sidecar WrcGame.<slot>.WaCaCampCats.ini) and given back to the cat at every later load.
local namesFor
local function keepCampNames()
    -- (walkers.lua on: the walkers wear the camp's named cats - nothing of their own to keep)
    local okW, walkersOn = pcall(function() return require("walkers").On() end)
    if okW and walkersOn then return end
    local slot = WaCa.CurrentSlot()
    local path = WaCa.SlotFile("WaCaCampCats")
    if not (slot and path) then return end
    local ini = WaCa.ReadIni(path) or {}
    local names = ini["Names"] or {}
    local kept, added, failed, changed = 0, 0, 0, false
    for _, c in ipairs(FindAllOf("SwtAdventureWalkingNPC") or {}) do
        pcall(function()
            local spot = c.QuestMoveComponentHandler.SpawnPointRef
            if not (spot and spot:IsValid()) then return end
            local key = spot:GetFName():ToString()
            local cd = WaCa.CustomData(c)
            if not cd then return end
            local now = cd.PrefixNameId:ToString() .. "|" .. cd.SuffixNameId:ToString()
            local saved = names[key]
            if saved and saved ~= now then
                local pre, suf = saved:match("^([^|]*)|(.*)$")
                cd.PrefixNameId = pre
                cd.SuffixNameId = suf
                local again = WaCa.CustomData(c) or cd
                if again.PrefixNameId:ToString() == pre and again.SuffixNameId:ToString() == suf then
                    kept = kept + 1
                else
                    failed = failed + 1
                end
            elseif saved then
                kept = kept + 1
            else
                names[key] = now
                added = added + 1
                changed = true
            end
        end)
    end
    if changed then
        local order = {}
        for k in pairs(names) do if k ~= "__order" then order[#order + 1] = k end end
        table.sort(order)
        names.__order = order
        WaCa.WriteIni(path, { Names = names, __order = { "Names" } },
            "; WaCa Clan Life - this save's camp cats: the name each walking cat has at its spawn point (events.lua)")
    end
    namesFor = slot
    log("events: camp cats - %d name(s) kept from this save, %d new%s", kept, added,
        failed > 0 and (", " .. failed .. " couldn't be given back") or "")
end

-- a camp cat as the groups see it: its name (the game's own: name ids -> STR_CAT_NAME<n><_SUFFIX>), role and clan
local function identity(cat)
    local who = { cat = cat }
    pcall(function()
        local cd = WaCa.CustomData(cat)
        if not cd then return end
        who.role = ROLE_NAMES[cd.Role] or tostring(cd.Role)
        who.clan = clanName(cd.ClanType)
        local name = WaCa.GetText(cd.PrefixNameId:ToString() .. cd.SuffixNameId:ToString())
        if name ~= "" then who.name = name end
    end)
    who.name = who.name or (cat:GetFName():ToString())
    return who
end

-- THE STORY'S LEVERS on who sits with whom (operator 2026-10-29: "making pairs out of apprentices by chance is fine,
-- but we need to be able to force specific pairs when the story requires it, or block certain pairs if the cats
-- don't like each other"): relations.ini [Pairs] / [Tensions], and story steps Pair: A & B / Part: A & B (kept with
-- the save as the story variables "Pair:A & B" / "Part:A & B"; Set: Pair:A & B = 0 lifts one)
local function pairKey(a, b)
    if a.name < b.name then return a.name .. " & " .. b.name end
    return b.name .. " & " .. a.name
end
local function storyVar(name)
    local ok, v = pcall(function() return Events.Var(name) end)
    return ok and tonumber(v) or 0
end
local function forcedPair(a, b)
    return (relations.pairs[a.name] and relations.pairs[a.name][b.name]) or storyVar("Pair:" .. pairKey(a, b)) >= 1
end
local function blockedPair(a, b)
    return (relations.tensions[a.name] and relations.tensions[a.name][b.name]) or storyVar("Part:" .. pairKey(a, b)) >= 1
end

local function getsOn(a, b)
    if a.anchor and b.anchor then return false end          -- (two cats that stay put can't sit together)
    if blockedPair(a, b) then return false end
    -- the leader: only its mate and / or the deputy
    for _, pair in ipairs({ { a, b }, { b, a } }) do
        local l, o = pair[1], pair[2]
        if l.role == "Leader" and not (o.role == "Deputy" or (relations.mates[l.name] and relations.mates[l.name][o.name])) then
            return false
        end
    end
    return true
end

-- WHO SITS WITH WHOM (operator 2026-10-29): what carries meaning is fixed - "always leader and deputy with each other
-- unless an event happens, e.g. the leader is ill" - and chance only picks among cats where it doesn't matter, with a
-- lever for the story everywhere ("some randomness is fine but we need a control lever / override"):
--   1. the leader with its mate(s) and the deputy - LeaderAway >= 1: the leader sits nowhere (ill, away);
--      DeputyAway >= 1: the deputy isn't there. A leader with neither sits alone.
--   2. queens with their kits.
--   3. mates and forced pairs (Pair) together; then by role - apprentices with apprentices, medicine cats, elders,
--      warriors - in 3s and 2s (never one left alone: 4 -> 2 + 2, 7 -> 3 + 2 + 2), shuffled by chance within the
--      role, friends next to each other.
--   4. tensions and blocked pairs (Part) never together (nor two cats that stay put); a cat that can't sit with its
--      own kind joins the first group with room it gets on with.
--   5. sharing prey: now and then a group of 4 round a big piece (events.ini BigPreyChance); BigPrey >= 1 forces it,
--      NoBigPrey >= 1 rules it out.
local function storyFlag(name)
    local ok, yes = pcall(function() return Events.Check(name .. " >= 1") end)
    return ok and yes == true
end

local function tied(set, a, b) return set[a.name] and set[a.name][b.name] or false end

local function chunkSizes(n, four)
    if n <= 0 then return {} end
    if four and n >= 4 then
        local rest = chunkSizes(n - 4)
        if #rest == 1 and rest[1] == 1 then return { 2, 3 } end      -- (5: 2 + 3, nobody alone)
        table.insert(rest, 1, 4)
        return rest
    end
    if n <= 3 then return { n } end
    if n == 4 then return { 2, 2 } end
    local out = {}
    local left = n
    while left > 0 do
        if left == 4 then out[#out + 1] = 2 out[#out + 1] = 2 left = 0
        elseif left <= 3 then out[#out + 1] = left left = 0
        else out[#out + 1] = 3 left = left - 3 end
    end
    return out
end

-- the cats into groups; returns the groups (lists of identities) and the cats that sit apart
local function makeGroups(cats, kind)
    local ROLE_ORDER = { Leader = 1, Deputy = 2, Queen = 3, Kit = 4, Apprentice = 5, MedicineCat = 6, Elder = 7, Warrior = 8 }
    local pool = {}
    for _, c in ipairs(cats) do pool[#pool + 1] = c end
    table.sort(pool, function(x, y)
        local a, b = ROLE_ORDER[x.role] or 9, ROLE_ORDER[y.role] or 9
        if a ~= b then return a < b end
        return x.name < y.name
    end)
    local used, groups, apart = {}, {}, {}
    local function free(c) return not used[c] end
    local function fits(c, g)
        for _, m in ipairs(g) do if not getsOn(c, m) then return false end end
        return true
    end
    local big = kind == "Prey" and not storyFlag("NoBigPrey")
        and (storyFlag("BigPrey") or math.random() * 100 < cfg.bigPreyChance)
    local maxSize = big and 4 or 3

    -- 1. the leader's group
    local leader
    for _, c in ipairs(pool) do if c.role == "Leader" then leader = c break end end
    if leader then
        used[leader] = true
        if storyFlag("LeaderAway") then
            apart[#apart + 1] = leader
        else
            local g = { leader }
            for _, c in ipairs(pool) do
                if free(c) and tied(relations.mates, leader, c) and fits(c, g) then g[#g + 1] = c used[c] = true end
            end
            if not storyFlag("DeputyAway") then
                for _, c in ipairs(pool) do
                    if free(c) and c.role == "Deputy" and fits(c, g) then g[#g + 1] = c used[c] = true break end
                end
            end
            if #g >= 2 then groups[#groups + 1] = g else apart[#apart + 1] = leader end
        end
    end
    -- (a deputy kept away by a story event sits nowhere)
    if storyFlag("DeputyAway") then
        for _, c in ipairs(pool) do if free(c) and c.role == "Deputy" then used[c] = true apart[#apart + 1] = c end end
    end

    -- 2. queens with their kits
    for _, q in ipairs(pool) do
        if free(q) and q.role == "Queen" then
            local g = { q }
            used[q] = true
            for _, k in ipairs(pool) do
                if free(k) and k.role == "Kit" and #g < maxSize and fits(k, g) then g[#g + 1] = k used[k] = true end
            end
            if #g >= 2 then groups[#groups + 1] = g else used[q] = nil end
        end
    end

    -- 3. mates and forced pairs together
    for _, a in ipairs(pool) do
        if free(a) then
            for _, b in ipairs(pool) do
                if b ~= a and free(b) and (tied(relations.mates, a, b) or forcedPair(a, b)) and getsOn(a, b) then
                    local g = { a, b }
                    used[a], used[b] = true, true
                    for _, c in ipairs(pool) do
                        if free(c) and #g < maxSize and (tied(relations.friends, a, c) or tied(relations.friends, b, c))
                            and fits(c, g) then g[#g + 1] = c used[c] = true end
                    end
                    groups[#groups + 1] = g
                    break
                end
            end
        end
    end

    -- 3b. by role: each role's cats in order, a cat's friends right after it, cut into 3s and 2s
    local buckets = { "Apprentice", "MedicineCat", "Elder", "Warrior", "Deputy", "Queen", "Kit" }
    local single = {}
    for _, role in ipairs(buckets) do
        local list = {}
        local placed = {}
        -- (chance picks who sits with whom within the role - a fresh draw every time)
        local members = {}
        for _, c in ipairs(pool) do if free(c) and c.role == role then members[#members + 1] = c end end
        for i = #members, 2, -1 do
            local j = math.random(i)
            members[i], members[j] = members[j], members[i]
        end
        for _, c in ipairs(members) do
            if free(c) and c.role == role and not placed[c] then
                list[#list + 1] = c
                placed[c] = true
                for _, f in ipairs(pool) do
                    if free(f) and f.role == role and not placed[f] and tied(relations.friends, c, f) then
                        list[#list + 1] = f
                        placed[f] = true
                    end
                end
            end
        end
        local four = big and role == "Warrior"
        if four then big = false end
        for _, size in ipairs(chunkSizes(#list, four)) do
            local g = {}
            for _, c in ipairs(list) do
                if #g >= size then break end
                if free(c) and fits(c, g) then g[#g + 1] = c used[c] = true end
            end
            if #g >= 2 then groups[#groups + 1] = g
            else for _, c in ipairs(g) do used[c] = nil end end
        end
        for _, c in ipairs(list) do if free(c) then single[#single + 1] = c end end
    end

    -- 4. the rest join the first group with room they get on with; two of them that fit each other sit together;
    -- whoever is left sits apart
    local rest = {}
    for _, c in ipairs(single) do
        local home
        for _, g in ipairs(groups) do
            local lead = false
            for _, m in ipairs(g) do if m.role == "Leader" then lead = true end end
            if not lead and #g < maxSize and fits(c, g) then home = g break end
        end
        if home then home[#home + 1] = c used[c] = true else rest[#rest + 1] = c end
    end
    local i = 1
    while i <= #rest do
        local c = rest[i]
        local partner
        for j = i + 1, #rest do
            if free(rest[j]) and getsOn(c, rest[j]) then partner = rest[j] break end
        end
        if partner and free(c) then
            groups[#groups + 1] = { c, partner }
            used[c], used[partner] = true, true
        elseif free(c) then
            apart[#apart + 1] = c
            used[c] = true
        end
        i = i + 1
    end
    return groups, apart
end

-- the grouping rules checked on a made-up roster (the event WaCaGroupsSelfTest from any mod / the test harness): the
-- camp's walking cats are often all warriors, so the leader / apprentice rules need a roster that has them. Logs PASS
-- or FAIL per rule over 20 groupings of each kind; the clan's own ties are left as they were.
local function groupsSelfTest()
    local saved = relations
    relations = { mates = {}, tensions = {}, friends = {}, pairs = {} }
    tie(relations.mates, "Leaderstar", "Matepelt")
    tie(relations.tensions, "Thornclaw", "Briarfang")
    tie(relations.pairs, "Fernpaw", "Ashfur")                  -- (a story pair across roles)
    local roster = {
        { name = "Leaderstar", role = "Leader" }, { name = "Matepelt", role = "Warrior" },
        { name = "Deputyfur", role = "Deputy" }, { name = "Sparrowpaw", role = "Apprentice" },
        { name = "Mosspaw", role = "Apprentice" }, { name = "Fernpaw", role = "Apprentice" },
        { name = "Thornclaw", role = "Warrior" }, { name = "Briarfang", role = "Warrior" },
        { name = "Daisytail", role = "Queen" }, { name = "Pebblekit", role = "Kit" },
        { name = "Ashfur", role = "Warrior" }, { name = "Hollypaw", role = "Apprentice" },
    }
    local function where(groups)
        local at = {}
        for i, g in ipairs(groups) do for _, m in ipairs(g) do at[m.name] = i end end
        return at
    end
    local fails = {}
    local function check(label, ok) if not ok then fails[label] = (fails[label] or 0) + 1 end end
    local pairings = {}
    pcall(function() Events.SetVar("Part:" .. pairKey({ name = "Mosspaw" }, { name = "Sparrowpaw" }), 1) end)
    for _, kind in ipairs({ "Tongues", "Prey" }) do
        for _ = 1, 20 do
            local groups, apart = makeGroups(roster, kind)
            local at = where(groups)
            check("leader with deputy + mate", at.Leaderstar ~= nil and at.Leaderstar == at.Deputyfur and at.Leaderstar == at.Matepelt)
            check("tension apart", at.Thornclaw == nil or at.Thornclaw ~= at.Briarfang)
            check("Part (story) apart", at.Mosspaw == nil or at.Mosspaw ~= at.Sparrowpaw)
            check("Pairs together", at.Fernpaw ~= nil and at.Fernpaw == at.Ashfur)
            check("kit with its queen", at.Pebblekit ~= nil and at.Pebblekit == at.Daisytail)
            for _, g in ipairs(groups) do check("sizes 2-4", #g >= 2 and #g <= 4) end
            check("nobody alone", #apart == 0)
            pairings[(at.Hollypaw == at.Mosspaw) and "Hollypaw+Mosspaw" or "Hollypaw+Sparrowpaw"] = true
        end
    end
    pcall(function() Events.SetVar("Part:" .. pairKey({ name = "Mosspaw" }, { name = "Sparrowpaw" }), 0) end)
    pcall(function() Events.SetVar("LeaderAway", 1) end)
    local _, apart = makeGroups(roster, "Tongues")
    local leaderApart = false
    for _, m in ipairs(apart) do if m.name == "Leaderstar" then leaderApart = true end end
    check("LeaderAway: the leader apart", leaderApart)
    pcall(function() Events.SetVar("LeaderAway", 0) end)
    relations = saved
    local results = {}
    for _, label in ipairs({ "leader with deputy + mate", "tension apart", "Part (story) apart", "Pairs together",
                             "kit with its queen", "sizes 2-4", "nobody alone", "LeaderAway: the leader apart" }) do
        results[#results + 1] = label .. ": " .. (fails[label] and ("FAIL x" .. fails[label]) or "PASS")
    end
    local seen = {}
    for k in pairs(pairings) do seen[#seen + 1] = k end
    table.sort(seen)
    log("events: groups self-test (40 draws) - %s; chance among apprentices: %s", table.concat(results, ", "),
        table.concat(seen, " / "))
end

function Events.Groups(kind, where, ctx, done)
    kind = (kind == "Prey") and "Prey" or "Tongues"
    local pawn = pc() and pc().Pawn
    local place = placeOf(where)
    if not (pawn and place) then return done() end
    if namesFor ~= WaCa.CurrentSlot() then pcall(keepCampNames) end
    local myClan = WaCa.PlayerClan and WaCa.PlayerClan() or nil
    local cats = {}
    for _, c in ipairs(clanmatesNear(place, 40, cfg.gatherRadius)) do
        local who = identity(c)
        if not (myClan and who.clan and who.clan ~= myClan) then cats[#cats + 1] = who end
    end
    -- the camp's named cats (its quest cats: Lionstar, Troutwing ...) take part where they are - moved, they don't
    -- draw (VM 2026-10-28) - each one the middle of its group; the walking cats and yours come to them. Only the ones
    -- the game shows, of your clan, in a clan role (not rogues / StarClan).
    for _, a in ipairs(FindAllOf("SwtAdventureQuestActor") or {}) do
        pcall(function()
            if not (a:IsValid() and not a.bHidden and a.SkeletalMeshComponent:IsVisible()) then return end
            local q = a:K2_GetActorLocation()
            if math.sqrt((q.X - place.X) ^ 2 + (q.Y - place.Y) ^ 2) > cfg.gatherRadius then return end
            local who = identity(a)
            who.role = ROLE_NAMES[a.GiverRole] or who.role
            who.named = true
            who.anchor = namedWalk() == nil
            local inRole = false
            for _, r in pairs(ROLE_NAMES) do if r == who.role then inRole = true end end
            if inRole and not (myClan and who.clan and who.clan ~= myClan) then cats[#cats + 1] = who end
        end)
    end
    -- (A PAIR'S OTHER CAT: the story put two cats together - Pair: A & B, relations.ini [Pairs] - and one takes part
    -- while the other isn't drawn or is across camp: it comes too - shown while it takes part, hidden again when the
    -- cats go back (library exercise 2026-11-02: Pair: Mossfeather & Otterfeather, the deputy far off and not drawn -
    -- she wasn't in any group, the pair did nothing)
    do
        local inIt = {}
        for _, w in ipairs(cats) do inIt[w.name] = true end
        local wanted = {}
        for k, v in pairs(Events.VarsLike("Pair:")) do
            local a, b = k:match("^Pair:(.-) & (.+)$")
            if a and (tonumber(v) or 0) >= 1 then
                if inIt[a] and not inIt[b] then wanted[b] = a elseif inIt[b] and not inIt[a] then wanted[a] = b end
            end
        end
        for a, others in pairs(relations.pairs) do
            for b in pairs(others) do if inIt[a] and not inIt[b] then wanted[b] = a end end
        end
        for name, partner in pairs(wanted) do
            local found
            for _, a in ipairs(FindAllOf("SwtAdventureQuestActor") or {}) do
                pcall(function()
                    if found or not a:IsValid() or a:GetClass():GetFName():ToString():find("Filler") then return end
                    if (WaCa.CatName(a) or "") ~= name then return end
                    local who = identity(a)
                    who.role = ROLE_NAMES[a.GiverRole] or who.role
                    who.named, who.anchor = true, false
                    if not (myClan and who.clan and who.clan ~= myClan) then
                        found = who
                        -- (the walkers, when on, show and hide a cat they stage themselves)
                        if not namedWalk() and not a.SkeletalMeshComponent:IsVisible() then
                            a.SkeletalMeshComponent:SetVisibility(true, true)
                            shownForScene[(a:GetFullName():gsub("^%S+ ", ""))] = true
                        end
                    end
                end)
            end
            if found then
                cats[#cats + 1] = found
                log("events: groups - %s comes too (paired with %s by the story)", name, partner)
            else
                log("events: groups - %s is paired with %s but isn't in the world - %s sits without", name, partner, partner)
            end
        end
    end
    if #cats == 0 then
        log("events: groups - no clan cats within %.0f m", cfg.gatherRadius / 100)
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
    staging = true
    fadeScreen(0, 1, FADE)
    local walking = {}
    ExecuteInGameThreadWithDelay(math.floor(FADE * 1000) + 100, function()
        -- (a scene of several group steps - the meal, then sharing tongues: the last step's cats go back first)
        if before and #before > 0 then
            putBack(before)
            pcall(function() stopMontage(pawn) end)
        end
        for _, path in ipairs(ctx.anchors or {}) do
            local a = StaticFindObject(path)
            if a and a:IsValid() then stopMontage(a) end
        end
        local facing = 0
        pcall(function() facing = pc().PlayerCameraManager:GetCameraRotation().Yaw end)
        local fwd, side = math.rad(facing), math.rad(facing + 90)
        local n, k = 0, 0
        ctx.anchors = {}
        for _, g in ipairs(groups) do
            local anchor
            for _, m in ipairs(g) do if m.anchor then anchor = m end end
            if anchor then
                -- round a cat that stays put: the middle just off it towards the camp's middle; the others (your cat
                -- too, set down in its seat) round the middle from its far side
                pcall(function()
                    local aq = anchor.cat:K2_GetActorLocation()
                    table.insert(ctx.anchors, (anchor.cat:GetFullName():gsub("^%S+ ", "")))
                    local dx, dy = place.X - aq.X, place.Y - aq.Y
                    local len = math.max(1, math.sqrt(dx * dx + dy * dy))
                    local mid = { X = aq.X + dx / len * cfg.groupRadius, Y = aq.Y + dy / len * cfg.groupRadius, Z = aq.Z }
                    local base = math.atan(aq.Y - mid.Y, aq.X - mid.X)
                    local slot = 0
                    for _, m in ipairs(g) do
                        if not m.anchor then
                            slot = slot + 1
                            local a = base + slot / #g * 2 * math.pi
                            local spot = { X = mid.X + math.cos(a) * cfg.groupRadius,
                                           Y = mid.Y + math.sin(a) * cfg.groupRadius, Z = aq.Z + 20 }
                            local yaw = math.deg(math.atan(mid.Y - spot.Y, mid.X - spot.X))
                            if m.player then
                                pawn:K2_SetActorLocationAndRotation(spot, { pitch = 0, Yaw = yaw, Roll = 0 }, false, {}, true)
                            else
                                local cat = m.cat
                                local l, r = cat:K2_GetActorLocation(), cat:K2_GetActorRotation()
                                table.insert(ctx.gathered, { path = (cat:GetFullName():gsub("^%S+ ", "")),
                                    loc = { X = l.X, Y = l.Y, Z = l.Z }, rot = { pitch = r.pitch, Yaw = r.Yaw, Roll = r.Roll } })
                                if cfg.walkIn then
                                    -- (from the open ground towards the camp's middle, like the other groups: set down
                                    -- past the seat - by the dens, where the named cats sit - 0-1 of 6 got there:
                                    -- VM 2026-10-29)
                                    local sx, sy = spot.X - place.X, spot.Y - place.Y
                                    local sl = math.max(1, math.sqrt(sx * sx + sy * sy))
                                    local back = math.min(cfg.walkFrom, sl - cfg.walkReach)
                                    local from = { X = spot.X - sx / sl * back, Y = spot.Y - sy / sl * back, Z = spot.Z }
                                    if back < cfg.walkReach then from = { X = spot.X, Y = spot.Y, Z = spot.Z } end
                                    cat:K2_SetActorLocationAndRotation(from, { pitch = 0, Yaw = yaw, Roll = 0 }, false, {}, true)
                                    walking[#walking + 1] = { cat = cat, spot = spot, yaw = yaw }
                                else
                                    cat:K2_SetActorLocationAndRotation(spot, { pitch = 0, Yaw = yaw, Roll = 0 }, false, {}, true)
                                    holdAI(cat, true)
                                end
                                n = n + 1
                            end
                        end
                    end
                end)
            else
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
                    local W = m.named and namedWalk() or nil
                    table.insert(ctx.gathered, { path = (cat:GetFullName():gsub("^%S+ ", "")), walker = W ~= nil,
                                                 loc = { X = l.X, Y = l.Y, Z = l.Z }, rot = { pitch = r.pitch, Yaw = r.Yaw, Roll = r.Roll } })
                    if W then
                        -- (a named cat walks over from where it is - walkers.lua's own walk)
                        -- (at the scene's walk-in speed; its time its own way there + 4 s - from their homes across camp
                        -- they came 10-18 m and a flat WalkSeconds set 7 of 9 down short: VM 2026-10-29)
                        W.Stage(cat, spot, yaw, cfg.walkSpeed)
                        local far = math.sqrt((spot.X - l.X) ^ 2 + (spot.Y - l.Y) ^ 2)
                        walking[#walking + 1] = { cat = cat, spot = spot, yaw = yaw, named = W,
                                                  limit = far / math.max(cfg.walkSpeed, 1) + 4 }
                    elseif cfg.walkIn then
                        -- (they walk in: set down a few metres out from their seat, inside the game's range so their AI
                        -- runs - from afar the game freezes them and a move order did nothing: VM 2026-10-28)
                        -- (from the open ground round your cat - the meeting place - out to its seat: set down WalkFrom
                        -- past the seat, half of them landed against the camp's rocks and den walls and never started -
                        -- VM 2026-10-29. Spread round your cat so they don't start in a heap.)
                        local dx, dy = spot.X - place.X, spot.Y - place.Y
                        local len = math.max(1, math.sqrt(dx * dx + dy * dy))
                        local back = math.min(cfg.walkFrom, len - cfg.walkReach)
                        local side = ((n % 3) - 1) * 60
                        local from = { X = spot.X - dx / len * back - dy / len * side,
                                       Y = spot.Y - dy / len * back + dx / len * side, Z = spot.Z }
                        if back < cfg.walkReach then from = { X = spot.X, Y = spot.Y, Z = spot.Z } end
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
        end
        keepGathered(ctx.gathered)
        log("events: groups - %d clanmate(s) placed, %d round cats that stay put%s", n, #ctx.anchors,
            cfg.walkIn and (", " .. #walking .. " walking in") or "")
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
            if w.named then goto continue end
            pcall(function() w.cat.Controller.BrainComponent:StopLogic("WaCa gathering") end)
            pcall(function() w.cat.Controller:StopMovement() end)
            -- (the camp cats amble at 50 - a pace that took ~6 s for 3 m: they walk over at WalkSpeed, then back to
            -- their own - VM 2026-10-29)
            -- (they pass through each other - and your cat - on the way in: half of them stalled at 90-170 short of
            -- their seats, pushing against the circle's other cats: VM 2026-10-29; blocking again once seated)
            pcall(function() w.cat.CapsuleComponent:SetCollisionResponseToChannel(2, 0) end)   -- (Pawn: Ignore)
            pcall(function()
                local m = w.cat.CharacterMovement
                m:SetMovementMode(1, 0)            -- (walking: a cat left held by an interrupted scene couldn't move)
                w.speed = m.MaxWalkSpeed
                m.MaxWalkSpeed = math.max(w.speed, cfg.walkSpeed)
            end)
            ::continue::
        end
        -- (the game's own clock: it stops with the game and slows with it - at a low frame rate the cats walk in game
        -- seconds, and a wall-clock limit gave up on cats still on their way: VM 2026-10-29)
        local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        local function gameNow()
            local ok, t = pcall(function() return statics:GetTimeSeconds(pawn) end)
            return ok and t or os.time()
        end
        local started = gameNow()
        local longest = cfg.walkSeconds               -- (the scene waits for its farthest named cat's own limit)
        for _, w in ipairs(walking) do if w.limit and w.limit > longest then longest = w.limit end end
        local waited, lastReport = 0, 0
        local function seat(w, snapped)
            w.seated = true
            if w.named then
                if snapped then w.named.Seat(w.cat) end
                return
            end
            pcall(function() w.cat.CapsuleComponent:SetCollisionResponseToChannel(2, 2) end)   -- (Pawn: Block)
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
            waited = gameNow() - started
            local left, walked = 0, 0
            for _, w in ipairs(walking) do
                if not w.seated and w.named then
                    -- (a named cat: walkers.lua walks it; seated when it's there - or set down at the time limit)
                    if w.named.Staged(w.cat) then
                        w.seated = true
                        walked = walked + 1
                    elseif waited < (w.limit or cfg.walkSeconds) then
                        left = left + 1                     -- (still on its way; at its limit it is set down below)
                    end
                elseif not w.seated then
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
                        pcall(function()
                            local v = w.cat:GetVelocity()
                            log("events: groups - %s stopped %.0f short of its seat (%s order %s, move status %s, speed %.0f, best %.0f at %.1f s)",
                                w.cat:GetFName():ToString(), d, w.straight and "straight" or "path", tostring(w.result),
                                tostring(w.cat.Controller:GetMoveStatus()), math.sqrt(v.X ^ 2 + v.Y ^ 2), w.best, w.bestAt)
                        end)
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
                                -- (a path round the camp's dens and rocks - in a straight line they pushed against
                                -- them: VM 2026-10-29; the straight move only if no path is found)
                                w.result = ctl:MoveToLocation(w.spot, cfg.walkReach * 0.5, false, true, true, false, nil, true)
                                w.straight = false
                                if w.result == 0 then
                                    w.result = ctl:MoveToLocation(w.spot, cfg.walkReach * 0.5, false, false, false, false, nil, true)
                                    w.straight = true
                                end
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
                            local status = "?"
                            pcall(function() status = tostring(w.cat.Controller:GetMoveStatus()) end)
                            parts[#parts + 1] = string.format("%.0f (order %s%s, moving %s, speed %.0f)",
                                math.sqrt((q.X - w.spot.X) ^ 2 + (q.Y - w.spot.Y) ^ 2), tostring(w.result), w.straight and " straight" or " path", status,
                                math.sqrt(w.cat:GetVelocity().X ^ 2 + w.cat:GetVelocity().Y ^ 2))
                        end)
                    end
                end
                log("events: groups - walking in, %.0f s: still to go %s", waited, table.concat(parts, " "))
            end
            if left > 0 and waited < longest then
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
    if not ((g and #g > 0) or (ctx and ctx.anchors and #ctx.anchors > 0)) then
        staging = false
        if done then done() end
        return
    end
    fadeScreen(0, 1, FADE)
    ExecuteInGameThreadWithDelay(math.floor(FADE * 1000) + 100, function()
        putBack(g)
        for _, path in ipairs(ctx.anchors or {}) do
            local a = StaticFindObject(path)
            if a and a:IsValid() then stopMontage(a) end
        end
        ctx.anchors = nil
        pcall(function() stopMontage(pc().Pawn) end)
        ctx.gathered = nil
        staging = false
        clearGathered()
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

-- numbered lines of a config section: <Prefix>, <Prefix>1, <Prefix>2 ... -> steps, in number order. ALL of them - it
-- used to stop at 9, so a longer scene (or a section that two packs' steps grow past 9) lost its end silently (the
-- story check, 2026-11-01).
function Events.Lines(section, prefix)
    local out = {}
    if not section then return out end
    local keys = {}
    for k in pairs(section) do
        if type(k) == "string" then
            local n = k == prefix and 0 or tonumber(k:match("^" .. prefix .. "(%d+)$") or "")
            if n then keys[#keys + 1] = { k = k, n = n } end
        end
    end
    table.sort(keys, function(a, b) return a.n < b.n end)
    for _, e in ipairs(keys) do
        local v = section[e.k]
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
-- the story variables whose names start with a prefix ("Pair:" ...) -> { name = value }
function Events.VarsLike(prefix)
    local out = {}
    for k, v in pairs(vars) do if k:sub(1, #prefix) == prefix then out[k] = v end end
    return out
end

function Events.Var(name)
    if providers[name] then
        local ok, v = pcall(providers[name])
        return ok and v or 0
    end
    local v = vars[name]
    if v == nil then return 0 end
    return v
end

-- is there such a variable (a story variable set, or a provider)? (Events.Var answers 0 for any unknown name)
function Events.Has(name) return providers[name] ~= nil or vars[name] ~= nil end

-- A STORY'S PANEL ON THE HUD (library exercise 2026-11-02: a pack could tell its story only in cards - nothing lasting
-- like "Find the lost kit: searched 1/3"): events.ini [Panel.<Name>] - Title, Where, Activity, Goal, Count (a story
-- variable - or a number), Need, Show (conditions: while they hold the panel is up), Done (conditions: the check mark;
-- else Count >= Need), Order (default 50: under the clan's day). Drawn by WaCa Core (WaCa.HudPanel), kept up to date
-- whenever a story variable changes.
local storyPanels, panelUp = {}, {}
local function refreshPanels()
    if not WaCa.HudPanel then return end
    for name, p in pairs(storyPanels) do
        local show = p.show == "" or Events.Check(p.show)
        local id = "Story." .. name
        if show then
            local got = tonumber(p.count) or tonumber(Events.Var(p.count)) or 0
            local need = tonumber(p.need)
            local done = (p.done ~= "" and Events.Check(p.done)) or (need ~= nil and got >= need)
            WaCa.HudPanel(id, { title = p.title, where = p.where, activity = p.activity, goal = p.goal,
                                got = need and got or nil, need = need, done = done, order = p.order })
            if not panelUp[name] then log("events: the story's panel %s is up", name) end
            panelUp[name] = true
        elseif panelUp[name] then
            WaCa.HudPanel(id, nil)
            panelUp[name] = nil
            log("events: the story's panel %s is down", name)
        end
    end
end

function Events.SetVar(name, value)
    local n = tonumber(value)
    if n then value = n end
    if vars[name] == value then return end
    vars[name] = value
    log("events: %s = %s", name, tostring(value))
    WaCa.Emit("StoryVar", name, value)
    pcall(refreshPanels)
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
            -- (the other side may name a variable too - "Day <= LostKit.Until"; text that names none stays text)
            if type(want) == "string" and want:match("^[%a][%w%.%_]*$") and Events.Has(want) then
                want = tonumber(Events.Var(want)) or Events.Var(want)
            end
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

-- ANOTHER MOD'S HOOK (library exercise 2026-11-02: every UE4SS mod has its own Lua state - Events.Hook is reachable
-- only from inside Clan Life, so "Hook: <name> - a mod's own Lua code runs here" could never reach another mod's code).
-- A mod announces the hooks it handles - WaCa.Publish("hook.<Name>", true, true) - and listens for
-- WaCa.On("StoryHook", function(name) ... end); when its part is over it says so: WaCa.Emit("StoryHookDone", name).
-- The scene waits for that (at most [Events] HookWait s - 60), then goes on.
local pendingHooks = {}           -- name -> its continuation
local hookSaid = {}               -- hook names already logged as unhandled
local hookWait = 60
local function crossHook(name, ctx, continue)
    local announced = WaCa.Latest and WaCa.Latest("hook." .. name)
    if not announced then
        -- (once per hook: Clan Life's own hook points - ClanAssign ... - are usually unhandled, every duty would log it)
        if not hooks[name] and not hookSaid[name] then
            hookSaid[name] = true
            log("events: Hook: %s - no mod handles it (announce it: WaCa.Publish('hook.%s', true, true)); going on", name, name)
        end
        return continue()
    end
    local done = false
    pendingHooks[name] = function()
        if done then return end
        done = true
        log("events: Hook: %s - done", name)
        continue()
    end
    log("events: Hook: %s - another mod's part; waiting for its StoryHookDone (at most %d s)", name, hookWait)
    WaCa.Emit("StoryHook", name)
    ExecuteInGameThreadWithDelay(hookWait * 1000, function()
        if done then return end
        log("events: Hook: %s - no StoryHookDone in %d s; going on", name, hookWait)
        local k = pendingHooks[name]
        pendingHooks[name] = nil
        if k then k() end
    end)
end

-- A LINE'S NAMES (library pre-work 2026-11-04: a pack could cast S:storyteller, but no line of ours could NAME her -
-- "{S:storyteller}" went on screen as typed). {UPPERCASE} = the line's own values (PLAYER, NAME ...) as before; any other
-- {key} is a cat - S:<role>, E:<role>, a part (Leader, Deputy) or a name, by Events.Who - and becomes its name. A key
-- with no such cat about stays as typed and is logged once.
local fillMissed = {}
function Events.Fill(text, ctx)
    return (tostring(text or ""):gsub("{([%w:_ ]+)}", function(k)
        if k:match("^%u+$") then
            if ctx and ctx[k] ~= nil then return tostring(ctx[k]) end
            if k == "PLAYER" and WaCa.PlayerName then return WaCa.PlayerName() end
            return nil
        end
        local ok, a = pcall(Events.Who, k)
        local name = ok and WaCa.Live(a) and WaCa.CatName(a) or nil
        -- (a role played by a cat brought in for it - S:loner = Rogue:Quill - carries no name ids: its cast line's name)
        if ok and a and not name and type(castSpecs[k]) == "string" then name = castSpecs[k]:match(":%s*(.+)$") or castSpecs[k] end
        if name and name ~= "" then return name end
        if not fillMissed[k] then
            fillMissed[k] = true
            log("events: a line names {%s} - no such cat about; left as written", k)
        end
        return nil
    end))
end
local function fill(text, ctx) return Events.Fill(text, ctx) end

local function after(seconds, fn) ExecuteInGameThreadWithDelay(math.max(1, math.floor(seconds * 1000)), fn) end

-- where a Lead: step goes - Den:<the game's den name> (your clan's nearest: Den:Apprentice's den), Zone:<code>,
-- Pile, or a cat's name; nil when there's no such place
local function leadPlace(where)
    where = tostring(where or ""):match("^%s*(.-)%s*$")
    local pawn = pc() and pc().Pawn
    if not pawn then return nil end
    local at = pawn:K2_GetActorLocation()
    local function nearest(list)
        local best, bd
        for _, q in ipairs(list) do
            local d = (q.X - at.X) ^ 2 + (q.Y - at.Y) ^ 2
            if not bd or d < bd then best, bd = q, d end
        end
        return best
    end
    local den = where:match("^Den:%s*(.+)$")
    if den then
        local list = {}
        for _, door in ipairs(FindAllOf("WrcHousingDoorActor") or {}) do
            pcall(function()
                if not door:IsValid() or door.bIsExit then return end
                if door.ActorTitle:ToString():lower() == den:lower() then list[#list + 1] = door:K2_GetActorLocation() end
            end)
        end
        return nearest(list)
    end
    local zone = where:match("^Zone:%s*(.+)$")
    if zone then
        local ok, place = pcall(function() return require("duties").ZonePlace(zone) end)
        return ok and place or nil
    end
    if where == "Pile" then
        local q = placeOf("Pile")
        if q and (q.X ~= at.X or q.Y ~= at.Y) then return q end
        return nil
    end
    for _, c in ipairs(WaCa.Cats and WaCa.Cats() or {}) do
        if c.name:lower() == where:lower() then
            local q
            pcall(function() q = c.actor:K2_GetActorLocation() end)
            return q
        end
    end
    return nil
end

-- ONE PLACE RESOLVER for every step that names a place (library exercise 2026-11-04: Reach knew places.ini and "x y z",
-- Lead knew Den: / Zone:, Gather knew Pile - a writer couldn't tell which step took what): "x y z", Here (your cat),
-- a place of WaCa Cutscenes' places.ini ([Place.<Name>] At = x y z, a pack's own too; "Place.<Name>" as well),
-- Den:<den>, Zone:<code>, Pile, or a cat (a name, S:<role>, Leader, Deputy ...) - where it is now. { X, Y, Z } or nil.
local namedPlaces
function Events.Place(spec)
    spec = tostring(spec or ""):match("^%s*(.-)%s*$")
    if spec == "" then return nil end
    local x, y, z = spec:match("^(%-?[%d.]+)%s+(%-?[%d.]+)%s+(%-?[%d.]+)$")
    if x then return { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) } end
    if spec == "Here" then
        local p = pc() and pc().Pawn
        return p and p:IsValid() and p:K2_GetActorLocation() or nil
    end
    local named = Events.NamedPlace(spec)
    if named then return named end
    local ok, place = pcall(leadPlace, spec)
    if ok and place then return place end
    local okW, cat = pcall(Events.Who, spec)
    cat = okW and WaCa.Live(cat)
    return cat and cat:K2_GetActorLocation() or nil
end
-- a place of places.ini by its name ("ReedBank" or "Place.ReedBank"), { X, Y, Z } or nil - never a cat (a duty point
-- uses it to tell a place from a cat to follow; library exercise 2026-11-05)
function Events.NamedPlace(spec)
    spec = tostring(spec or ""):match("^%s*(.-)%s*$")
    if not namedPlaces then
        namedPlaces = {}
        pcall(function()
            local modsDir = modDir:match("^(.+)[/\\][^/\\]+$") or modDir
            local ini = WaCa.ReadContent(modsDir .. "/WaCaCutscenes/config/places.ini", "places") or {}
            for section, sec in pairs(ini) do
                local name = type(sec) == "table" and tostring(section):match("^Place%.(.+)$")
                local px, py, pz = tostring(sec.At or ""):match("^%s*(%-?[%d.]+)%s+(%-?[%d.]+)%s+(%-?[%d.]+)")
                if name and px then namedPlaces[name] = { X = tonumber(px), Y = tonumber(py), Z = tonumber(pz) } end
            end
        end)
    end
    return namedPlaces[(spec:gsub("^Place%.", ""))]
end

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

local function runStep(s, ctx, nextStep, stop, jump)
    local k = s.kind
    if k == "Set" then
        local name, value = tostring(s.value):match("^%s*([%w%.%_]+)%s*=%s*(.-)%s*$")
        -- (a value from another variable, + / - a number: "Set: LostKit.Until = Day + 2" - a side thread's deadline.
        -- Library exercise 2026-10-31: a value could only be a literal)
        local from, sign, n = tostring(value or ""):match("^([%a][%w%.%_]*)%s*([%+%-])%s*([%d%.]+)$")
        if not from then from = tostring(value or ""):match("^([%a][%w%.%_]*)$") end
        local base = from and Events.Has(from) and tonumber(Events.Var(from))
        if base then value = sign and (sign == "+" and base + tonumber(n) or base - tonumber(n)) or base end
        if name then Events.SetVar(name, value) end
        nextStep()
    elseif k == "Add" then
        local name, n = tostring(s.value):match("^%s*([%w%.%_]+)%s+([%-%+]?[%d%.]+)%s*$")
        if name then Events.SetVar(name, (tonumber(Events.Var(name)) or 0) + tonumber(n)) end
        nextStep()
    elseif k == "If" then
        -- (IF / ELSE / ENDIF - library exercise 2026-11-02, a Choice had two answers but a scene only one way on: a
        -- false If goes on after the next Else (or EndIf); with neither the scene ends, as it always did. Not nested.)
        if Events.Check(s.value) then nextStep() else jump({ Else = true, EndIf = true }) end
    elseif k == "Else" then
        jump({ EndIf = true })                        -- (the If's own branch is done: past its EndIf)
    elseif k == "EndIf" then
        nextStep()
    elseif k == "Card" then
        showCard(fill(s.value, ctx), cfg.cardSeconds, nextStep)
    elseif k == "Duty" then
        -- (Duty: <kind> - the scene gives your cat that duty now: one of the clan's or a pack's [Duty.<Name>])
        WaCa.Emit("GiveDuty", tostring(s.value):match("^%s*(.-)%s*$"))
        nextStep()
    elseif k == "Gather" then
        Events.Gather(tonumber(s.value) or 5, s.who, ctx, nextStep)
    elseif k == "Groups" then
        Events.Groups(s.value, s.who, ctx, nextStep)
    elseif k == "Pair" or k == "Part" then
        -- (Pair: A & B - they sit together from now on; Part: A & B - never together; kept with the save)
        local a, b = tostring(s.value):match("^%s*(.-)%s*&%s*(.-)%s*$")
        if a and b and a ~= "" and b ~= "" then
            Events.SetVar(k .. ":" .. pairKey({ name = a }, { name = b }), 1)
        else
            log("events: %s needs two cats - %s: <cat> & <cat>", k, k)
        end
        nextStep()
    elseif k == "Pose" then
        Events.Pose(s.value, s.who, ctx)
        nextStep()
    elseif k == "Skip" then
        -- (Skip: <days or a [Skip.<Name>] of timeskip.ini> - time passes on purpose: the card, the season / pile ...)
        WaCa.Emit("SkipDays", s.value)
        nextStep()
    elseif k == "Newcomer" then
        -- (Newcomer: <clanmate> [as S:<role>] - a new cat joins the clan, taking after that clanmate - kits.lua; "as
        -- S:<role>": it plays that story role from now on - later scenes / cutscenes cast it by the role)
        local like, castAs = tostring(s.value):match("^%s*(.-)%s+as%s+(S:[%w_]+)%s*$")
        if castAs then
            -- (the next step waits till the role is the NEWCOMER's - the full sweep 2026-11-04: NewApprenticeJoins'
            -- cutscene started with the role's previous cat, the binding came a moment later; 10 s at most)
            local w = { key = castAs, go = nextStep }
            newcomerWait = w
            ExecuteInGameThreadWithDelay(10000, function()
                if newcomerWait ~= w then return end
                newcomerWait = nil
                log("events: the newcomer for %s wasn't cast in 10 s - going on", castAs)
                w.go()
            end)
        end
        WaCa.Emit("Newcomer", like or s.value, castAs)
        if not castAs then nextStep() end
    elseif k == "Activity" then
        -- (Activity: <name> @ <who> - that cat does one of activities.ini's [Activity.*] now, joinable with the Join key;
        -- library exercise 2026-11-03)
        local cat = Events.Who(s.who or "Nearest")
        if cat then
            WaCa.Emit("StartActivity", s.value, (cat:GetFullName():gsub("^%S+ ", "")))
        else
            log("events: Activity %s - no cat '%s'", tostring(s.value), tostring(s.who or "Nearest"))
        end
        nextStep()
    elseif k == "Choice" then
        askChoice(s.value, nextStep)
    elseif k == "Freeze" then
        -- (a story point - tickets.md "Time freezes at story points": Freeze: On ... Freeze: Off - the clan's clock
        -- stands still and its next third waits; questing at a story point is never under time pressure)
        local v = tostring(s.value or ""):lower()
        local on = v == "on" or v == "1" or v == "yes"
        pcall(function() require("daynight").Freeze("story", on) end)
        log("events: time %s (a Freeze step)", on and "stands still" or "runs again")
        nextStep()
    elseif k == "Release" then
        Events.Release(ctx, nextStep)
    elseif k == "Say" then
        -- SAY: <line> @ <who> - the line over that cat's head (its nameplate - WaCa Core's Say), else on the screen's
        -- line; the scene goes on when it's been read (library exercise 2026-11-04: a scene's cats could only speak
        -- through the big card or the game's own dialogues)
        local cat = Events.Who(s.who or "Nearest")
        local name = cat and cat:IsValid() and WaCa.CatName and WaCa.CatName(cat) or nil
        local line = fill(tostring(s.value or ""), ctx)
        if not name then
            log("events: Say - no cat %s about; the line on the screen", tostring(s.who))
            WaCa.Emit("ShowLine", line)
        else
            local over = WaCa.SayOrShow and WaCa.SayOrShow(name, line)
            log("events: %s says%s: %s", name, over and "" or " (on the screen - no nameplate up)", line)
        end
        after(math.max(2, #line / 14), nextStep)
    elseif k == "Interact" then
        -- INTERACT: <place> [= <label>] - the game's Interact prompt at a place (Events.Place: a places.ini place,
        -- Den:, Zone:, Pile, x y z, a cat), marked on the map with the label; the scene waits until your cat uses it
        -- (show, not tell - operator 2026-11-04; library exercise: a pack had no way to say "do this there")
        local where, label = tostring(s.value or ""):match("^(.-)%s*=%s*(.+)$")
        where = where or tostring(s.value or "")
        local place = Events.Place(where)
        local spot = place and WaCa.InteractSpot and WaCa.InteractSpot(place, function(sp)
            sp:Remove()
            pcall(function() require("mapmarks").Clear("scene.interact") end)
            log("events: Interact at %s - done", where)
            nextStep()
        end, { reach = 300 })
        if not spot then
            log("events: Interact: %s - %s; going on", where, place and "no Interact prompt could be made" or "no such place")
            return nextStep()
        end
        pcall(function() require("mapmarks").Set("scene.interact", place, { R = 0.45, G = 0.9, B = 0.2, A = 1 }, label or where) end)
        log("events: Interact at %s (%.0f %.0f) - waiting for your cat%s", where, place.X, place.Y, label and (" (" .. label .. ")") or "")
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
        -- a mod's own role (S:<role>) has no bond in the game: it is ours - the story variable Bond.<role>, saved with
        -- the save and good for If: / Require: (Bond.herbalist >= 4) - library exercise 2026-10-30
        local own = not now and tostring(s.who or ""):match("^S:(.+)$")
        if own then
            local var = "Bond." .. own
            Events.SetVar(var, (tonumber(Events.Var(var)) or 0) + (tonumber(s.value) or 1))
            log("events: bond +%s with %s (%s = %s)", s.value, s.who, var, tostring(Events.Var(var)))
        else
            log("events: bond +%s with %s%s", s.value, s.who or "Nearest", now and "" or " (not a story cat - no bond)")
        end
        nextStep()
    elseif k == "Party" then
        -- who fights beside your cat from now on (tickets.md "The party = who you're out with"): Party: Toadfrost,
        -- E:RiverClanDeputy - story cats (by name, E:<role>, Leader ...); Party: none = the game's own. Kept as the
        -- story variable Party (saved with the cat, set again each session - Events.Init)
        local roles = {}
        if tostring(s.value):lower() ~= "none" then
            for raw in tostring(s.value or ""):gmatch("[^,]+") do
                local who = raw:match("^%s*(.-)%s*$")
                -- (a pack's own role: the cat its [Cast] gives it - a name or E:<role>; a brought-in cat (Rogue: / Clan:)
                -- has no story role. Library exercise 2026-11-01: S:herbalist = Mossfeather wasn't found)
                if who:match("^S:") then
                    local spec = (Events.CastSpecs and Events.CastSpecs() or {})[who]
                    if type(spec) == "string" and not spec:match("^Rogue") and not spec:match("^Clan:") then who = spec end
                end
                local role = who:match("^E:(.+)$")
                if not role then
                    pcall(function()
                        local cat = Events.Who(who)
                        local v = cat and cat.narrativeRole
                        if type(v) == "number" and v > 0 then role = v end
                    end)
                end
                -- (a story cat anywhere in the world by its name - Who finds the ones near you: VM 2026-11-01)
                if not role then
                    for _, a in ipairs(FindAllOf("SwtAdventureQuestActor") or {}) do
                        local ok, v = pcall(function() return WaCa.CatName(a) == who and a.narrativeRole end)
                        if ok and type(v) == "number" and v > 0 then role = v break end
                    end
                end
                if role then roles[#roles + 1] = role
                else log("events: Party - %s is no story cat (only story cats can fight beside you)", who) end
            end
        end
        local names = {}
        for _, r in ipairs(roles) do names[#names + 1] = tostring(r) end
        Events.SetVar("Party", #names > 0 and table.concat(names, ",") or 0)
        local took = WaCa.SetCombatParty and WaCa.SetCombatParty(roles, true)
        log("events: the party - %s%s", #roles > 0 and table.concat(names, ", ") or "the game's own",
            took == false and " (not taken - WaCa Core too old?)" or "")
        nextStep()
    elseif k == "Emit" then
        -- (Emit: <event> = <value> hands the value over first - Emit: SetSpecialisation = Herbalist (WaCa Hunting);
        -- library exercise 2026-11-02: a story had no way to tell another mod anything but a name)
        local name, value = tostring(s.value):match("^%s*(.-)%s*=%s*(.-)%s*$")
        if name and name ~= "" then WaCa.Emit(name, value, ctx) else WaCa.Emit(s.value, ctx) end
        nextStep()
    elseif k == "Hook" then
        local fns, i = hooks[s.value] or {}, 0
        local function nextHook()
            i = i + 1
            if i > #fns then return crossHook(s.value, ctx, nextStep) end
            local ok, err = pcall(fns[i], ctx, nextHook)
            if not ok then
                log("events: hook %s failed (%s)", s.value, tostring(err))
                nextHook()
            end
        end
        nextHook()
    elseif k == "Lead" then
        -- (a cat leads your cat there - waits when you fall behind; the scene goes on when it's there: tickets.md P1
        -- "walk quests". Lead: Den:Apprentice's den @ S:mentor)
        local okW, Walkers = pcall(require, "walkers")
        local cat = Events.Who(s.who or "Nearest")
        -- (the one place resolver - library exercise 2026-11-05: ScentLesson's 'Lead: ReedBank' said "no such place"
        -- while the very next 'Interact: ReedBank' found it; Lead still called the older den / zone / pile / cat one)
        local spot = Events.Place(s.value)
        if not (okW and Walkers.Lead and cat and cat:IsValid() and spot) then
            log("events: Lead: %s - %s; going on", tostring(s.value),
                not spot and "no such place" or "no cat to lead (" .. tostring(s.who or "Nearest") .. ")")
            return nextStep()
        end
        local name = (WaCa.CatName and WaCa.CatName(cat)) or "a clanmate"
        local path = (cat:GetFullName():gsub("^%S+ ", ""))
        -- (the spot a little short of the place - in front of a den's door, not inside it)
        pcall(function()
            local q = cat:K2_GetActorLocation()
            local dx, dy = q.X - spot.X, q.Y - spot.Y
            local len = math.max(1, math.sqrt(dx * dx + dy * dy))
            spot = { X = spot.X + dx / len * 150, Y = spot.Y + dy / len * 150, Z = spot.Z }
        end)
        local arrived = false
        local function arrive(why)
            if arrived then return end
            arrived = true
            log("events: %s led your cat to %s%s", name, tostring(s.value), why or "")
            after(cfg.leadStay or 30, function()
                local c = StaticFindObject(path)
                if c and c:IsValid() then Walkers.Unstage(c) end
            end)
            nextStep()
        end
        -- (your cat far off when it begins: the cat comes to you first - without waiting - then leads; VM 2026-11-01: it
        -- started by waiting where it stood)
        local function lead() Walkers.Lead(cat, spot, function() arrive() end, "Lead: " .. tostring(s.value)) end
        -- (a cat too far to walk in, and out of sight - not drawn, or past LeadFar and behind your camera: set down
        -- LeadNear behind your cat first, its own spot kept as home. Library exercise 2026-11-05: ScentLesson's mentor
        -- started 139 m off, undrawn - your cat waited ~2 min of play for it to walk over)
        pcall(function()
            if not (Walkers.BringNear and WaCa.OnGround) then return end
            local p, q = pc().Pawn:K2_GetActorLocation(), cat:K2_GetActorLocation()
            local d = math.sqrt((p.X - q.X) ^ 2 + (p.Y - q.Y) ^ 2)
            if d <= (cfg.leadFar or 4000) then return end
            local drawn = true
            pcall(function() drawn = cat.SkeletalMeshComponent:IsVisible() end)
            local yaw = math.rad(pc().PlayerCameraManager:GetCameraRotation().Yaw)
            local fx, fy = math.cos(yaw), math.sin(yaw)
            local inFront = (q.X - p.X) * fx + (q.Y - p.Y) * fy > 0
            if drawn and inFront then return end
            local back = cfg.leadNear or 1200
            local at = WaCa.OnGround({ X = p.X - fx * back, Y = p.Y - fy * back, Z = p.Z + 100 })
            Walkers.BringNear(cat, at)
        end)
        local near = true
        local meet
        pcall(function()
            local p, q = pc().Pawn:K2_GetActorLocation(), cat:K2_GetActorLocation()
            local dx, dy = p.X - q.X, p.Y - q.Y
            local d = math.sqrt(dx * dx + dy * dy)
            if d > 500 then
                near = false
                meet = { X = p.X - dx / d * 200, Y = p.Y - dy / d * 200, Z = p.Z }
            end
        end)
        if near then lead()
        else
            log("events: %s comes to your cat first", name)
            Walkers.Lead(cat, meet, function() if not arrived then lead() end end, "to your cat", true)
        end
        -- (never a scene stuck on a walk: a cat that makes no headway for 3 checks in a row (30 s each) - and isn't
        -- waiting for you - is set down there. Progress, not a time limit: on the VM a 40 m lead outlasted a 300 s
        -- limit while walking fine, 2026-11-01)
        local last, stuck = nil, 0
        local function watch()
            if arrived then return end
            local c = StaticFindObject(path)
            if not (c and c:IsValid()) then return arrive(" (the cat is gone)") end
            local q = c:K2_GetActorLocation()
            local waiting = false
            pcall(function() waiting = Walkers.Waiting and Walkers.Waiting(c) end)
            if last and not waiting and (q.X - last.X) ^ 2 + (q.Y - last.Y) ^ 2 < 50 * 50 then stuck = stuck + 1 else stuck = 0 end
            last = { X = q.X, Y = q.Y }
            if stuck >= 3 then
                Walkers.Seat(c)
                return arrive(" (set down - it made no headway)")
            end
            after(30, watch)
        end
        after(30, watch)
    elseif k == "Cutscene" then
        -- (WaCa Cutscenes plays it; the scene goes on when it's over - or at once when that mod isn't there to start it)
        local name = tostring(s.value)
        local state = { started = false, over = false }
        local function over()
            if state.over then return end
            state.over = true
            if cutsceneWait and cutsceneWait.state == state then cutsceneWait = nil end
            nextStep()
        end
        cutsceneWait = { name = name, state = state, done = over }
        WaCa.Emit("PlayCutscene", name)
        log("events: cutscene %s", name)
        after(cfg.startWait, function()
            if not state.started and not state.over then
                log("events: cutscene %s never started (WaCa Cutscenes not installed?) - going on", name)
                over()
            end
        end)
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
-- (scenes running now - Events.Busy(): a Reach event waits while another scene runs. Library exercise 2026-11-05: the
-- mentor's ScentLesson led your cat to the reeds and the pack's FrostAtTheReeds (When = Reach: ReedBank) fired in the
-- middle of it. A run older than 10 min doesn't count - a scene stuck on a step must not silence the places for good)
local running = {}
function Events.Busy()
    local now, n = os.time(), 0
    for token, since in pairs(running) do
        if now - since < 600 then n = n + 1 else running[token] = nil end
    end
    return n > 0
end

function Events.Run(steps, onDone, ctx)
    local i = 0
    local finished = false
    local token = {}
    running[token] = os.time()
    local function stop()
        if finished then return end
        finished = true
        running[token] = nil
        if onDone then onDone() end
    end
    local nextStep
    -- (on after the next step of one of these kinds - none: the scene ends)
    local function jump(kinds)
        for j = i + 1, #(steps or {}) do
            local st = steps[j]
            if type(st) == "string" then st = Events.Parse(st) end
            if st and kinds[st.kind] then
                i = j
                return nextStep()
            end
        end
        stop()
    end
    nextStep = function()
        if finished then return end
        i = i + 1
        local s = steps and steps[i]
        if not s then return stop() end
        if type(s) == "string" then s = Events.Parse(s) end
        if not s then return nextStep() end
        local ok, err = pcall(runStep, s, ctx, nextStep, stop, jump)
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

-- YOUR CAT'S MENTOR, FROM THE GAME'S OWN LINES (operator 2026-11-04: an apprentice reports to its mentor; the game has
-- no mentor field - its story names one only in dialogue): every line of the game's text naming a story role as "your
-- mentor" ("{THE REGRETFUL WARRIOR} as your mentor", "was your mentor" ...) counts for that role; the most named one
-- whose cat is in this world (of your clan) plays S:mentor, unless a pack casts it. English lines
-- only (the phrase is looked for): another language = no mentor found = the deputy, as before. Logged with its count.
local function storyMentor()
    if castSpecs["S:mentor"] then return end
    local ok, keys = pcall(function()
        return StaticFindObject("/Script/Engine.Default__KismetStringTableLibrary"):GetKeysFromStringTable(FName("SwtStrings"))
    end)
    if not (ok and keys) then return end
    local roles = {}
    pcall(function()
        StaticFindObject("/Script/SwtQuest.ENarrativeRole"):ForEachName(function(n) roles[(n:ToString():gsub("^.*::", ""))] = true end)
    end)
    local count = {}
    for i = 1, #keys do
        local k = keys[i]
        -- (each key an FString in the array's element: :get() first - VM 2026-11-04, a tostring of it read nothing)
        local key = type(k) == "string" and k or nil
        if not key then pcall(function() key = k:get():ToString() end) end
        local text = key and WaCa.GetText(key) or ""
        for ph in text:gmatch("{([%u ]+)}[^{}]-your mentor") do
            local name = ph:lower():gsub("(%a)(%a*)", function(a, b) return a:upper() .. b end):gsub(" ", "")
            if roles[name] then count[name] = (count[name] or 0) + 1 end
        end
    end
    local list = {}
    for name, n in pairs(count) do list[#list + 1] = { name = name, n = n } end
    table.sort(list, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.name < b.name end)
    -- (YOUR clan's only: the story's mentors of the other Clans' tales stand in the world too - the most named, The
    -- Self Doubting Warrior, isn't RiverClan's)
    local mine = clan()
    local wanted = {}
    pcall(function()
        StaticFindObject("/Script/SwtQuest.ENarrativeRole"):ForEachName(function(n, x) wanted[(n:ToString():gsub("^.*::", ""))] = x end)
    end)
    for _, e in ipairs(list) do
        local cat
        for _, a in ipairs(FindAllOf("QuestBaseActor") or {}) do
            pcall(function()
                if not cat and a:IsValid() and a.narrativeRole == wanted[e.name] and clanName(a.ClanType) == mine
                    and not a:GetClass():GetFName():ToString():find("Filler") then
                    cat = a
                end
            end)
        end
        if cat and cat:IsValid() then
            castSpecs["S:mentor"] = "E:" .. e.name
            Events.BindRole("S:mentor", cat)
            log("events: your cat's mentor (S:mentor) = %s - the game's lines call %s 'your mentor' %d time(s)",
                WaCa.CatName(cat) or e.name, e.name, e.n)
            return
        end
    end
    log("events: no mentor in the game's lines with a cat in this world (%d role(s) named) - an apprentice reports to the deputy", #list)
end

function Events.Init(c)
    WaCa, log, modDir, DayNight = c.WaCa, c.log, c.modDir, c.DayNight
    -- (the mentor once the world and the cast are up)
    local mentorFor
    WaCa.On("ScreenShown", function(screen)
        if not screen:GetClass():GetFName():ToString():find("^WBP_GuiHudGame") then return end
        if mentorFor == WaCa.CurrentSlot() then return end
        mentorFor = WaCa.CurrentSlot()
        ExecuteInGameThreadWithDelay(25000, function() local okM, err = pcall(storyMentor) if not okM then log("events: mentor - %s", tostring(err)) end end)
    end)
    local ini = WaCa.ReadContent(modDir .. "/config/events.ini", "events") or {}
    local e = ini["Events"] or {}
    cfg.cardSeconds = tonumber(e.CardSeconds or "") or cfg.cardSeconds
    cfg.choiceRoom = tonumber(e.ChoiceRoom or "") or cfg.choiceRoom
    cfg.walkIn = (e.WalkIn or "1") ~= "0"
    cfg.walkFrom = tonumber(e.WalkFrom or "") or cfg.walkFrom
    cfg.walkSeconds = tonumber(e.WalkSeconds or "") or cfg.walkSeconds
    cfg.walkSpeed = tonumber(e.WalkSpeed or "") or cfg.walkSpeed
    cfg.bigPreyChance = tonumber(e.BigPreyChance or "") or cfg.bigPreyChance
    log("events: %d tie(s) between clan cats (config/relations.ini)", readRelations(modDir))
    for _, key in ipairs((ini["Cast"] or {}).__order or {}) do
        local spec = ini["Cast"][key]
        if key:match("^S:.+$") and spec and spec ~= "" then castSpecs[key] = spec
        else log("events: [Cast] %s - only S:<role> = <who> (a mod's own roles)", key) end
    end
    -- (who plays each role, as written - WaCa Cutscenes brings in a Rogue / Clan: one per scene)
    WaCa.Publish("roles.specs", castSpecs, true)
    for key, spec in pairs(castSpecs) do
        if spec:match("^Rogue") or spec:match("^Clan:") then
            log("events: [Cast] %s = %s - brought in by the scenes that ask for it", key, spec)
        end
    end
    if next(castSpecs) then
        WaCa.On("ScreenShown", function(screen)
            if screen:GetClass():GetFName():ToString():find("^WBP_GuiHudGame") then
                ExecuteInGameThreadWithDelay(5000, function() pcall(Events.Cast) end)
            end
        end)
        WaCa.On("ClanThird", function() pcall(Events.Cast) end)
    end
    -- (the camp cats' names: once the world is up - its walking cats spawned - and before any grouping)
    WaCa.On("ScreenShown", function(screen)
        if not screen:GetClass():GetFName():ToString():find("^WBP_GuiHudGame") then return end
        if namesFor == WaCa.CurrentSlot() then return end
        ExecuteInGameThreadWithDelay(20000, function() pcall(keepCampNames) end)
    end)
    -- (other mods - a story mod - set the clan's story variables: WaCa.Emit("SetStoryVar", name, value))
    WaCa.On("SetStoryVar", function(name, value)
        if name then Events.SetVar(tostring(name), value) end
    end)
    -- (other mods: play steps now - step lines as in clanevents.ini, joined by "|": "Groups: Prey|Wait: 3|Release")
    -- (a reload with the world up: cats a scene before had gathered go back)
    ExecuteInGameThreadWithDelay(2500, function()
        if WaCa.CurrentSlot() then Events.RecoverGathered() else Events.ForgetRecords() end
    end)
    WaCa.On("KeyDown", function(_, key) if pendingChoice then pcall(answerChoice, key) end end)
    -- (the game's screen commands for the answer menu - pressed (0), held (2), released (1). One press can reach several
    -- screens: a press counts only while its command isn't down already, its release lets the next one count - by time
    -- it went wrong: the VM handled two presses 3 ms apart in game time and the second was dropped)
    WaCa.Watch("OnListenCommand", "/Script/SwtEngine.SwtScreen", "WaCaChoiceCommand", "pre", "Command,InputEvent")
    WaCa.On("WaCaChoiceCommand", function(_, command, inputEvent)
        local c = pendingChoice
        if inputEvent == "1" then commandDown[command] = nil return end
        if not (c and c.menu) or (inputEvent ~= "0" and inputEvent ~= "2") then return end
        if inputEvent == "0" then
            if commandDown[command] then return end
            commandDown[command] = true
        end
        if CMD_MOVE[command] then
            Events.ChoiceSelect((c.pick - 1 + CMD_MOVE[command]) % c.n + 1)
        elseif CMD_PICK[command] then
            pcall(answerChoice, ({ "One", "Two", "Three", "Four" })[c.pick])
        end
    end)
    WaCa.On("StoryHookDone", function(name)
        local k = pendingHooks[tostring(name)]
        pendingHooks[tostring(name)] = nil
        if k then k() end
    end)
    hookWait = tonumber((ini["Events"] or {}).HookWait or "") or hookWait
    for section, sec in pairs(ini) do
        local name = type(sec) == "table" and section:match("^Panel%.([%w_]+)$")
        if name and sec.Off ~= "1" then
            local function v(k) return (sec[k] or "") ~= "" and sec[k] or nil end
            storyPanels[name] = { title = v("Title") or name, where = v("Where"), activity = v("Activity"), goal = v("Goal"),
                                  count = sec.Count or "", need = v("Need"), show = sec.Show or "", done = sec.Done or "",
                                  order = tonumber(sec.Order or "") or 50 }
        end
    end
    -- (a reload with the world up: the panels for this save's story as it stands)
    ExecuteInGameThreadWithDelay(3000, function() if WaCa.CurrentSlot() then pcall(refreshPanels) end end)
    WaCa.On("NewcomerCast", function(key, name)
        if tostring(key or ""):match("^S:") and (name or "") ~= "" then
            ExecuteInGameThread(function() newcomerCast(tostring(key), tostring(name)) end)
        end
    end)
    -- (IN THE WORLD ONLY - operator 2026-11-04: Hunting's role question popped up on the Select Your Cat screen. A scene
    -- asked for while the game's HUD isn't up - the menus, a level loading - waits, and plays once the HUD is back)
    local hudUp, waiting = false, {}
    WaCa.On("ScreenShown", function(screen)
        if not screen:GetClass():GetFName():ToString():find("^WBP_GuiHudGame") then return end
        hudUp = true
        if #waiting == 0 then return end
        ExecuteInGameThreadWithDelay(3000, function()
            if not hudUp then return end
            local list = waiting
            waiting = {}
            log("events: %d scene(s) asked for in the menus - playing now, in the world", #list)
            for _, steps in ipairs(list) do Events.Play(steps) end
        end)
    end)
    WaCa.On("ScreenHidden", function(screen)
        if screen:GetClass():GetFName():ToString():find("^WBP_GuiHudGame") then hudUp = false end
    end)
    WaCa.On("PlayScene", function(text)
        local steps = { context = {} }                  -- (a scene's own context: its gathered cats, its place)
        for line in tostring(text or ""):gmatch("[^|]+") do
            local st = Events.Parse(line)
            if st then steps[#steps + 1] = st end
        end
        log("events: a scene asked for - %d step(s): %s", #steps, tostring(text))
        if #steps == 0 then return end
        if not hudUp then
            waiting[#waiting + 1] = steps
            log("events: ... not in the world (no HUD) - it plays once you are")
            return
        end
        ExecuteInGameThread(function() Events.Play(steps) end)
    end)
    -- (WaCa Cutscenes: one playing holds the cards; the Cutscene step goes on when its own is over)
    WaCa.On("CutsceneStarted", function(name)
        cutsceneOn = true
        if cutsceneWait and cutsceneWait.name == tostring(name) then cutsceneWait.state.started = true end
    end)
    -- (queued behind another one: it will play - not "never started")
    WaCa.On("CutsceneQueued", function(name)
        if cutsceneWait and cutsceneWait.name == tostring(name) then cutsceneWait.state.started = true end
    end)
    WaCa.On("CutsceneEnded", function(name, why)
        cutsceneOn = false
        if cutsceneWait and cutsceneWait.name == tostring(name) then
            log("events: cutscene %s is over (%s)", tostring(name), tostring(why))
            ExecuteInGameThread(function() if cutsceneWait then cutsceneWait.done() end end)
        end
    end)
    WaCa.On("WaCaGroupsSelfTest", function()
        local ok, err = pcall(groupsSelfTest)
        if not ok then log("events: groups self-test failed to run: %s", tostring(err)) end
    end)
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
            pcall(refreshPanels)
            -- (a Party step's party is this cat's: set again for the session)
            if vars.Party and vars.Party ~= 0 and WaCa.SetCombatParty then
                local roles = {}
                for r in tostring(vars.Party):gmatch("[^,%s]+") do roles[#roles + 1] = tonumber(r) or r end
                WaCa.SetCombatParty(roles, true)
                log("events: the party - %s (this save's Party)", tostring(vars.Party))
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
