local _, ns = ...
local installed

function ns.InstallMenu()
    if installed or not Menu or type(Menu.ModifyMenu) ~= "function" then return end
    -- The native quest-log menu's owner is the quest title button. Do not
    -- guess a quest from selected/focused state: the same tag is also used
    -- for user waypoints, and gamepad menus can have a different owner.
    Menu.ModifyMenu("MENU_QUEST_MAP_LOG_TITLE", function(owner, root)
        local id = owner and owner.questID
        if type(id) ~= "number" or id <= 0 then return end
        if C_QuestLog.GetLogIndexForQuestID and not C_QuestLog.GetLogIndexForQuestID(id) then return end
        root:CreateDivider()
        root:CreateCheckbox("Keep showing across zones", function()
            return ns.IsPinned(id)
        end, function()
            ns.SetPinned(id, not ns.IsPinned(id))
        end)
    end)
    installed = true
end
