-- Marks on the game's world map (operator 2026-10-30: "a cyan map marker for it"): Clan Life's places - the meeting
-- place you give out the clan's tasks at - drawn among the map's own icons when the map opens.
-- MapMarks.Set(id, { X, Y }, color) / MapMarks.Clear(id). A mark is an image in the map's icon layer
-- (GuiPopupWorldMap.CanvasGenericIcons), the legend's outpost icon tinted.
-- WHERE on the map: the map's own MapCoordinates (world box -> map box). Which way its axes run isn't in the data, so
-- it is read off the map itself: the player's icon (mcGuiPlayerIcon) sits where the game put your cat - of the eight
-- ways a world box can map onto the map box, the one that puts your cat there is the map's.
local MapMarks = {}
local WaCa, log
local marks = {}                    -- id -> { at = {X, Y}, color }
local shown = {}                    -- id -> image path (on the open map)
local orient                        -- { swap, flipU, flipV } once read off the map

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
    local pawn
    for _, pc in ipairs(FindAllOf("SwtPlayerController") or {}) do
        if pc:IsValid() and pc.Player and pc.Pawn and pc.Pawn:IsValid() then pawn = pc.Pawn end
    end
    if not pawn then return nil end
    local p = pawn:K2_GetActorLocation()
    local slot = m.mcGuiPlayerIcon.Slot
    local pos = slot:GetPosition()
    local best, bestD
    for _, swap in ipairs({ false, true }) do
        for _, fu in ipairs({ false, true }) do
            for _, fv in ipairs({ false, true }) do
                local o = { swap = swap, flipU = fu, flipV = fv }
                local mx, my = project(c, o, p.X, p.Y)
                local d = math.abs(mx - pos.X) + math.abs(my - pos.Y)
                if not bestD or d < bestD then best, bestD = o, d end
            end
        end
    end
    log("map marks: the map's axes read off your cat's icon (%s%s%s, %.0f off)", best.swap and "swapped " or "",
        best.flipU and "flip-u " or "", best.flipV and "flip-v" or "", bestD)
    return best
end

local function draw(m)
    local c = m.MapCoordinates
    orient = orient or readOrientation(m, c)
    if not orient then return end
    local canvas = m.CanvasGenericIcons
    local tex
    pcall(function() tex = m.mcGuiMapLegend.mcGuiLegendOutspot.Icon end)
    for id, mark in pairs(marks) do
        local ok, err = pcall(function()
            local path = shown[id]
            local img = path and StaticFindObject(path)
            if not (img and img:IsValid()) then
                img = StaticConstructObject(StaticFindObject("/Script/UMG.Image"), m.WidgetTree, FName("WaCaMapMark_" .. id))
                local slot = canvas:AddChildToCanvas(img)
                slot:SetAutoSize(false)
                slot:SetSize({ X = 56, Y = 56 })
                slot:SetAlignment({ X = 0.5, Y = 0.5 })
                slot:SetZOrder(50)
                if tex and tex:IsValid() then img:SetBrushFromTexture(tex, false) end
                shown[id] = (img:GetFullName():gsub("^%S+ ", ""))
            end
            img:SetColorAndOpacity(mark.color)
            local x, y = project(c, orient, mark.at.X, mark.at.Y)
            img.Slot:SetPosition({ X = x, Y = y })
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

function MapMarks.Set(id, at, color)
    marks[id] = { at = { X = at.X, Y = at.Y }, color = color }
    ExecuteInGameThread(refresh)
end

function MapMarks.Clear(id)
    marks[id] = nil
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
