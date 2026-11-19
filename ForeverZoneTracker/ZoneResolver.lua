local _, ns = ...

-- These are the native UI map types, not Classic area IDs. Never compare a
-- continent to a quest's zone: that would show every quest on the continent.
local ZONE, DUNGEON, MICRO = 3, 4, 5

local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, result = pcall(fn, ...)
    if ok then return result end
end
ns.Call = call

local function nameKey(name)
    if type(name) ~= "string" then return nil end
    name = name:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    name = name:lower():gsub("^%s+", ""):gsub("%s+$", "")
    if name ~= "" then return name end
end

-- A micro map belongs to its zone; dungeon floors belong to their dungeon,
-- not to the outdoor zone containing the entrance. Use a per-refresh cache so
-- missing map data can recover on a later refresh.
function ns.MapArea(mapID, cache)
    if type(mapID) ~= "number" or mapID <= 0 then return nil end
    if cache[mapID] ~= nil then return cache[mapID] or nil end
    local original, seen, dungeon = mapID, {}, nil
    for _ = 1, 20 do
        if seen[mapID] then break end
        seen[mapID] = true
        local info = call(C_Map and C_Map.GetMapInfo, mapID)
        if not info then break end
        if info.mapType == ZONE then
            local result = dungeon or { id = mapID, name = info.name, kind = ZONE }
            cache[original] = result
            return result
        elseif info.mapType == DUNGEON then
            dungeon = { id = mapID, name = info.name, kind = DUNGEON }
        elseif info.mapType ~= MICRO then
            break
        end
        if not info.parentMapID or info.parentMapID <= 0 then break end
        mapID = info.parentMapID
    end
    cache[original] = dungeon or false
    return dungeon
end

function ns.ReadZone()
    local mapID = call(C_Map and C_Map.GetBestMapForUnit, "player")
    local cache = {}
    local area = ns.MapArea(mapID, cache)
    local inInstance = call(IsInInstance) == true
    local instanceName = inInstance and call(GetInstanceInfo) or nil
    local realName = call(GetRealZoneText)

    -- Quest categories need a zone NAME, not a map ID. Map data can lag behind
    -- a zone transition or be unavailable even when GetRealZoneText is valid.
    if inInstance and (not area or area.kind ~= DUNGEON) then
        area, mapID = nil, nil
    end
    local names = {}
    local function add(name)
        local key = nameKey(name)
        if key then names[key] = true end
    end
    local name
    if inInstance then
        if area then add(area.name) end
        add(instanceName)
        name = nameKey(instanceName) and instanceName or (area and area.name)
    elseif nameKey(realName) then
        -- Never retain a stale map's old zone as an additional matching name.
        add(realName)
        name = realName
    elseif area then
        add(area.name)
        name = area.name
    end
    if not nameKey(name) then return nil end

    local zone = {
        mapID = mapID, area = area, cache = cache, names = names,
        inInstance = inInstance,
        name = name,
        key = (inInstance and "instance:" or "zone:") .. nameKey(name),
    }
    return zone
end

function ns.IsRelevant(quest, zone)
    -- Match the same zone/dungeon category the player sees in the quest log.
    -- Quest POIs and destination maps can disagree with that category on
    -- Forever (for example, a Badlands quest appearing local in Riverglades).
    -- They must neither promote an unrelated quest nor hide a local one.
    -- Explicit cross-zone pins are handled separately by Core.lua.
    return zone.names[nameKey(quest.header)] == true, "quest category"
end
