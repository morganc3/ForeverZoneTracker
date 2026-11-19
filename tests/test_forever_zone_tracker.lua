-- Run using Lua 5.1; ADDON_DIR can be supplied by a host such as lupa.lua51.
local addonDir = ADDON_DIR or "ForeverZoneTracker"
local passed = 0
local function eq(actual, expected, label)
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function quest(id, header, destination, extra)
    local q = { id = id, header = header, destination = destination, title = "Quest " .. id }
    for k, v in pairs(extra or {}) do q[k] = v end
    return q
end

local function newClient(options)
    options = options or {}
    local s = {
        map = 10, realZone = "Badlands", quests = {
            quest(101, "Badlands", 10), quest(102, "Badlands", 10),
            quest(201, "Stranglethorn Vale", 20),
        },
        watches = { 101, 201 }, calls = {}, timers = {}, now = 0,
        messages = {}, frames = {}, menuMods = {}, points = {}, cap = 25,
        focus = 0, focusWrites = 0, collapsedHeaders = {}, headerEdits = 0,
        maps = {
            [1] = { name = "Eastern Kingdoms", mapType = 2, parentMapID = 0 },
            [10] = { name = "Badlands", mapType = 3, parentMapID = 1 },
            [11] = { name = "Uldaman Excavation", mapType = 5, parentMapID = 10 },
            [20] = { name = "Stranglethorn Vale", mapType = 3, parentMapID = 1 },
            [2548] = { name = "Riverglades", mapType = 3, parentMapID = 1 },
            [40] = { name = "The Drowned City", mapType = 4, parentMapID = 20 },
            [41] = { name = "Lower Floor", mapType = 4, parentMapID = 40 },
            [42] = { name = "Chamber", mapType = 5, parentMapID = 41 },
        },
    }
    for k, v in pairs(options) do s[k] = v end
    local env = setmetatable({}, { __index = _G })
    env._G = env
    s.env = env
    function s:emit(event, ...)
        for _, f in ipairs(self.frames) do if f.events[event] then f.scripts.OnEvent(f, event, ...) end end
    end
    function s:advance(seconds)
        local target, iterations = self.now + (seconds or 0.4), 0
        while true do
            local first
            for i, t in ipairs(self.timers) do
                if t.time <= target and (not first or t.time < self.timers[first].time) then first = i end
            end
            if not first then break end
            iterations = iterations + 1
            assert(iterations < 1000, "timer/event feedback loop")
            local timer = table.remove(self.timers, first)
            self.now = timer.time
            timer.callback()
            if timer.period then
                timer.time = self.now + timer.period
                self.timers[#self.timers + 1] = timer
            end
        end
        self.now = target
    end
    function s:rows()
        local rows, last, headerNumber = {}, nil, 0
        for _, q in ipairs(self.quests) do
            local collapsed = self.collapsedHeaders[q.header]
            if collapsed == nil then collapsed = self.collapsed end
            if q.header and q.header ~= last then
                headerNumber = headerNumber + 1
                rows[#rows + 1] = { isHeader = true, title = q.header, isCollapsed = collapsed,
                    headerSortKey = not self.noHeaderKeys and headerNumber or nil, questLogIndex = #rows + 1 }
                last = q.header
            end
            if not (self.hideCollapsed and collapsed) then
                rows[#rows + 1] = { questID = q.id, title = q.title, questLogIndex = #rows + 1,
                    isHidden = q.hidden, isTask = q.task, isBounty = q.bounty, isOnMap = q.isOnMap }
            end
        end
        return rows
    end
    function s:has(id)
        for _, watched in ipairs(self.watches) do if watched == id then return true end end
        return false
    end
    function s:expectWatches(...)
        local actual, wanted = {}, { ... }
        for _, id in ipairs(self.watches) do actual[#actual + 1] = id end
        table.sort(actual) table.sort(wanted)
        eq(table.concat(actual, ","), table.concat(wanted, ","), "watch list")
    end
    function s:command(message) env.SlashCmdList.FOREVERZONETRACKER(message) end
    function s:zone(map, name, instance)
        self.map, self.realZone, self.instance = map, name, instance
        self:emit("ZONE_CHANGED_NEW_AREA") self:advance()
    end
    function s:assertNoErrors()
        for _, message in ipairs(self.messages) do
            assert(not message:find("refresh failed", 1, true), message)
        end
    end
    env.CreateFrame = function(kind, name, parent, template)
        eq(kind, "Frame") eq(name, nil) eq(parent, nil) eq(template, nil)
        local f = { events = {}, scripts = {} }
        function f:RegisterEvent(event) self.events[event] = true end
        function f:SetScript(script, fn) self.scripts[script] = fn end
        s.frames[#s.frames + 1] = f
        return f
    end
    env.C_Timer = {
        After = function(delay, callback) s.timers[#s.timers + 1] = { time = s.now + delay, callback = callback } end,
        NewTicker = function(period, callback)
            local timer = { time = s.now + period, period = period, callback = callback }
            s.timers[#s.timers + 1] = timer return timer
        end,
    }
    env.DEFAULT_CHAT_FRAME = { AddMessage = function(_, message) s.messages[#s.messages + 1] = message end }
    env.SlashCmdList = {}
    env.ForeverZoneTrackerDB = s.saved
    env.InCombatLockdown = function() return s.combat == true end
    env.GetTime = function() return s.now end
    env.ExpandQuestHeader = function(index)
        assert(not s.combat, "header expansion during combat")
        local header = s:rows()[index]
        assert(header and header.isHeader, "wrong header index expanded")
        if s.failExpand == header.title then error("simulated expansion failure") end
        s.collapsedHeaders[header.title] = false s.headerEdits = s.headerEdits + 1
        s:emit("QUEST_LOG_UPDATE")
    end
    env.CollapseQuestHeader = function(index)
        assert(not s.combat, "header collapse during combat")
        local header = s:rows()[index]
        assert(header and header.isHeader, "wrong header index collapsed")
        if s.failCollapse == header.title then error("simulated collapse failure") end
        s.collapsedHeaders[header.title] = true s.headerEdits = s.headerEdits + 1
        s:emit("QUEST_LOG_UPDATE")
    end
    env.IsInInstance = function() return s.instance ~= nil, s.instance and "party" or "none" end
    env.GetInstanceInfo = function() return s.instance end
    env.GetRealZoneText = function() return s.realZone end
    env.Constants = { QuestWatchConsts = { MAX_QUEST_WATCHES = s.cap } }
    env.C_Map = {
        GetBestMapForUnit = function(unit) eq(unit, "player") return s.map end,
        GetMapInfo = function(id) if s.mapError then error("map temporarily unavailable") end return s.maps[id] end,
        SetMapID = function() error("must not change the viewed map") end,
    }
    env.GetQuestUiMapID = function(id, ignoreWaypoints)
        eq(ignoreWaypoints, true, "ignore travel waypoints")
        if s.destinationError then error("destination missing") end
        for _, q in ipairs(s.quests) do if q.id == id then return q.destination end end
        return 0
    end
    env.C_SuperTrack = {
        GetSuperTrackedQuestID = function() return s.focus end,
        SetSuperTrackedQuestID = function(id) s.focus = id s.focusWrites = s.focusWrites + 1 end,
    }
    env.C_QuestLog = {
        GetNumQuestLogEntries = function() return #s:rows(), s.totalOverride or #s.quests end,
        GetInfo = function(i) if i == s.missingRow then return nil end return s:rows()[i] end,
        GetNumQuestWatches = function() return #s.watches end,
        GetQuestIDForQuestWatchIndex = function(i) return s.watches[i] end,
        GetQuestsOnMap = function(id) return s.points[id] end,
        GetSelectedQuest = function() return s.selected or 0 end,
        GetLogIndexForQuestID = function(id)
            for i, row in ipairs(s:rows()) do if row.questID == id then return i end end
        end,
        AddQuestWatch = function(...)
            eq(select("#", ...), 1, "Forever AddQuestWatch argument count")
            assert(not s.combat, "watch modified in combat")
            local id = ...
            s.calls[#s.calls + 1] = { "add", id }
            if s:has(id) or #s.watches >= s.cap or s.refuseAdd == id then return false end
            if s.throwAdd then error("simulated add failure") end
            s.watches[#s.watches + 1] = id
            s:emit("QUEST_WATCH_LIST_CHANGED", id, true)
            s:emit("QUEST_LOG_UPDATE")
            return true
        end,
        RemoveQuestWatch = function(id)
            assert(not s.combat, "watch modified in combat")
            s.calls[#s.calls + 1] = { "remove", id }
            if s.refuseRemove == id then return false end
            for i, watched in ipairs(s.watches) do
                if watched == id then
                    table.remove(s.watches, i)
                    if s.clearFocusOnRemove then s.focus = 0 end
                    s:emit("QUEST_WATCH_LIST_CHANGED", id, false)
                    s:emit("QUEST_LOG_UPDATE")
                    return true
                end
            end
            return false
        end,
    }
    env.hooksecurefunc = function(tbl, key, hook)
        local original = tbl[key]
        tbl[key] = function(...)
            local result = original(...)
            hook(...)
            return result
        end
    end
    env.Menu = { ModifyMenu = function(tag, modifier) s.menuMods[tag] = modifier end }
    if s.beforeLoad then s.beforeLoad(env) end
    s.ns = {}
    for _, file in ipairs({ "ZoneResolver.lua", "QuestLog.lua", "Core.lua", "Menu.lua" }) do
        local chunk = assert(loadfile(addonDir .. "/" .. file))
        setfenv(chunk, env)("ForeverZoneTracker", s.ns)
    end
    s:emit("ADDON_LOADED", "ForeverZoneTracker")
    s:emit("PLAYER_LOGIN")
    s:emit("PLAYER_ENTERING_WORLD")
    if not s.defer then s:advance() end
    return s
end

local function test(name, fn)
    if TEST_FILTER and not name:find(TEST_FILTER, 1, true) then return end
    local ok, err = pcall(fn)
    if not ok then error("FAIL " .. name .. ": " .. tostring(err), 0) end
    passed = passed + 1
    print("PASS " .. name)
end

test("automatically shows ALL local quests in native tracker", function()
    local s = newClient() s:expectWatches(101, 102)
    eq(s.env.ForeverZoneTrackerDB.baseline[201], true)
    eq(s.env.ForeverZoneTrackerDB.baseline[102], false)
    eq(next(s.env.ForeverZoneTrackerDB.excluded), nil)
    s:assertNoErrors()
end)
test("zone changes hide old quests and restore new local quests", function()
    local s = newClient() s:zone(20, "Stranglethorn Vale") s:expectWatches(201)
    s:zone(10, "Badlands") s:expectWatches(101, 102)
end)
test("off restores baseline and on takes a fresh snapshot", function()
    local s = newClient() s:command("off") s:expectWatches(101, 201)
    eq(s.env.ForeverZoneTrackerDB.baseline, nil)
    s.env.C_QuestLog.RemoveQuestWatch(101)
    s:command("on") s:expectWatches(101, 102)
    s:command("off") s:expectWatches(201)
end)
test("map POIs cannot promote a quest from another category", function()
    local s = newClient({ points = { [10] = { { questID = 201 } } } })
    s:expectWatches(101, 102)
end)
test("entrance indicator pins do not make distant quests local", function()
    local s = newClient({ points = { [10] = { { questID = 201, isMapIndicatorQuest = true } } } })
    s:expectWatches(101, 102)
end)
test("quest category remains authoritative when its destination changes", function()
    local s = newClient() s.quests[1].destination = 20
    s:emit("QUEST_LOG_UPDATE") s:advance() s:expectWatches(101, 102)
    s:zone(20, "Stranglethorn Vale") s:expectWatches(201)
end)
test("missing destination does not interfere with localized category", function()
    local s = newClient({ destinationError = true }) s:expectWatches(101, 102) s:assertNoErrors()
end)
test("normalizes colored category and whitespace", function()
    local s = newClient({ quests = { quest(101, " |cffff0000BADLANDS|r ", nil) } })
    s:expectWatches(101, 201) -- unknown watched IDs are deliberately left alone
end)
test("viewed-map flags never influence player zone filtering", function()
    local s = newClient({ quests = { quest(101, "Badlands", 10, { isOnMap = false }),
        quest(201, "Stranglethorn Vale", 20, { isOnMap = true }) } }) s:expectWatches(101)
end)
test("micro maps use their surrounding zone", function()
    local s = newClient() s:zone(11, "Badlands") s:expectWatches(101, 102)
end)
test("dungeon floors group under dungeon without outdoor quests", function()
    local s = newClient({ quests = { quest(101, "Badlands", 10), quest(201, "Stranglethorn Vale", 20),
        quest(401, "The Drowned City", 41), quest(402, "The Drowned City", 20) } })
    s:zone(42, "Chamber", "The Drowned City") s:expectWatches(401, 402)
end)
test("custom unmapped dungeon uses exact instance category", function()
    local s = newClient({ quests = { quest(101, "Badlands", 10), quest(201, "Stranglethorn Vale", 20),
        quest(501, "Excavation Site: Wetlands", nil) } })
    s:zone(nil, "Excavation Site: Wetlands", "Excavation Site: Wetlands") s:expectWatches(501)
end)
test("stale outdoor map in instance does not match outdoor quests", function()
    local s = newClient({ quests = { quest(101, "Badlands", 10), quest(201, "Stranglethorn Vale", 20),
        quest(401, "The Drowned City", 20) } })
    s:zone(20, "The Drowned City", "The Drowned City") s:expectWatches(401)
end)
test("missing player map leaves watch list alone and later recovers", function()
    local s = newClient() s:zone(nil, "") s:expectWatches(101, 102)
    s.map, s.realZone = 20, "Stranglethorn Vale"
    s:advance(5.5) s:expectWatches(201)
end)
test("continent map does not override the actual zone name", function()
    local s = newClient() s:zone(1, "Stranglethorn Vale") s:expectWatches(201)
end)
test("loading screens suspend updates", function()
    local s = newClient() s:emit("PLAYER_LEAVING_WORLD")
    s:zone(20, "Stranglethorn Vale") s:expectWatches(101, 102)
    s:emit("PLAYER_ENTERING_WORLD") s:advance() s:expectWatches(201)
end)
test("combat defers watch updates and restoration", function()
    local s = newClient() s.combat = true
    s:zone(20, "Stranglethorn Vale") s:expectWatches(101, 102)
    s:command("off") s:expectWatches(101, 102)
    s.combat = false s:emit("PLAYER_REGEN_ENABLED") s:advance() s:expectWatches(101, 201)
end)
test("native Stop Tracking exclusion survives zone changes", function()
    local s = newClient() s.env.C_QuestLog.RemoveQuestWatch(102) s:advance()
    s:expectWatches(101) s:zone(20, "Stranglethorn Vale") s:zone(10, "Badlands") s:expectWatches(101)
    s:command("reset") s:expectWatches(101, 102)
end)
test("native Track clears exclusion and is preserved by off", function()
    local s = newClient() s.env.C_QuestLog.RemoveQuestWatch(102) s:advance()
    s.env.C_QuestLog.AddQuestWatch(102) s:advance()
    s:command("off") s:expectWatches(101, 102, 201)
end)
test("rejected manual add does not rewrite baseline", function()
    local s = newClient({ cap = 2 }) s.env.C_QuestLog.AddQuestWatch(201) s:advance()
    eq(s.env.ForeverZoneTrackerDB.baseline[201], true)
    s:command("off") s:expectWatches(101, 201)
end)
test("rejected manual removal does not create exclusion", function()
    local s = newClient({ refuseRemove = 101 }) s.env.C_QuestLog.RemoveQuestWatch(101) s:advance()
    eq(s.env.ForeverZoneTrackerDB.excluded[101], nil)
end)
test("saved baseline survives reload instead of capturing filtered watches", function()
    local first = newClient()
    local second = newClient({ saved = first.env.ForeverZoneTrackerDB, watches = first.watches })
    second:command("off") second:expectWatches(101, 201)
end)
test("empty loading log does not erase pending restore", function()
    local s = newClient({ quests = {}, watches = {}, saved = { enabled = false, baseline = { [201] = true } } })
    eq(s.env.ForeverZoneTrackerDB.baseline[201], true)
    s.quests = { quest(201, "Stranglethorn Vale", 20) }
    s:emit("QUEST_LOG_UPDATE") s:advance() s:expectWatches(201)
    eq(s.env.ForeverZoneTrackerDB.baseline, nil)
end)
test("collapsed categories retain all child quests", function()
    local s = newClient({ collapsed = true }) s:expectWatches(101, 102)
end)
test("partial quest log data fails open", function()
    local s = newClient({ totalOverride = 10 }) s:expectWatches(101, 201)
    s.totalOverride = nil s:emit("QUEST_LOG_UPDATE") s:advance() s:expectWatches(101, 102)
end)
test("nil quest rows fail open", function()
    local s = newClient({ missingRow = 2 }) s:expectWatches(101, 201)
end)
test("hidden quests and bonus objectives are not managed", function()
    local s = newClient({ quests = { quest(101, "Badlands", 10), quest(201, "Stranglethorn Vale", 20, { task = true }),
        quest(102, "Badlands", 10, { hidden = true }) } }) s:expectWatches(101, 201)
end)
test("newly accepted quests join automatic local tracking", function()
    local s = newClient() s.quests[#s.quests + 1] = quest(103, "Badlands", 10)
    s:emit("QUEST_ACCEPTED", 103) s:advance() s:expectWatches(101, 102, 103)
end)
test("pinned quest stays visible across zones and reload", function()
    local s = newClient() s:command("pin 201") s:expectWatches(101, 102, 201)
    s:zone(11, "Badlands") s:expectWatches(101, 102, 201)
    local r = newClient({ saved = s.env.ForeverZoneTrackerDB, watches = s.watches })
    r:expectWatches(101, 102, 201) r:command("unpin 201") r:expectWatches(101, 102)
end)
test("pin accepts selected quest, exact title and quest link", function()
    local s = newClient({ selected = 201 }) s:command("pin") s:expectWatches(101, 102, 201)
    s:command("unpin Quest 201") s:expectWatches(101, 102)
    s:command("pin |cffffff00|Hquest:201:40|h[Quest 201]|h|r") s:expectWatches(101, 102, 201)
end)
test("invalid pin does not mutate watches", function()
    local s = newClient() s:command("pin typo") s:command("pin 999") s:command("pin")
    s:expectWatches(101, 102) eq(next(s.env.ForeverZoneTrackerDB.pinned), nil)
end)
test("native untrack removes pin and keeps quest hidden", function()
    local s = newClient() s:command("pin 201") s.env.C_QuestLog.RemoveQuestWatch(201) s:advance()
    eq(s.env.ForeverZoneTrackerDB.pinned[201], nil)
    s:zone(20, "Stranglethorn Vale") s:expectWatches()
end)
test("pin prioritizes an out-of-zone quest over locals at watch cap", function()
    local s = newClient({ cap = 2 }) s:command("pin 201") s:expectWatches(101, 201)
    s:command("unpin 201") s:expectWatches(101, 102)
end)
test("pin changes wait for combat to end", function()
    local s = newClient() s.combat = true s:command("pin 201") s:expectWatches(101, 102)
    s.combat = false s:emit("PLAYER_REGEN_ENABLED") s:advance() s:expectWatches(101, 102, 201)
end)
test("quest removal clears saved preferences", function()
    local s = newClient() s:command("pin 201")
    table.remove(s.quests, 3) table.remove(s.watches, 3)
    s:emit("QUEST_REMOVED", 201) s:advance()
    eq(s.env.ForeverZoneTrackerDB.pinned[201], nil)
    eq(s.env.ForeverZoneTrackerDB.baseline[201], nil)
end)
test("native quest menu checkbox pins its owner quest", function()
    local s = newClient() local checkbox, divided
    local root = {
        CreateDivider = function() divided = true end,
        CreateCheckbox = function(_, label, selected, toggle) checkbox = { label = label, selected = selected, toggle = toggle } end,
    }
    local modify = s.menuMods.MENU_QUEST_MAP_LOG_TITLE
    modify({ questID = 201 }, root)
    eq(divided, true) eq(checkbox.label, "Keep showing across zones") eq(checkbox.selected(), false)
    checkbox.toggle() s:expectWatches(101, 102, 201) eq(checkbox.selected(), true)
    checkbox.toggle() s:expectWatches(101, 102)
    checkbox = nil modify({}, root) eq(checkbox, nil) -- user waypoint uses same native menu tag
end)
test("late-loaded native menu API gains extension", function()
    local s = newClient({ beforeLoad = function(env) env.Menu = false end })
    s.env.Menu = { ModifyMenu = function(tag, cb) s.menuMods[tag] = cb end }
    s:emit("ADDON_LOADED", "Blizzard_Menu")
    eq(type(s.menuMods.MENU_QUEST_MAP_LOG_TITLE), "function")
end)
test("event bursts debounce and stable refreshes do not rewrite watches", function()
    local s = newClient() local writes = #s.calls
    for _ = 1, 50 do s:emit("QUEST_LOG_UPDATE") end
    eq(#s.timers, 2) s:advance(11) eq(#s.calls, writes) s:assertNoErrors()
end)
test("unknown APIs disable filtering without changing watches", function()
    local s = newClient({ beforeLoad = function(env) env.C_Timer = nil end })
    s:expectWatches(101, 201) eq(s.env.ForeverZoneTrackerDB.enabled, false)
    s:command("on") s:expectWatches(101, 201) eq(s.env.ForeverZoneTrackerDB.enabled, false)
end)
test("failed watch API recovers on a subsequent tick", function()
    local s = newClient({ throwAdd = true }) s:expectWatches(101)
    s.throwAdd = false s:advance(5.5) s:expectWatches(101, 102)
end)
test("local quest navigation focus restored only when cleared", function()
    local s = newClient({ focus = 101, clearFocusOnRemove = true })
    eq(s.focus, 101) eq(s.focusWrites, 1)
    local r = newClient({ focus = 0 }) eq(r.focusWrites, 0)
end)
test("map errors do not prevent filtering by a valid zone name", function()
    local s = newClient({ mapError = true }) s:expectWatches(101, 102) s:assertNoErrors()
end)
test("Riverglades excludes Badlands despite a misleading local pin and destination", function()
    local s = newClient({ map = 2548, realZone = "Riverglades", watches = { 201 },
        quests = { quest(301, "Riverglades", 2548),
            quest(201, "Badlands", 2548, { title = "Broken Alliances" }) },
        points = { [2548] = { { questID = 201 } } },
    })
    s:expectWatches(301)
    eq(next(s.env.ForeverZoneTrackerDB.pinned), nil)
    s:command("pin Broken Alliances") s:expectWatches(201, 301)
    s:command("unpin Broken Alliances") s:expectWatches(301)
end)
test("Riverglades keeps its category quests despite distant or missing map data", function()
    local s = newClient({ map = 2548, realZone = "Riverglades", watches = {},
        quests = { quest(301, "Riverglades", 20), quest(302, "Riverglades", nil),
            quest(401, "Alchemy", 2548) },
        points = { [2548] = { { questID = 401 } } },
    })
    s:expectWatches(301, 302)
end)
test("entering Badlands still updates when player map is unavailable", function()
    local s = newClient({ map = 20, realZone = "Stranglethorn Vale" })
    s:expectWatches(201)
    s:zone(nil, "Badlands")
    s:expectWatches(101, 102)
end)
test("zone change succeeds with collapsed quest categories and restores them", function()
    local s = newClient({ map = 20, realZone = "Stranglethorn Vale", hideCollapsed = true })
    s:expectWatches(201)
    s.collapsedHeaders = { Badlands = true, ["Stranglethorn Vale"] = true }
    s:zone(10, "Badlands")
    s:expectWatches(101, 102)
    eq(s.collapsedHeaders.Badlands, true)
    eq(s.collapsedHeaders["Stranglethorn Vale"], true)
    s:zone(20, "Stranglethorn Vale") s:expectWatches(201)
    s:command("off") s:expectWatches(101, 201)
end)
test("stale map data cannot keep the previous zone visible", function()
    local s = newClient({ map = 20, realZone = "Stranglethorn Vale" })
    s:zone(20, "Badlands") s:expectWatches(101, 102)
    s:command("status")
    assert(table.concat(s.messages, "\n"):find("current zone: Badlands", 1, true))
end)
test("zone filtering works when the entire map API is unavailable", function()
    local s = newClient({ beforeLoad = function(env) env.C_Map = nil end })
    s:expectWatches(101, 102)
    s:zone(nil, "Stranglethorn Vale") s:expectWatches(201)
end)
test("timer fallback recovers missed zone events without NewTicker", function()
    local s = newClient({ beforeLoad = function(env) env.C_Timer.NewTicker = nil end })
    s.realZone, s.map = "Stranglethorn Vale", nil
    s:advance(5.5) s:expectWatches(201)
    s.realZone = "Badlands"
    s:advance(5.5) s:expectWatches(101, 102)
end)
test("mixed collapsed categories preserve the player's layout", function()
    local s = newClient({ hideCollapsed = true,
        collapsedHeaders = { Badlands = true, ["Stranglethorn Vale"] = false } })
    s:expectWatches(101, 102)
    eq(s.collapsedHeaders.Badlands, true)
    eq(s.collapsedHeaders["Stranglethorn Vale"], false)
end)
test("collapsed category recovery also works without header sort keys", function()
    local s = newClient({ hideCollapsed = true, noHeaderKeys = true,
        collapsedHeaders = { Badlands = true, ["Stranglethorn Vale"] = true } })
    s:expectWatches(101, 102)
    eq(s.collapsedHeaders.Badlands, true)
    eq(s.collapsedHeaders["Stranglethorn Vale"], true)
end)
test("expansion failure restores categories before retrying", function()
    local s = newClient({ hideCollapsed = true, failExpand = "Badlands",
        collapsedHeaders = { Badlands = true, ["Stranglethorn Vale"] = true } })
    s:expectWatches(101, 201)
    eq(s.collapsedHeaders.Badlands, true)
    eq(s.collapsedHeaders["Stranglethorn Vale"], true)
    s.failExpand = nil s:advance(5.5) s:expectWatches(101, 102)
end)
test("failed header restoration recovers on the next update", function()
    local s = newClient({ hideCollapsed = true, failCollapse = "Badlands",
        collapsedHeaders = { Badlands = true, ["Stranglethorn Vale"] = true } })
    s:expectWatches(101, 201)
    s:command("status")
    assert(table.concat(s.messages, "\n"):find("Header restoration failed", 1, true))
    s.failCollapse = nil s:advance(5.5) s:expectWatches(101, 102)
    eq(s.collapsedHeaders.Badlands, true)
    eq(s.collapsedHeaders["Stranglethorn Vale"], true)
end)
test("collapsed headers are never expanded in combat", function()
    local s = newClient({ hideCollapsed = true, combat = true,
        collapsedHeaders = { Badlands = true, ["Stranglethorn Vale"] = true } })
    s:expectWatches(101, 201) eq(s.headerEdits, 0)
    s.combat = false s:emit("PLAYER_REGEN_ENABLED") s:advance()
    s:expectWatches(101, 102) eq(s.collapsedHeaders.Badlands, true)
end)
test("status names the current zone and blocked scan instead of stale counts", function()
    local s = newClient({ map = 20, realZone = "Stranglethorn Vale" })
    s.totalOverride = 10 s:zone(10, "Badlands") s:expectWatches(201)
    s.messages = {} s:command("status")
    local report = table.concat(s.messages, "\n")
    assert(report:find("current zone: Badlands", 1, true))
    assert(report:find("Quest log incomplete: 3 of 10", 1, true))
    assert(report:find("Last applied zone: Stranglethorn Vale", 1, true))
    assert(not report:find("1 shown", 1, true))
    s.totalOverride = nil s:advance(5.5) s:expectWatches(101, 102)
end)
test("missing header APIs leave partial data untouched with a clear reason", function()
    local s = newClient({ hideCollapsed = true,
        collapsedHeaders = { Badlands = true },
        beforeLoad = function(env) env.ExpandQuestHeader = nil end })
    s:expectWatches(101, 201) eq(s.headerEdits, 0)
    s:command("status")
    assert(table.concat(s.messages, "\n"):find("Quest log incomplete", 1, true))
end)
print(string.format("%d tests passed under %s", passed, _VERSION))
