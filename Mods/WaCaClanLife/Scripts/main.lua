-- WaCa Clan Life: living in the clan. A day / night cycle with seasons and weather, the clan loop (the day in thirds:
-- the deputy's task, its turn-in, the clan's events - sharing tongues, meetings - and the night's sleep or watch),
-- Gatherings, the clan's own patrols, cats saying new things by day and story, exhaustion from effort, and a scene
-- system any mod can write story into (content/*.ini files - see the README). Needs WaCa Core.
local VERSION = "0.8.0"
local WaCa = require("WaCa")

local modDir = debug.getinfo(1, "S").source:match("^@(.+)[/\\]Scripts[/\\]main%.lua$") or "."
local function log(fmt, ...) print(string.format("[WaCaClanLife] " .. fmt .. "\n", ...)) end
log("%s loaded", VERSION)
if not WaCaNative_Command then
    log("WaCa Core is not installed (or off) - this mod needs it: nothing applied")
    return
end

-- ONE SWITCH (config/clanlife.ini): [ClanLife] On = 1 turns on every part in its Parts list, whatever that part's own
-- file says; parts not listed (or On = 0 here) follow their own file's On. So a player turns the clan's life on in one
-- place, and still tunes or adds single parts in their files.
local master = (WaCa.ReadIni(modDir .. "/config/clanlife.ini") or {})["ClanLife"] or {}
local masterParts = {}
if (master.On or "0") == "1" then
    for name in (master.Parts or ""):gmatch("[^,%s]+") do masterParts[name] = true end
end
local function part(name, own)
    return masterParts[name] == true or (own or "0") == "1"
end
do
    local on = {}
    for name in pairs(masterParts) do table.insert(on, name) end
    table.sort(on)
    log("clanlife.ini: %s", #on > 0 and ("on - " .. table.concat(on, ", ")) or "off (each part by its own file)")
end

-- the context every part gets
local function ctx(t)
    t.WaCa, t.log, t.modDir, t.part = WaCa, log, modDir, part
    return t
end

-- (the order matters where noted: each Init only subscribes - nothing runs until the game's events come)
local DayNight = require("daynight")
local Weather = require("weather")
local Events = require("events")
local Days = require("days")
local Duties = require("duties")

-- clan activities: ambient camp life (config/activities.ini)
require("activities").Init(ctx({ DayNight = DayNight }))
-- day / night cycle (config/daynight.ini)
DayNight.Init(ctx({}))
-- the story as days (config/days.ini) - before weather / duties: it sets their day up first on each DayStarted
Days.Init(ctx({ DayNight = DayNight, Weather = Weather, Duties = Duties, Events = Events }))
-- seasons and weather (config/weather.ini)
Weather.Init(ctx({ DayNight = DayNight }))
-- frozen water in leaf-bare (weather.ini [Ice])
require("ice").Init(ctx({}))
-- prey follows the season (config/weather.ini [Season.*] Prey)
require("preyworld").Init(ctx({ Weather = Weather }))
-- intentional time skips (config/timeskip.ini)
require("timeskip").Init(ctx({ DayNight = DayNight, Weather = Weather }))
-- more for clan cats to say, by time of day and story day (config/lines.ini)
require("lines").Init(ctx({ DayNight = DayNight, Days = Days, Events = Events }))
-- exhaustion: a resource - pounces and fights tire the cat, sleep resets it (config/exhaustion.ini)
require("exhaustion").Init(ctx({ DayNight = DayNight }))
-- scenes: the one scene runner + its hook points, and hour-scheduled scenes (config/events.ini) - before the loop
Events.Init(ctx({ DayNight = DayNight }))
-- following: cats moving together - a modding tool (follow.lua)
local Follow = require("follow")
Follow.Init(ctx({}))
-- the clan loop: thirds, the deputy's tasks, their turn-ins, the clan's events (config/duties.ini, clanevents.ini)
Duties.Init(ctx({ DayNight = DayNight, Events = Events, Days = Days }))
-- the clan's own patrols heading out together (config/patrols.ini)
require("patrols").Init(ctx({ Duties = Duties, Follow = Follow, Lines = require("lines") }))
-- the camp's walking cats are its named cats, in turns (after Duties: its thirds turn them)
require("walkers").Init(ctx({ Events = Events, Duties = Duties }))
-- Gatherings: the leader's pick, the announcement, attending or staying behind (config/gatherings.ini)
require("gathering").Init(ctx({ Events = Events, Days = Days, DayNight = DayNight }))
-- kits of your own: born to your cat and a mate, by the clan's nursery, kept with the save (config/kits.ini)
require("kits").Init(ctx({ DayNight = DayNight }))
-- romance, a draft: a mate by the game's own bond, kits after some days (config/romance.ini, off by default)
require("romance").Init(ctx({ Events = Events }))
-- the day at a glance on the HUD (clanlife.ini [Hud])
require("hud").Init(ctx({}))
require("dayclock").Init(ctx({}))
require("mapmarks").Init(ctx({}))
-- clanmates comment on your hunts (lines.ini [Hunt])
require("huntlines").Init(ctx({}))
require("murmurs").Init(ctx({}))

WaCa.Ready()
