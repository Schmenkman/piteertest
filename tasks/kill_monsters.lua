local utils      = require "core.utils"
local enums      = require "data.enums"
local settings   = require "core.settings"
local navigation = require "core.navigation"
local explorer   = require "core.explorer"

local stuck_position = nil

local task = {
    name = "Kill Monsters",
    shouldExecute = function()
        if not utils.player_on_quest(enums.quests.pit_ongoing) then
            return false
        end

        local close_enemy = utils.get_closest_enemy()
        return close_enemy ~= nil
    end,
    Execute = function()
        explorer.is_task_running = true  -- Setze dies am Anfang der Execute-Funktion
        explorer.current_task = "Kill Monsters"
        local player_pos = get_player_position()

        if explorer.check_if_stuck() then
            -- Log the stuck position
            stuck_position = player_pos
            return false
        end

        if stuck_position and utils.distance_to(stuck_position) < 25 then
            -- Player is still within 10 units of the stuck position, do not resume
            return false
        else
            -- Clear the stuck position once the player has moved 10+ units away
            stuck_position = nil
        end

        local distance_check = 4
        local enemy = utils.get_closest_enemy()
        if not enemy then return false end

        local within_distance = utils.distance_to(enemy) < distance_check

        if not within_distance then
            local enemy_pos = enemy:get_position()
    
            explorer:clear_path_and_target()
            explorer:set_custom_target(enemy_pos)
            explorer:move_to_target()
        else
            -- Der Spieler ist bereits innerhalb von 4 Metern, keine weitere Bewegung notwendig
        end

        
        explorer.current_task = nil
        explorer.is_task_running = false  -- Setze dies am Ende der Execute-Funktion
    end
}

return task