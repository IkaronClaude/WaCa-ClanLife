-- Marks on the game's world map (operator 2026-10-30: "a cyan map marker for it"): Clan Life's places - the meeting
-- place you give out the clan's tasks at - drawn among the map's own icons when the map opens.
-- MapMarks.Set(id, { X, Y }, color, label) / MapMarks.Clear(id). A mark is an image in the map's icon layer
-- (GuiPopupWorldMap.CanvasGenericIcons): the game's white UI circle, tinted (the legend's icons are yellow - a tint
-- made them green, VM 2026-10-30). The labels go out as the sticky topic "map.marks" ({ id = label }): WaCa Keybinds
-- & Mouse names a mark with it when the mouse points at it.
-- WHERE on the map: the map's own MapCoordinates (world box -> map box). Which way its axes run isn't in the data, so
-- it is read off the map itself: the game's checkpoint icons (GuiItemCheckPointMap, placed by their render translation)
-- sit where its checkpoints are - of the eight ways a world box can map onto the map box, the one that puts every
-- checkpoint on its icon is the map's (VM 2026-10-30: map u = world Y, v = 1 - world X, exact).
local MapMarks = {}
local WaCa, log
local marks = {}                    -- id -> { at = {X, Y}, color }
local shown = {}                    -- id -> image path (on the open map)
local orient                        -- { swap, flipU, flipV } once read off the map
local CIRCLE = "/Game/Art/UXD/Textures/TEMP/T_UI_Circle_512x512.T_UI_Circle_512x512"
local SIZE = 44

local function mapUp()
    for _, m in ipairs(FindAllOf("GuiPopupWorldMap") or {}) do
        local ok, up = pcall(function() return m:IsValid() and m:IsInViewport() end)
        if ok and up then return m end
    end
end

-- world -> map for one orientation
local function project(c, o, x, y)
    local u = (x - c.WorldMinX) / (c.WorldMaxX - c.WorldMinX)
    local v = (y - c.WorldMinY) / (c.WorldMaxY - c.WorldMinY)
    if o.swap then u, v = v, u end
    if o.flipU then u = 1 - u end
    if o.flipV then v = 1 - v end
    return c.MapOffsetX + u * c.MapWidth, c.MapOffsetY + v * c.MapHeight
end

local function readOrientation(m, c)
    local icons, cps = {}, {}
    local canvas = m.CanvasGenericIcons
    for i = 0, canvas:GetChildrenCount() - 1 do
        pcall(function()
            local w = canvas:GetChildAt(i)
            if w:GetClass():GetFName():ToString():find("CheckPoint") then
                local t = w.RenderTransform.Translation
                icons[#icons + 1] = { X = t.X, Y = t.Y }
            end
        end)
    end
    for _, a in ipairs(FindAllOf("SwtAdventureCheckpoint") or {}) do
        pcall(function() local q = a:K2_GetActorLocation() cps[#cps + 1] = { X = q.X, Y = q.Y } end)
    end
    if #icons == 0 or #cps == 0 then
        log("map marks: no checkpoints to read the map's axes off (%d icons, %d checkpoints)", #icons, #cps)
        return nil
    end
    local best, bestD
    for _, swap in ipairs({ false, true }) do
        for _, fu in ipairs({ false, true }) do
            for _, fv in ipairs({ false, true }) do
                local o = { swap = swap, flipU = fu, flipV = fv }
                local total = 0
                for _, cp in ipairs(cps) do
                    local x, y = project(c, o, cp.X, cp.Y)
                    local near
                    for _, ic in ipairs(icons) do
                        local d = math.abs(ic.X - x) + math.abs(ic.Y - y)
                        if not near or d < near then near = d end
                    end
                    total = total + near
                end
                if not bestD or total < bestD then best, bestD = o, total end
            end
        end
    end
    bestD = bestD / #cps
    log("map marks: the map's axes read off its %d checkpoints (%s%s%s, %.1f off)", #cps, best.swap and "swapped " or "",
        best.flipU and "flip-u " or "", best.flipV and "flip-v" or "", bestD)
    if bestD > 20 then return nil end
    return best
end

local function draw(m)
    local c = m.MapCoordinates
    orient = orient or readOrientation(m, c)
    if not orient then return end
    local canvas = m.CanvasGenericIcons
    local tex = WaCa.LoadAsset(CIRCLE)
    for id, mark in pairs(marks) do
        local ok, err = pcall(function()
            local path = shown[id]
            local img = path and StaticFindObject(path)
            -- (the map is the same widget each time it opens: a mark made before - or by the mod before a reload - is
            -- still in its icon layer; a second one under the same name collided)
            if not (img and img:IsValid()) then
                for i = 0, canvas:GetChildrenCount() - 1 do
                    local w = canvas:GetChildAt(i)
                    if w and w:IsValid() and w:GetFName():ToString() == "WaCaMapMark_" .. id then img = w end
                end
                if img then shown[id] = (img:GetFullName():gsub("^%S+ ", "")) end
            end
            if not (img and img:IsValid()) then
                img = StaticConstructObject(StaticFindObject("/Script/UMG.Image"), m.WidgetTree, FName("WaCaMapMark_" .. id))
                local slot = canvas:AddChildToCanvas(img)
                slot:SetAutoSize(false)
                slot:SetSize({ X = SIZE, Y = SIZE })
                slot:SetPosition({ X = -SIZE / 2, Y = -SIZE / 2 })
                -- (UNDER the game's own icons: a duty point's in-world marker draws the game's quest-hint leaf on the map,
                -- and this circle covered it completely - operator 2026-11-04)
                slot:SetZOrder(-1)
                if tex and tex:IsValid() then img:SetBrushFromTexture(tex, false) end
                shown[id] = (img:GetFullName():gsub("^%S+ ", ""))
            end
            img:SetColorAndOpacity(mark.color)
            -- (the map's icons are placed by their render translation, their box at the point - this one centred on it)
            local x, y = project(c, orient, mark.at.X, mark.at.Y)
            img:SetRenderTranslation({ X = x, Y = y })
            log("map marks: %s at %.0f %.0f on the map", id, x, y)
            img:SetVisibility(4)                                     -- (hit-test invisible: the map's own icons get the mouse)
        end)
        if not ok then log("map marks: %s couldn't be drawn (%s)", id, tostring(err)) end
    end
end

local function refresh()
    local m = mapUp()
    if not m then shown = {} return end
    -- (marks taken away since: off the map)
    for id, path in pairs(shown) do
        if not marks[id] then
            local img = StaticFindObject(path)
            if img and img:IsValid() then pcall(function() img:RemoveFromParent() end) end
            shown[id] = nil
        end
    end
    draw(m)
end

local function publishLabels()
    local labels = {}
    for id, mark in pairs(marks) do labels[id] = mark.label end
    WaCa.Publish("map.marks", labels, true)
end

function MapMarks.Set(id, at, color, label)
    marks[id] = { at = { X = at.X, Y = at.Y }, color = color, label = label or id }
    publishLabels()
    ExecuteInGameThread(refresh)
end

function MapMarks.Clear(id)
    marks[id] = nil
    publishLabels()
    ExecuteInGameThread(refresh)
end

function MapMarks.Init(c)
    WaCa, log = c.WaCa, c.log
    WaCa.On("ScreenShown", function(screen)
        if not screen:GetClass():GetFName():ToString():find("WorldMap") then return end
        shown = {}
        ExecuteInGameThread(refresh)
    end)
end

return MapMarks
