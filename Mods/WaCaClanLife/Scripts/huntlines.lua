-- Clanmates comment on a hunt (operator 2026-10-30, future work: "your party mates should be able to say a line of
-- dialogue after you land or miss a hunt"). config/lines.ini [Hunt] (a story pack's content\lines.ini adds lines):
-- after a catch or a missed pounce (WaCa Hunting's HuntCaught / HuntMissed) the clanmate nearest your cat - within
-- Radius - says one of the Caught / Missed lines, by Chance %. {PLAYER} = your cat's name, {PREY} = the prey kind
-- (mouse, rabbit ...). The line shows as WaCa Cutscenes' subtitle (its ShowLine event); without WaCa Cutscenes it is
-- only logged.
local HuntLines = {}
local WaCa, log
local cfg = { on = true, radius = 1500, chance = 100, caught = {}, missed = {} }
local PREY = { Mice = "mouse", Squirrel = "squirrel", Rabbit = "rabbit", Bird = "bird", Rat = "rat", Fish = "fish" }

local function kindName(value)
    local name
    pcall(function()
        StaticFindObject("/Script/SwtQuest.ESwtQuestCharacterType"):ForEachName(function(n, v)
            if v == tonumber(value) then name = n:ToString():gsub("^.*::", ""):gsub("^Weak", "") end
        end)
    end)
    return PREY[name or ""] or (name and name:lower()) or "prey"
end

local function speaker()
    local mine = WaCa.PlayerClan and WaCa.PlayerClan() or nil
    for _, c in ipairs(WaCa.Cats and WaCa.Cats() or {}) do
        if c.dist <= cfg.radius and (not mine or not c.clan or c.clan == mine) then return c end
    end
end

local function comment(list, kind)
    if #list == 0 or math.random(100) > cfg.chance then return end
    local who = speaker()
    if not who then return end
    local line = list[math.random(#list)]
    local name = WaCa.PlayerName and WaCa.PlayerName() or "you"
    line = line:gsub("{PLAYER}", name):gsub("{PREY}", kindName(kind))
    log("hunt lines: %s: %s", who.name, line)
    WaCa.Emit("ShowLine", who.name .. ": " .. line)
end

function HuntLines.Init(c)
    WaCa, log = c.WaCa, c.log
    local ini = WaCa.ReadContent(c.modDir .. "/config/lines.ini", "lines") or {}
    local h = ini["Hunt"] or {}
    cfg.on = (h.On or "1") ~= "0"
    cfg.radius = tonumber(h.Radius or "") or cfg.radius
    cfg.chance = tonumber(h.Chance or "") or cfg.chance
    for _, k in ipairs(h.__order or {}) do
        if k:match("^Caught%d*$") then cfg.caught[#cfg.caught + 1] = h[k] end
        if k:match("^Missed%d*$") then cfg.missed[#cfg.missed + 1] = h[k] end
    end
    log("hunt lines: %s (%d for a catch, %d for a miss)", cfg.on and "on" or "off", #cfg.caught, #cfg.missed)
    if not cfg.on then return end
    WaCa.On("HuntCaught", function(_, _, _, kind) pcall(comment, cfg.caught, kind) end)
    WaCa.On("HuntMissed", function(_, _, _, kind) pcall(comment, cfg.missed, kind) end)
end

return HuntLines
