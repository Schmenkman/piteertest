
local MinHeap = {}
MinHeap.__index = MinHeap

function MinHeap.new(compare)
    return setmetatable({
        heap = {},
        map = {},
        compare = compare or function(a, b) return a < b end
    }, MinHeap)
end

function MinHeap:push(value)
    table.insert(self.heap, value)
    self.map[value] = true
    self:siftUp(#self.heap)
end

function MinHeap:pop()
    local root = self.heap[1]
    self.heap[1] = self.heap[#self.heap]
    table.remove(self.heap)
    self.map[root] = nil
    self:siftDown(1)
    return root
end

function MinHeap:contains(value)
    return self.map[value] ~= nil
end

function MinHeap:siftUp(index)
    local value = self.heap[index]
    while index > 1 do
        local parentIndex = math.floor(index / 2)
        local parent = self.heap[parentIndex]
        if not self.compare(value, parent) then break end
        self.heap[index] = parent
        index = parentIndex
    end
    self.heap[index] = value
end

function MinHeap:empty()
    return #self.heap == 0
end

function MinHeap:siftDown(index)
    local heap = self.heap
    local size = #heap
    local value = heap[index]
    local compare = self.compare
    while true do
        local smallestIndex = index
        local left = 2 * index
        local right = left + 1
        if left <= size and compare(heap[left], heap[smallestIndex]) then
            smallestIndex = left
        end
        if right <= size and compare(heap[right], heap[smallestIndex]) then
            smallestIndex = right
        end
        if smallestIndex == index then break end
        heap[index] = heap[smallestIndex]
        index = smallestIndex
    end
    heap[index] = value
end


local utils = require "core.utils"
local enums = require "data.enums"
local settings = require "core.settings"
local tracker = require "core.tracker"
local explorer = {
    enabled = false,
    is_task_running = false, --added to prevent boss dead pathing 
}
local explored_areas = {}
local target_position = nil
local grid_size = 2            -- Size of grid cells in meters
local exploration_radius = 10   -- Radius in which areas are considered explored
local explored_buffer = 2      -- Buffer around explored areas in meters
local max_target_distance = 120 -- Maximum distance for a new target
local target_distance_states = {120, 40, 20, 5}
local target_distance_index = 1
local unstuck_target_distance = 2 -- Maximum distance for an unstuck target
local stuck_threshold = 5      -- Seconds before the character is considered "stuck"
local last_position = nil
local last_move_time = 0
local last_explored_targets = {}
local max_last_targets = 50




-- A* pathfinding variables
local current_path = {}
local path_index = 1

-- Explorationsmodus
local exploration_mode = "unexplored" -- "unexplored" oder "explored"

-- Richtung für den "explored" Modus
local exploration_direction = { x = 10, y = 0 } -- Initiale Richtung (kann angepasst werden)

-- Neue Variable für die letzte Bewegungsrichtung
local last_movement_direction = nil

--ai fix for kill monsters path
function explorer:clear_path_and_target()
    console.print("Clearing path and target.")
    target_position = nil
    current_path = {}
    path_index = 1
end

local function calculate_distance(point1, point2)
    --console.print("Calculating distance between points.")
    if not point2.x and point2 then
        return point1:dist_to_ignore_z(point2:get_position())
    end
    return point1:dist_to_ignore_z(point2)
end



--ai fix for stairs
local function set_height_of_valid_position(point)
    --console.print("Setting height of valid position.")
    return utility.set_height_of_valid_position(point)
end

local function get_grid_key(point)
    --console.print("Getting grid key.")
    return math.floor(point:x() / grid_size) .. "," ..
        math.floor(point:y() / grid_size) .. "," ..
        math.floor(point:z() / grid_size)
end

local explored_area_bounds = {
    min_x = math.huge,
    max_x = -math.huge,
    min_y = math.huge,
    max_y = -math.huge,
    min_z = math.huge,
    max_z = math.huge
}
local function update_explored_area_bounds(point, radius)
    --console.print("Updating explored area bounds.")
    explored_area_bounds.min_x = math.min(explored_area_bounds.min_x, point:x() - radius)
    explored_area_bounds.max_x = math.max(explored_area_bounds.max_x, point:x() + radius)
    explored_area_bounds.min_y = math.min(explored_area_bounds.min_y, point:y() - radius)
    explored_area_bounds.max_y = math.max(explored_area_bounds.max_y, point:y() + radius)
    explored_area_bounds.min_z = math.min(explored_area_bounds.min_z or math.huge, point:z() - radius)
    explored_area_bounds.max_z = math.max(explored_area_bounds.max_z or -math.huge, point:z() + radius)
end

local function is_point_in_explored_area(point)
    --console.print("Checking if point is in explored area.")
    return point:x() >= explored_area_bounds.min_x and point:x() <= explored_area_bounds.max_x and
        point:y() >= explored_area_bounds.min_y and point:y() <= explored_area_bounds.max_y and
        point:z() >= explored_area_bounds.min_z and point:z() <= explored_area_bounds.max_z
end


local function check_walkable_area()
    --console.print("Checking walkable area.")
    if os.time() % 5 ~= 0 then return end  -- Only run every 5 seconds

    local player_pos = get_player_position()
    local check_radius = 15 -- Überprüfungsradius in Metern
    local points = {}
    for x = -check_radius, check_radius, grid_size do
        for y = -check_radius, check_radius, grid_size do
            for z = -check_radius, check_radius, grid_size do
                table.insert(points, vec3:new(player_pos:x() + x, player_pos:y() + y, player_pos:z() + z))
            end
        end
    end
end

local huge = math.huge

local function reset_exploration()
    explored_area_bounds.min_x = huge
    explored_area_bounds.max_x = -huge
    explored_area_bounds.min_y = huge
    explored_area_bounds.max_y = -huge
    
    target_position = nil
    last_position = nil
    last_move_time = 0
    current_path = {}
    path_index = 1
    exploration_mode = "unexplored"
    last_movement_direction = nil

    console.print("Exploration reset. All areas marked as unexplored.")
end

local set_height_of_valid_position = set_height_of_valid_position
local is_point_walkeable = utility.is_point_walkeable

local directions = {
    vec3:new(1, 0, 0), vec3:new(-1, 0, 0), vec3:new(0, 1, 0), vec3:new(0, -1, 0),
    vec3:new(1, 1, 0), vec3:new(1, -1, 0), vec3:new(-1, 1, 0), vec3:new(-1, -1, 0)
}

local function is_near_wall(point)
    local wall_check_distance = 2
    local check_point = vec3:new()

    for _, dir in ipairs(directions) do
        check_point:set(
            point:x() + dir:x() * wall_check_distance,
            point:y() + dir:y() * wall_check_distance,
            point:z()
        )
        check_point = set_height_of_valid_position(check_point)
        if not is_point_walkeable(check_point) then
            return true
        end
    end
    return false
end

-- Removed the find_central_unexplored_target function
-- It was previously located here

local function find_random_explored_target()
    console.print("Finding random explored target.")
    local player_pos = get_player_position()
    local check_radius = max_target_distance
    local explored_points = {}
    local max_points = 50  -- Maximale Anzahl von Punkten, die wir sammeln wollen

    local set_height = set_height_of_valid_position
    local is_walkeable = utility.is_point_walkeable
    local near_wall = is_near_wall

    local point = vec3:new(0, 0, 0)
    local offsets = {}
    for x = -check_radius, check_radius, grid_size do
        for y = -check_radius, check_radius, grid_size do
            table.insert(offsets, {x, y})
        end
    end

    for _, offset in ipairs(offsets) do
        point:set(
            player_pos:x() + offset[1],
            player_pos:y() + offset[2],
            player_pos:z()
        )
        point = set_height(point)
        local grid_key = get_grid_key(point)
        if is_walkeable(point) and explored_areas[grid_key] and not near_wall(point) then
            table.insert(explored_points, vec3:new(point:x(), point:y(), point:z()))
            if #explored_points >= max_points then
                break
            end
        end
    end

    if #explored_points == 0 then   
        return nil
    end

    return explored_points[math.random(#explored_points)]
end

function vec3.__add(v1, v2)
    local v1x, v1y, v1z = v1:x(), v1:y(), v1:z()
    local v2x, v2y, v2z = v2:x(), v2:y(), v2:z()
    return vec3:new(v1x + v2x, v1y + v2y, v1z + v2z)
end

local function is_in_last_targets(point)
    local dist_func = calculate_distance
    local max_distance = grid_size * 2
    
    for _, target in ipairs(last_explored_targets) do
        if dist_func(point, target) < max_distance then
            return true
        end
    end
    
    return false
end

local last_explored_targets = {}
local current_index = 0

-- Vorallokieren des Arrays
for i = 1, max_last_targets do
    last_explored_targets[i] = nil
end

local function add_to_last_targets(point)
    current_index = (current_index % max_last_targets) + 1
    last_explored_targets[current_index] = point
end

local function find_nearby_unexplored_point(center, radius)
    local check_radius = max_target_distance
    local player_pos = get_player_position()
    local is_walkeable = utility.is_point_walkeable
    local is_explored = is_point_in_explored_area
    local set_height = set_height_of_valid_position
    local step = grid_size * 2  -- Größerer Schritt für schnellere Suche

    local function check_point(x, y)
        local point = vec3:new(center:x() + x, center:y() + y, center:z())
        point = set_height(point)
        return is_walkeable(point) and not is_explored(point) and point or nil
    end

    -- Spiralförmige Suche
    local x, y = 0, 0
    local dx, dy = 1, 0
    for i = 1, math.floor((check_radius * 2 / step)^2) do
        local point = check_point(x * step, y * step)
        if point then return point end

        if x == y or (x < 0 and x == -y) or (x > 0 and x == 1-y) then
            dx, dy = -dy, dx
        end
        x, y = x + dx, y + dy
    end

    return nil
end

local function find_unstuck_target()
    console.print("Finding unstuck target.")
    local player_pos = get_player_position()
    local is_walkeable = utility.is_point_walkeable
    local set_height = set_height_of_valid_position
    local step = grid_size

    local function check_point(x, y)
        local point = vec3:new(player_pos:x() + x, player_pos:y() + y, player_pos:z())
        point = set_height(point)
        local distance = calculate_distance(player_pos, point)
        return is_walkeable(point) and distance >= 2 and distance <= unstuck_target_distance and point or nil
    end

    -- Spiralförmige Suche
    local x, y = 0, 0
    local dx, dy = 1, 0
    for i = 1, math.floor((unstuck_target_distance * 2 / step)^2) do
        local point = check_point(x * step, y * step)
        if point then
            return point  -- Früher Abbruch bei erstem gültigen Punkt
        end

        if x == y or (x < 0 and x == -y) or (x > 0 and x == 1-y) then
            dx, dy = -dy, dx
        end
        x, y = x + dx, y + dy
    end

    return nil
end

explorer.find_unstuck_target = find_unstuck_target

-- A* pathfinding functions
local function heuristic(a, b)
    return (a:x() - b:x())^2 + (a:y() - b:y())^2 + (a:z() - b:z())^2
end

local directions = {
    { x = 1, y = 0 }, { x = -1, y = 0 }, { x = 0, y = 1 }, { x = 0, y = -1 },
    { x = 1, y = 1 }, { x = 1, y = -1 }, { x = -1, y = 1 }, { x = -1, y = -1 }
}

local function get_neighbors(point)
    local neighbors = {}
    local px, py, pz = point:x(), point:y(), point:z()
    
    for _, dir in ipairs(directions) do
        local nx, ny = px + dir.x * grid_size, py + dir.y * grid_size
        local neighbor = vec3:new(nx, ny, pz)
        neighbor = set_height_of_valid_position(neighbor)
        
        if utility.is_point_walkeable(neighbor) and 
           (not last_movement_direction or
            dir.x ~= -last_movement_direction.x or 
            dir.y ~= -last_movement_direction.y) then
            table.insert(neighbors, neighbor)
        end
    end

    if #neighbors == 0 and last_movement_direction then
        local bx = px - last_movement_direction.x * grid_size
        local by = py - last_movement_direction.y * grid_size
        local back_direction = set_height_of_valid_position(vec3:new(bx, by, pz))
        if utility.is_point_walkeable(back_direction) then
            table.insert(neighbors, back_direction)
        end
    end

    return neighbors
end

local function reconstruct_path(came_from, current)
    local path = { current }
    while came_from[get_grid_key(current)] do
        current = came_from[get_grid_key(current)]
        table.insert(path, 1, current)
    end

    local filtered_path = { path[1] }
    local angle_threshold = math.cos(math.rad(settings.path_angle))

    for i = 2, #path - 1 do
        local prev, curr, next = path[i-1], path[i], path[i+1]
        local dx1, dy1 = curr:x() - prev:x(), curr:y() - prev:y()
        local dx2, dy2 = next:x() - curr:x(), next:y() - curr:y()
        
        local dot_product = dx1 * dx2 + dy1 * dy2
        local magnitude = math.sqrt((dx1^2 + dy1^2) * (dx2^2 + dy2^2))
        
        if dot_product / magnitude < angle_threshold then
            table.insert(filtered_path, curr)
        end
    end
    table.insert(filtered_path, path[#path])

    return filtered_path
end

local function a_star(start, goal)
    local closed_set = {}
    local came_from = {}
    local g_score = { [get_grid_key(start)] = 0 }
    local f_score = { [get_grid_key(start)] = heuristic(start, goal) }
    local open_set = MinHeap.new(function(a, b)
        return (f_score[get_grid_key(a)] or math.huge) < (f_score[get_grid_key(b)] or math.huge)
    end)
    open_set:push(start)

    for iterations = 1, 6666 do
        if open_set:empty() then break end

        local current = open_set:pop()
        if calculate_distance(current, goal) < grid_size then
            max_target_distance = target_distance_states[1]
            target_distance_index = 1
            return reconstruct_path(came_from, current)
        end

        closed_set[get_grid_key(current)] = true

        for _, neighbor in ipairs(get_neighbors(current)) do
            local neighbor_key = get_grid_key(neighbor)
            if not closed_set[neighbor_key] then
                local tentative_g_score = g_score[get_grid_key(current)] + calculate_distance(current, neighbor)

                if not g_score[neighbor_key] or tentative_g_score < g_score[neighbor_key] then
                    came_from[neighbor_key] = current
                    g_score[neighbor_key] = tentative_g_score
                    f_score[neighbor_key] = g_score[neighbor_key] + heuristic(neighbor, goal)

                    if not open_set:contains(neighbor) then
                        open_set:push(neighbor)
                    end
                end
            end
        end
    end

    if target_distance_index < #target_distance_states then
        target_distance_index = target_distance_index + 1
        max_target_distance = target_distance_states[target_distance_index]
        console.print("No path found. Reducing max target distance to " .. max_target_distance)
    else
        console.print("No path found even after reducing max target distance.")
    end

    return nil
end

local last_a_star_call = 0.0

local calculate_distance = calculate_distance
local get_player_position = get_player_position
local get_time_since_inject = get_time_since_inject
local pathfinder_force_move = pathfinder.force_move

local empty_table = {}
local function reset_path()
    current_path = empty_table
    path_index = 1
end

local function move_to_target()
    if explorer.is_task_running then return end
    if not target_position then return end

    local player_pos = get_player_position()
    if calculate_distance(player_pos, target_position) > 500 then
        reset_path()
        return
    end

    local current_core_time = get_time_since_inject()
    local time_since_last_call = current_core_time - last_a_star_call
    local should_recalculate = not current_path or #current_path == 0 or path_index > #current_path or time_since_last_call >= 0.50

    if should_recalculate then
        path_index = 1
        current_path = a_star(player_pos, target_position)
        last_a_star_call = current_core_time

        if not current_path then
            console.print("No path found to target. Finding new target.")
            return
        end
    end

    local next_point = current_path[path_index]
    if next_point and not next_point:is_zero() then
        pathfinder_force_move(next_point)

        if calculate_distance(player_pos, next_point) < grid_size then
            last_movement_direction = {
                x = next_point:x() - player_pos:x(),
                y = next_point:y() - player_pos:y()
            }
            path_index = path_index + 1
        end
    end

    if calculate_distance(player_pos, target_position) < 2 then
        target_position = nil
        reset_path()
    end
end


local get_player_position = get_player_position
local os_time = os.time
local calculate_distance = calculate_distance
local STUCK_THRESHOLD = 10 -- Anpassen nach Bedarf

local last_position, last_move_time

local function check_if_stuck()
    local current_pos = get_player_position()
    local current_time = os_time()

    if not last_position then
        last_position = current_pos
        last_move_time = current_time
        return false
    end

    if calculate_distance(current_pos, last_position) >= 0.1 then
        last_move_time = current_time
        last_position = current_pos
        return false
    end

    if current_time - last_move_time > STUCK_THRESHOLD then
        return true
    end

    last_position = current_pos
    return false
end

explorer.check_if_stuck = check_if_stuck


local settings_enabled = settings.enabled
local world_get_current_world = world.get_current_world
local get_time_since_inject = get_time_since_inject
local utils_player_on_quest = utils.player_on_quest
local check_walkable_area = check_walkable_area
local check_if_stuck = check_if_stuck
local find_target = find_target
local set_height_of_valid_position = set_height_of_valid_position
local get_local_player = get_local_player
local revive_at_checkpoint = revive_at_checkpoint

function explorer:set_custom_target(target)
    target_position = target
end

function explorer:move_to_target()
    move_to_target()
end

local function check_world()
    local world = world_get_current_world()
    return world and not (world:get_name():match("Sanctuary") or world:get_name():match("Limbo"))
end

local function handle_stuck()
    console.print("Character was stuck. Finding new target and attempting revive")
    target_position = set_height_of_valid_position(find_target(false))
    last_move_time = os.time()
    current_path = {}
    path_index = 1

    local local_player = get_local_player()
    if local_player and local_player:is_dead() then
        revive_at_checkpoint()
    end
end

local last_call_time = 0.0
local is_player_on_quest = false
on_update(function()
    if not settings_enabled or explorer.is_task_running or not check_world() then
        return
    end

    local current_core_time = get_time_since_inject()
    if current_core_time - last_call_time <= 0.45 then
        return
    end


    check_walkable_area()
    if check_if_stuck() then
        handle_stuck()
    end
end)

local function render_target()
    if target_position then
        if target_position.x then
            graphics.text_3d("TARGET_1", target_position, 20, color_red(255))
        elseif target_position:get_position() then
            graphics.text_3d("TARGET_2", target_position:get_position(), 20, color_orange(255))
        end
    end
end

local function render_path()
    if current_path then
        for i, point in ipairs(current_path) do
            local color = (i == path_index) and color_green(255) or color_yellow(255)
            graphics.text_3d("PATH_1", point, 15, color)
        end
    end
end

on_render(function()
    if not settings_enabled then
        return
    end

    render_target()
    render_path()
    graphics.text_2d("Mode: " .. exploration_mode, vec2:new(10, 10), 20, color_white(255))
end)

return explorer
