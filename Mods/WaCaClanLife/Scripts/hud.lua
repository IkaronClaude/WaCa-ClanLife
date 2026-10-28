-- The day at a glance on the HUD: the clan loop's status (the WaCa topic "clan.status", duties.lua) in a second copy of
-- the game's own current-objective panel (WBP_GuiHudCurrentObjective_C - the same look as the game's quests: title,
-- location, activity, a goal with its count and check mark), on the gameplay HUD's left column under the game's own
-- objective. Shown while the clan loop runs; clanlife.ini [Hud] On / Below / Right.
-- The copy gets the game panel's own slot (size, anchors, alignment - its content sits well above the slot's top, VM
-- 2026-10-28: an auto-sized copy at a plain position overlapped the game's), moved Below (design units) further down,
-- so the two stack: the game's quest above, the clan's day under it.
local Hud = {}

local WaCa, log
-- (the HUD is laid out in 3840 x 2160 units - VM 2026-10-28: viewport scale 0.125 at 270 pixels high. The game's quest
-- panel at its slot's 450 spans about 620 - 1260 with three goals; ours goes under it)
local cfg = { on = true, below = 760, right = 0 }
local status                      -- the latest clan.status
local panel, panelHud             -- our panel and the HUD (its full name) it was made in

local VISIBLE, COLLAPSED, HIDDEN, HIT_TEST_INVISIBLE = 0, 1, 2, 4

local function setText(widget, text)
    if widget and widget:IsValid() then widget:SetText(FText(text or "")) end
end

local function show(widget, on)
    if widget and widget:IsValid() then widget:SetVisibility(on and HIT_TEST_INVISIBLE or COLLAPSED) end
end

local function fill()
    if not (panel and panel:IsValid()) then return end
    if not status then
        panel:SetVisibility(COLLAPSED)
        return
    end
    local s = status
    setText(panel.mcGuiTitle, s.title)
    show(panel.CanvasLocation, s.where ~= nil)
    setText(panel.mcGuiLocation, s.where)
    setText(panel.mcGuiActivity, s.activity)
    local g = panel.mcGuiGoal1
    show(g, s.goal ~= nil)
    if s.goal then
        setText(g.mcGuiGoalName, s.goal)
        setText(g.mcGuiGoalValues, s.need and string.format("%d/%d", s.got or 0, s.need) or "")
        pcall(function() g.CanvasCheck:SetVisibility(s.done and HIT_TEST_INVISIBLE or HIDDEN) end)
    end
    show(panel.mcGuiGoal2, false)
    show(panel.mcGuiGoal3, false)
    panel:SetVisibility(HIT_TEST_INVISIBLE)
end

-- our panel in this HUD (a level load builds a new HUD: a new panel goes into it)
local function attach(hud)
    if not (hud and hud:IsValid()) then return end
    local name = hud:GetFullName()
    if panel and panel:IsValid() and panelHud == name then return end
    local game = hud.mcGuiQuestObjective
    if not (game and game:IsValid()) then
        log("hud: the gameplay HUD has no objective panel to copy - no day status on screen")
        return
    end
    local pc
    for _, c in ipairs(FindAllOf("SwtPlayerController") or {}) do
        if c:IsValid() and c.Player then pc = c end
    end
    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local w = lib:Create(hud, game:GetClass(), pc)
    if not (w and w:IsValid()) then
        log("hud: the objective panel couldn't be made")
        return
    end
    -- (copies of the panel this HUD already has besides the game's own: ours from before a reload of the mod)
    local canvas = game:GetParent()
    for i = canvas:GetChildrenCount() - 1, 0, -1 do
        local other = canvas:GetChildAt(i)
        if other:IsValid() and other:GetClass() == game:GetClass() and other ~= game
            and other:GetFName():ToString() ~= game:GetFName():ToString() then
            other:RemoveFromParent()
        end
    end
    local slot = canvas:AddChildToCanvas(w)
    local layout = game.Slot:GetLayout()
    layout.Offsets.Left = layout.Offsets.Left + cfg.right
    layout.Offsets.Top = layout.Offsets.Top + cfg.below
    slot:SetLayout(layout)
    slot:SetAutoSize(false)
    panel, panelHud = w, name
    log("hud: the day status panel is on the HUD (%.0f, %.0f - the game's quest panel + %.0f, %.0f)", layout.Offsets.Left,
        layout.Offsets.Top, cfg.right, cfg.below)
    fill()
end

function Hud.Init(c)
    WaCa, log = c.WaCa, c.log
    local h = (WaCa.ReadIni(c.modDir .. "/config/clanlife.ini") or {})["Hud"] or {}
    cfg.on = (h.On or "1") ~= "0"
    cfg.below = tonumber(h.Below or "") or cfg.below
    cfg.right = tonumber(h.Right or "") or cfg.right
    if not cfg.on then
        log("hud: off (clanlife.ini [Hud] On = 0)")
        return
    end
    WaCa.Subscribe("clan.status", function(s)
        status = s
        if not (panel and panel:IsValid()) then Hud.Attach() end
        local ok, err = pcall(fill)
        if not ok then log("hud: %s", tostring(err)) end
    end)
    WaCa.On("ScreenShown", function(screen)
        local ok, name = pcall(function() return screen:GetClass():GetFName():ToString() end)
        if not (ok and name:find("^WBP_GuiHudGame")) then return end
        -- (only once there is a status: without the clan loop no panel is made at all)
        if not status then return end
        local ok2, err = pcall(attach, screen)
        if not ok2 then log("hud: %s", tostring(err)) end
    end)
end

-- the first status after the HUD is already up
function Hud.Attach()
    for _, s in ipairs(FindAllOf("SwtScreen") or {}) do
        if s:IsValid() and s:IsInViewport() and s:GetClass():GetFName():ToString():find("^WBP_GuiHudGame") then
            pcall(attach, s)
        end
    end
end

return Hud
