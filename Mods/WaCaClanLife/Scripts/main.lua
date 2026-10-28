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

-- (the order matters where noted: each Init only subscribes - nothing runs until the game's events come)
local DayNight = require("daynight")
local Weather = require("weather")
local Events = require("events")
local Days = require("days")
local Duties = require("duties")

-- clan activities: ambient camp life (config/activities.ini)
require("activities").Init({ WaCa = WaCa, log = log, modDir = modDir, DayNight = DayNight })
-- day / night cycle (config/daynight.ini)
DayNight.Init({ WaCa = WaCa, log = log, modDir = modDir })
-- the story as days (config/days.ini) - before weather / duties: it sets their day up first on each DayStarted
Days.Init({ WaCa = WaCa, log = log, modDir = modDir, DayNight = DayNight, Weather = Weather, Duties = Duties,
    Events = Events })
-- seasons and weather (config/weather.ini)
Weather.Init({ WaCa = WaCa, log = log, modDir = modDir, DayNight = DayNight })
-- prey follows the season (config/weather.ini [Season.*] Prey)
require("preyworld").Init({ WaCa = WaCa, log = log, modDir = modDir, Weather = Weather })
-- intentional time skips (config/timeskip.ini)
require("timeskip").Init({ WaCa = WaCa, log = log, modDir = modDir, DayNight = DayNight, Weather = Weather })
-- more for clan cats to say, by time of day and story day (config/lines.ini)
require("lines").Init({ WaCa = WaCa, log = log, modDir = modDir, DayNight = DayNight, Days = Days, Events = Events })
-- exhaustion: a resource - pounces and fights tire the cat, sleep resets it (config/exhaustion.ini)
require("exhaustion").Init({ WaCa = WaCa, log = log, modDir = modDir, DayNight = DayNight })
-- scenes: the one scene runner + its hook points, and hour-scheduled scenes (config/events.ini) - before the loop
Events.Init({ WaCa = WaCa, log = log, modDir = modDir, DayNight = DayNight })
-- following: cats moving together - a modding tool (follow.lua)
local Follow = require("follow")
Follow.Init({ WaCa = WaCa, log = log })
-- the clan loop: thirds, the deputy's tasks, their turn-ins, the clan's events (config/duties.ini, clanevents.ini)
Duties.Init({ WaCa = WaCa, log = log, modDir = modDir, DayNight = DayNight, Events = Events, Days = Days })
-- the clan's own patrols heading out together (config/patrols.ini)
require("patrols").Init({ WaCa = WaCa, log = log, modDir = modDir, Duties = Duties, Follow = Follow,
    Lines = require("lines") })
-- Gatherings: the leader's pick, the announcement, attending or staying behind (config/gatherings.ini)
require("gathering").Init({ WaCa = WaCa, log = log, modDir = modDir, Events = Events, Days = Days, DayNight = DayNight })

WaCa.Ready()
