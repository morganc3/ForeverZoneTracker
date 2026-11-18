local ADDON_NAME, ns = ...
local frame = CreateFrame("Frame")
local db, loggedIn, inWorld, applying, scheduled, ready
local lastZone, lastStats, lastError
local REFRESH_DELAY = 0.35

local function say(message)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff80d5ffForever Zone Tracker:|r " .. message)
    end
end

local function supported()
    if not C_QuestLog or not C_Map then return false end
    for _, key in ipairs({ "GetNumQuestLogEntries", "GetInfo", "GetNumQuestWatches",
        "GetQuestIDForQuestWatchIndex", "AddQuestWatch", "RemoveQuestWatch" }) do
        if type(C_QuestLog[key]) ~= "function" then return false end
    end
    return type(C_Map.GetBestMapForUnit) == "function" and type(C_Map.GetMapInfo) == "function"
end

local function readLog()
    local count, total = C_QuestLog.GetNumQuestLogEntries()
    if type(count) ~= "number" then return nil end
    local quests, byID, header, seen = {}, {}, nil, 0
    for index = 1, count do
        local info = C_QuestLog.GetInfo(index)
        if not info then return nil end -- partial server data: leave watches alone
        if info.isHeader then
            header = info.title
        elseif type(info.questID) == "number" and info.questID > 0 then
            seen = seen + 1
            if not info.isHidden and not info.isTask and not info.isBounty then
                local quest = { id = info.questID, title = info.title, header = header }
                quests[#quests + 1], byID[quest.id] = quest, quest
            end
        end
    end
    -- Modern Forever exposes children of collapsed headers (the UI filters
    -- them afterwards). Fail open if a future build exposes only some quests.
    if type(total) == "number" and seen < total then return nil end
    return quests, byID
end

local function readWatches()
    local watched, ordered = {}, {}
    for index = 1, C_QuestLog.GetNumQuestWatches() do
        local id = C_QuestLog.GetQuestIDForQuestWatchIndex(index)
        if id then
            watched[id] = true
            ordered[#ordered + 1] = id
        end
    end
    return watched, ordered
end

local function setWatch(id, value)
    local fn = value and C_QuestLog.AddQuestWatch or C_QuestLog.RemoveQuestWatch
    local ok, result = pcall(fn, id) -- Forever AddQuestWatch has ONE argument.
    if not ok then lastError = tostring(result) end
    return ok and result ~= false
end

local function restore(quests, byID)
    if not db.baseline then return end
    -- A temporarily empty log at login must not erase the saved watch list.
    -- Real quest removals clear their baseline entries in QUEST_REMOVED.
    if #quests == 0 and next(db.baseline) then return end
    local watched, ordered = readWatches()
    -- Remove auto-added watches before restoring others, respecting the cap.
    for _, id in ipairs(ordered) do
        if byID[id] and db.baseline[id] == false then setWatch(id, false) end
    end
    for _, quest in ipairs(quests) do
        if db.baseline[quest.id] and not watched[quest.id] then setWatch(quest.id, true) end
    end
    local after = readWatches()
    for id, wanted in pairs(db.baseline) do
        if byID[id] and (after[id] == true) ~= wanted then return end
    end
    db.baseline = nil
end

local function refreshBody()
    if not ready or not db or not loggedIn or not inWorld or not supported() then return end
    if InCombatLockdown and InCombatLockdown() then return end
    local quests, byID = readLog()
    if not quests then return end
    if not db.enabled then
        restore(quests, byID)
        return
    end
    local zone = ns.ReadZone()
    if not zone then
        lastStats = { waiting = true }
        return
    end
    lastZone = zone
    local watched, ordered = readWatches()
    db.baseline = db.baseline or {}
    for _, quest in ipairs(quests) do
        if db.baseline[quest.id] == nil then
            db.baseline[quest.id] = watched[quest.id] == true
        end
    end
    local localIDs = ns.LocalQuests(zone)
    local wanted, matching, excluded, pinned, desired = {}, 0, 0, 0, 0
    for _, quest in ipairs(quests) do
        local relevant = ns.IsRelevant(quest, zone, localIDs)
        if relevant then matching = matching + 1 end
        if db.pinned[quest.id] then
            wanted[quest.id] = true
            pinned = pinned + 1
        elseif relevant then
            if db.excluded[quest.id] then
                excluded = excluded + 1
            else
                wanted[quest.id] = true
            end
        end
    end
    for _ in pairs(wanted) do desired = desired + 1 end
    -- Reserve the client's available slots for explicit pins before locals.
    local cap = Constants and Constants.QuestWatchConsts and Constants.QuestWatchConsts.MAX_QUEST_WATCHES
    if type(cap) == "number" then
        for _, id in ipairs(ordered) do if not byID[id] then cap = cap - 1 end end
        local selected, used = {}, 0
        for pass = 1, 2 do
            for _, quest in ipairs(quests) do
                if wanted[quest.id] and (db.pinned[quest.id] == true) == (pass == 1) and used < cap then
                    selected[quest.id], used = true, used + 1
                end
            end
        end
        wanted = selected
    end
    local focus = ns.Call(C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID)
    for _, id in ipairs(ordered) do
        if byID[id] and not wanted[id] then setWatch(id, false) end
    end
    for pass = 1, 2 do
        for _, quest in ipairs(quests) do
            if wanted[quest.id] and not watched[quest.id]
                and (db.pinned[quest.id] == true) == (pass == 1) then
                setWatch(quest.id, true)
            end
        end
    end
    -- Don't steal a user waypoint or another local quest's navigation focus.
    -- Restore the selected LOCAL quest only if changing watches cleared it.
    if focus and wanted[focus] and C_SuperTrack and C_SuperTrack.SetSuperTrackedQuestID then
        local afterFocus = ns.Call(C_SuperTrack.GetSuperTrackedQuestID)
        if not afterFocus or afterFocus == 0 then
            pcall(C_SuperTrack.SetSuperTrackedQuestID, focus)
        end
    end
    local after, shown = readWatches(), 0
    for id in pairs(wanted) do if after[id] then shown = shown + 1 end end
    lastStats = { total = #quests, matching = matching, excluded = excluded,
        pinned = pinned, desired = desired, shown = shown }
end

function ns.Refresh()
    if applying then return end
    applying = true
    local ok, err = pcall(refreshBody)
    applying = false
    if not ok then
        local message = tostring(err)
        if lastError ~= message then
            say("A refresh failed; use /fzt status for the API error.")
        end
        lastError = message
    end
end

local function requestRefresh()
    if not ready or not db or not loggedIn or applying or scheduled then return end
    scheduled = true
    C_Timer.After(REFRESH_DELAY, function()
        scheduled = false
        ns.Refresh()
    end)
end

local function status()
    say((db.enabled and "ON" or "OFF") .. "; zone: " .. (lastZone and lastZone.name or "waiting"))
    if lastStats and lastStats.waiting then
        say("Waiting for the player's zone map; current watches have been left alone.")
    elseif lastStats and db.enabled then
        say(string.format("%d shown; %d local; %d pinned across zones; %d hidden; %d in your log.",
            lastStats.shown, lastStats.matching, lastStats.pinned, lastStats.excluded, lastStats.total))
        if lastStats.shown < lastStats.desired then
            say("Some watches were refused by the client (for example, its watch limit).")
        end
    end
    if InCombatLockdown and InCombatLockdown() then say("Changes wait until combat ends.") end
    if not db.enabled and db.baseline then say("Restoring your previous watch choices when possible.") end
    if lastError then say("Last API error: " .. lastError) end
end

function ns.IsPinned(id)
    return db and db.pinned[id] == true
end

function ns.SetPinned(id, value)
    local quests, byID = readLog()
    if not quests or not byID[id] then say("Choose a quest that is in your quest log.") return end
    db.pinned[id] = value and true or nil
    db.excluded[id] = nil
    if value and db.enabled then
        db.baseline = db.baseline or {}
        db.baseline[id] = true -- an explicit request to track this quest
    end
    ns.Refresh()
    say((value and "Pinned across zones: " or "Normal zone filtering: ") .. byID[id].title
        .. (not db.enabled and " (filtering is OFF)" or ""))
end

local function resolveQuest(argument)
    if argument == "" then return ns.Call(C_QuestLog and C_QuestLog.GetSelectedQuest) end
    local id = tonumber(argument) or tonumber(argument:match("|Hquest:(%d+):"))
    if id then return id end
    local quests = readLog()
    for _, quest in ipairs(quests or {}) do
        if quest.title:lower() == argument:lower() then return quest.id end
    end
end

local function slash(message)
    local command, argument = (message or ""):match("^%s*(%S*)%s*(.-)%s*$")
    command = command:lower()
    if command == "off" then
        db.enabled = false
        ns.Refresh()
        say(db.baseline and "OFF; restoring your previous tracking when the client allows it."
            or "OFF; your previous tracking choices are restored.")
    elseif command == "on" then
        if not ready then say("Required Forever APIs are unavailable; filtering remains OFF.") return end
        db.enabled = true
        ns.Refresh()
        say("ON; automatically showing quests for the current zone.")
    elseif command == "reset" then
        db.excluded = {}
        ns.Refresh()
        say("Manual exclusions cleared.")
    elseif command == "pin" or command == "unpin" then
        local id = resolveQuest(argument)
        if not id or id == 0 then
            say("Select a quest in your log, then /fzt " .. command .. "; or supply its exact name, link or ID.")
        else
            ns.SetPinned(id, command == "pin")
        end
    elseif command == "pins" then
        local quests, found = readLog(), false
        for _, quest in ipairs(quests or {}) do
            if db.pinned[quest.id] then say(quest.title .. " (" .. quest.id .. ")") found = true end
        end
        if not found then say("No quests pinned across zones.") end
    elseif command == "refresh" then
        ns.Refresh()
        status()
    elseif command == "status" then
        status()
    else
        say("/fzt on | off | status | reset | refresh")
        say("/fzt pin | unpin [quest name, link or ID]; /fzt pins to list. No name = selected quest.")
        say("Use the native Stop Tracking option to hide a quest; /fzt reset shows it again.")
        say("Use /fzt off before disabling or removing this addon to restore your old watches.")
    end
end

local function initialize()
    if type(ForeverZoneTrackerDB) ~= "table" then ForeverZoneTrackerDB = {} end
    db = ForeverZoneTrackerDB
    if db.enabled == nil then db.enabled = true end
    if type(db.excluded) ~= "table" then db.excluded = {} end
    if type(db.pinned) ~= "table" then db.pinned = {} end
    if type(db.baseline) ~= "table" then db.baseline = nil end
    db.version = 1
    SLASH_FOREVERZONETRACKER1 = "/fzt"
    SLASH_FOREVERZONETRACKER2 = "/zonetracker"
    SlashCmdList.FOREVERZONETRACKER = slash

    if not supported() or not C_Timer or not C_Timer.After or not hooksecurefunc then
        db.enabled = false
        say("Required Forever quest APIs are missing. Filtering is disabled; watches were not changed.")
        return
    end
    hooksecurefunc(C_QuestLog, "RemoveQuestWatch", function(id)
        if (db.enabled or db.baseline) and not applying and type(id) == "number" then
            if readWatches()[id] then return end -- rejected by the client
            if db.enabled then db.excluded[id], db.pinned[id] = true, nil end
            if db.baseline then db.baseline[id] = false end
            requestRefresh()
        end
    end)
    hooksecurefunc(C_QuestLog, "AddQuestWatch", function(id)
        if (db.enabled or db.baseline) and not applying and type(id) == "number" then
            if not readWatches()[id] then return end -- watch limit or other refusal
            if db.enabled then db.excluded[id] = nil end
            if db.baseline then db.baseline[id] = true end
            requestRefresh()
        end
    end)
    ready = true
    if ns.InstallMenu then ns.InstallMenu() end
    -- Zone/quest events do the normal work. A slow fallback recovers from nil
    -- map data at login and from missed events without per-frame polling.
    if C_Timer.NewTicker then
        ns.ticker = C_Timer.NewTicker(5, function()
            if db.enabled or db.baseline then requestRefresh() end
        end)
    end
end

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if ... == ADDON_NAME then initialize()
        elseif ready and ns.InstallMenu then ns.InstallMenu() end
    elseif event == "PLAYER_LOGIN" then
        loggedIn = true
    elseif event == "PLAYER_LEAVING_WORLD" then
        inWorld = false
    elseif event == "PLAYER_ENTERING_WORLD" then
        inWorld = true
        requestRefresh()
    elseif event == "QUEST_REMOVED" or event == "QUEST_TURNED_IN" then
        local id = ...
        if db and type(id) == "number" then
            db.excluded[id] = nil
            db.pinned[id] = nil
            if db.baseline then db.baseline[id] = nil end
        end
        requestRefresh()
    else
        requestRefresh()
    end
end)

for _, event in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD",
    "PLAYER_LEAVING_WORLD", "PLAYER_REGEN_ENABLED", "ZONE_CHANGED_NEW_AREA",
    "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "QUEST_LOG_UPDATE", "QUEST_POI_UPDATE",
    "QUEST_WATCH_LIST_CHANGED", "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN",
    "QUEST_WATCH_UPDATE", "QUEST_DATA_LOAD_RESULT" }) do
    pcall(frame.RegisterEvent, frame, event)
end
