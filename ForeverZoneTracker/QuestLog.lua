local _, ns = ...
local reading, pendingRestore

local function headerKey(info, occurrences)
    local title = info.title or ""
    occurrences[title] = (occurrences[title] or 0) + 1
    return info.headerSortKey ~= nil and ("sort:" .. tostring(info.headerSortKey))
        or ("title:" .. title .. ":" .. occurrences[title])
end

local function scan()
    local count, total = C_QuestLog.GetNumQuestLogEntries()
    local result = { quests = {}, byID = {}, headers = {}, seen = 0, total = total }
    if type(count) ~= "number" then result.issue = "Quest log entry count is unavailable." return result end
    local header, occurrences = nil, {}
    for index = 1, count do
        local info = C_QuestLog.GetInfo(index)
        if not info then result.issue = "Quest log row " .. index .. " is unavailable." return result end
        if info.isHeader then
            header = info.title
            result.headers[#result.headers + 1] = {
                index = index, key = headerKey(info, occurrences), collapsed = info.isCollapsed,
            }
        elseif type(info.questID) == "number" and info.questID > 0 then
            result.seen = result.seen + 1
            if not info.isHidden and not info.isTask and not info.isBounty then
                local quest = { id = info.questID, title = info.title, header = header }
                result.quests[#result.quests + 1], result.byID[quest.id] = quest, quest
            end
        end
    end
    return result
end

local function complete(result)
    return not result.issue and (type(result.total) ~= "number" or result.seen >= result.total)
end

local function restoreHeaders()
    if not pendingRestore then return end
    local headers, occurrences, unreadable = {}, {}, false
    local count = C_QuestLog.GetNumQuestLogEntries()
    assert(type(count) == "number", "quest log count unavailable during header restoration")
    for index = 1, count do
        local info = C_QuestLog.GetInfo(index)
        if not info then unreadable = true end
        if info and info.isHeader then
            local key = headerKey(info, occurrences)
            if pendingRestore[key] then headers[#headers + 1] = { index = index, key = key } end
        end
    end
    -- Collapsing later headers first keeps all earlier indexes valid.
    for index = #headers, 1, -1 do
        local header = headers[index]
        CollapseQuestHeader(header.index)
        pendingRestore[header.key] = nil
    end
    assert(not unreadable or not next(pendingRestore), "some quest headers are not available for restoration")
    pendingRestore = nil
end

function ns.ReadQuestLog()
    if reading then return nil, nil, "Quest log scan is already running." end
    if pendingRestore then
        if InCombatLockdown and InCombatLockdown() then return nil, nil, "Header restoration waits for combat." end
        local ok, err = pcall(restoreHeaders)
        if not ok then return nil, nil, "Header restoration failed: " .. tostring(err) end
    end
    local result = scan()
    if complete(result) then return result.quests, result.byID end
    if result.issue then return nil, nil, result.issue end
    local collapsed = {}
    for _, header in ipairs(result.headers) do
        if header.collapsed then collapsed[header.key] = true end
    end
    local reason = string.format("Quest log incomplete: %d of %d quests readable.", result.seen, result.total)
    if not next(collapsed) or type(ExpandQuestHeader) ~= "function" or type(CollapseQuestHeader) ~= "function" then
        return nil, nil, reason
    end
    if InCombatLockdown and InCombatLockdown() then return nil, nil, reason .. " Expansion waits for combat." end

    -- Some client paths omit children of collapsed categories. Expand only
    -- when the initial scan is incomplete, then restore the player's exact
    -- collapsed categories before returning or allowing a tracker update.
    reading, pendingRestore = true, collapsed
    local ok, expanded = pcall(function()
        for index = #result.headers, 1, -1 do
            local header = result.headers[index]
            if header.collapsed then ExpandQuestHeader(header.index) end
        end
        return scan()
    end)
    local restored, restoreError = pcall(restoreHeaders)
    reading = false
    if not restored then return nil, nil, "Header restoration failed: " .. tostring(restoreError) end
    if not ok then return nil, nil, "Quest log expansion failed: " .. tostring(expanded) end
    if complete(expanded) then return expanded.quests, expanded.byID end
    return nil, nil, expanded.issue or reason
end
