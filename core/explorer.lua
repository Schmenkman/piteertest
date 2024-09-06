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
    local heap = self.heap
    heap[#heap + 1] = value
    self.map[value] = #heap
    self:siftUp(#heap)
end

function MinHeap:pop()
    local heap = self.heap
    local root = heap[1]
    local lastItem = heap[#heap]
    heap[1] = lastItem
    heap[#heap] = nil
    self.map[root] = nil
    self.map[lastItem] = 1
    if #heap > 1 then
        self:siftDown(1)
    end
    return root
end

function MinHeap:peek()
    return self.heap[1]
end

function MinHeap:empty()
    return #self.heap == 0
end

function MinHeap:siftUp(index)
    local heap, compare = self.heap, self.compare
    local value = heap[index]
    while index > 1 do
        local parentIndex = math.floor(index / 2)
        local parent = heap[parentIndex]
        if not compare(value, parent) then break end
        heap[index] = parent
        self.map[parent] = index
        index = parentIndex
    end
    heap[index] = value
    self.map[value] = index
end

function MinHeap:siftDown(index)
    local heap, size, compare = self.heap, #self.heap, self.compare
    local value = heap[index]
    while true do
        local smallestIndex = index
        local left, right = 2 * index, 2 * index + 1
        if left <= size and compare(heap[left], heap[smallestIndex]) then
            smallestIndex = left
        end
        if right <= size and compare(heap[right], heap[smallestIndex]) then
            smallestIndex = right
        end
        if smallestIndex == index then break end
        heap[index] = heap[smallestIndex]
        self.map[heap[smallestIndex]] = index
        index = smallestIndex
    end
    heap[index] = value
    self.map[value] = index
end

function MinHeap:contains(value)
    return self.map[value] ~= nil
end

local utils = require "core.utils"
local enums = require "data.enums"
local settings = require "core.settings"
local tracker = require "core.tracker"
-- Konfigurationsdatei
local config = {
    grid_size = 1,
    exploration_radius = 7,
    explored_buffer = 2,
    max_target_distance = 200,
    target_distance_states = {10, 20, 40, 80, 120, 240},
    unstuck_target_distance = 15,
    stuck_threshold = 4,
    max_last_targets = 200,
    check_walkable_area_interval = 5,  -- Sekunden
    stuck_check_interval = 2.0,
    update_interval = 0.000000001,
}

-- Modulare Struktur
local Explorer = {}
Explorer.__index = Explorer

function Explorer.new()
    local self = setmetatable({}, Explorer)
    self.enabled = false
    self.is_task_running = false
    self.start_location_reached = false
    self.unexplored_areas = {}
    self.explored_areas = {}
    self.target_position = nil
    self.current_path = {}
    self.path_index = 1
    self.exploration_mode = "unexplored"
    self.exploration_direction = { x = 10, y = 0 }
    self.last_movement_direction = nil
    self.last_a_star_call = 0
    self.last_call_time = 0
    self.last_position = nil
    self.last_move_time = 0
    self.last_explored_targets = {}
    self.last_stuck_check_time = 0
    self.target_distance_index = 1
    self.last_check_walkable_area_time = 0
    self:init_last_explored_targets()
    return self
end



-- Cached values
local get_time_since_inject = get_time_since_inject
local console_print = console.print
local reset_all_dungeons = reset_all_dungeons
local get_player_position = get_player_position

function Explorer:safe_get_player_position()
    local pos = get_player_position()
    if not pos then
        error("Failed to get player position")
    end
    return pos
end


-- Function to check and print pit start time and time spent in pit
function Explorer:check_pit_time()
    if tracker.pit_start_time > 0 then
        -- Only calculate time_spent_in_pit if needed
        -- local time_spent_in_pit = get_time_since_inject() - tracker.pit_start_time
    end
end

function Explorer:check_and_reset_dungeons()
    if tracker.pit_start_time > 0 then
        local time_spent_in_pit = get_time_since_inject() - tracker.pit_start_time
        if time_spent_in_pit > settings.reset_time then
            console_print("Time spent in pit is greater than " .. settings.reset_time .. " seconds. Resetting all dungeons.")
            reset_all_dungeons()
        end
    end
end







function Explorer:clear_path_and_target()
    self.target_position = nil
    self.current_path = {}
    self.path_index = 1
end

function Explorer:calculate_distance(point1, point2)
    --console.print("Calculating distance between points.")
    if not point2.x and point2 then
        return point1:dist_to_ignore_z(point2:get_position())
    end
    return point1:dist_to_ignore_z(point2)
end




-- Cached functions
local math_floor, math_min, math_max = math.floor, math.min, math.max






function Explorer:get_grid_key(point)
    return math_floor(point:x() / config.grid_size) .. "," ..
           math_floor(point:y() / config.grid_size) .. "," ..
           math_floor(point:z() / config.grid_size)
end

local explored_area_bounds = {
    min_x = math.huge, max_x = -math.huge,
    min_y = math.huge, max_y = -math.huge,
    min_z = math.huge, max_z = -math.huge
}

function Explorer:update_explored_area_bounds(point, radius)
    if not point or not radius then
        console.print("Error: Invalid point or radius in update_explored_area_bounds")
        return
    end

    local x, y, z = point:x(), point:y(), point:z()
    if not x or not y or not z then
        console.print("Error: Invalid point coordinates in update_explored_area_bounds")
        return
    end

    explored_area_bounds.min_x = math_min(explored_area_bounds.min_x or x, x - radius)
    explored_area_bounds.max_x = math_max(explored_area_bounds.max_x or x, x + radius)
    explored_area_bounds.min_y = math_min(explored_area_bounds.min_y or y, y - radius)
    explored_area_bounds.max_y = math_max(explored_area_bounds.max_y or y, y + radius)
    explored_area_bounds.min_z = math_min(explored_area_bounds.min_z or z, z - radius)
    explored_area_bounds.max_z = math_max(explored_area_bounds.max_z or z, z + radius)
end

function Explorer:is_point_in_explored_area(point)
    local x, y, z = point:x(), point:y(), point:z()
    return x >= explored_area_bounds.min_x and x <= explored_area_bounds.max_x and
           y >= explored_area_bounds.min_y and y <= explored_area_bounds.max_y and
           z >= explored_area_bounds.min_z and z <= explored_area_bounds.max_z
end





-- Optimierte check_walkable_area Funktion
function Explorer:check_walkable_area()
    local current_time = os.time()
    if current_time - self.last_check_walkable_area_time < config.check_walkable_area_interval then
        return
    end
    self.last_check_walkable_area_time = current_time

    local player_pos = get_player_position()
    self:mark_area_as_explored(player_pos, config.exploration_radius)

    local check_radius = 15
    local px, py, pz = player_pos:x(), player_pos:y(), player_pos:z()

    for x = -check_radius, check_radius, config.grid_size do
        for y = -check_radius, check_radius, config.grid_size do
            local point = vec3:new(px + x, py + y, pz)
            point = utility.set_height_of_valid_position(point)

            if utility.is_point_walkeable(point) and not self:is_point_in_explored_area(point) then
                if #self.unexplored_areas < 1000 then  -- Begrenzung der unexplored_areas
                    table.insert(self.unexplored_areas, point)
                end
            end
        end
    end
end

function Explorer:mark_area_as_explored(center, radius)
    if not center or not radius then
        console_print("Error: Invalid center or radius in mark_area_as_explored")
        return
    end

    if type(center) ~= "table" or type(center.x) ~= "function" or type(center.y) ~= "function" or type(center.z) ~= "function" then
        console_print("Error: Invalid center object in mark_area_as_explored")
        return
    end

    if type(radius) ~= "number" or radius <= 0 then
        console_print("Error: Invalid radius in mark_area_as_explored")
        return
    end

    self:update_explored_area_bounds(center, radius)

    -- Überprüfen Sie, ob unexplored_areas initialisiert und nicht leer ist
    if self.unexplored_areas and #self.unexplored_areas > 0 then
        for i = #self.unexplored_areas, 1, -1 do
            local unexplored_area = self.unexplored_areas[i]
            if unexplored_area then
                if self:calculate_distance(center, unexplored_area) <= radius then
                    table.remove(self.unexplored_areas, i)
                end
            else
                console_print("Warning: Nil unexplored area found at index " .. i)
                table.remove(self.unexplored_areas, i)
            end
        end
    end
end

function Explorer:reset_exploration()
    explored_area_bounds = {
        min_x = math.huge,
        max_x = -math.huge,
        min_y = math.huge,
        max_y = -math.huge,
    }
    self.target_position = nil
    self.last_position = nil
    self.last_move_time = 0
    self.current_path = {}
    self.path_index = 1
    self.exploration_mode = "unexplored"
    self.last_movement_direction = nil

    -- Nur wenn wirklich nötig:
    -- console.print("Exploration reset. All areas marked as unexplored.")
end

local vec3_new = vec3.new



local directions = {
    { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
    { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 }
}

function Explorer:is_near_wall(point)
    local wall_check_distance = 2
    local px, py, pz = point:x(), point:y(), point:z()

    for i = 1, 8 do
        local dir = directions[i]
        local check_point = vec3_new(
            px + dir[1] * wall_check_distance,
            py + dir[2] * wall_check_distance,
            pz
        )
        check_point = utility.set_height_of_valid_position(check_point)
        if not utility.is_point_walkeable(check_point) then
            return true
        end
    end
    return false
end

function Explorer:find_central_unexplored_target()
    console.print("Finding central unexplored target.")
    local player_pos = get_player_position()
    local check_radius = config.max_target_distance
    local grid = {}
    local largest_cluster_key = nil
    local max_count = 0

    -- Erhöhte grid_size für gröbere Suche
    local search_grid_size = config.grid_size * 4

    -- Begrenzen der maximalen Anzahl zu überprüfender Punkte
    local max_points_to_check = 10000
    local points_checked = 0

    -- Caching für bereits überprüfte Bereiche
    local checked_areas = {}

    for x = -check_radius, check_radius, search_grid_size do
        for y = -check_radius, check_radius, search_grid_size do
            points_checked = points_checked + 1
            if points_checked > max_points_to_check then
                break
            end

            local point = vec3:new(
                player_pos:x() + x,
                player_pos:y() + y,
                player_pos:z()
            )

            local area_key = math.floor(x / (search_grid_size * 2)) .. "," .. math.floor(y / (search_grid_size * 2))
            if not checked_areas[area_key] then
                checked_areas[area_key] = true

                point = utility.set_height_of_valid_position(point)

                if utility.is_point_walkeable(point) and not self:is_point_in_explored_area(point) then
                    local grid_key = self:get_grid_key(point)
                    if not grid[grid_key] then
                        grid[grid_key] = { sum_x = 0, sum_y = 0, count = 0 }
                    end
                    local cell = grid[grid_key]
                    cell.sum_x = cell.sum_x + point:x()
                    cell.sum_y = cell.sum_y + point:y()
                    cell.count = cell.count + 1

                    if cell.count > max_count then
                        largest_cluster_key = grid_key
                        max_count = cell.count
                    end
                end
            end
        end
        if points_checked > max_points_to_check then
            break
        end
    end

    if not largest_cluster_key then
        return nil
    end

    -- Calculate the center of the largest cluster
    local largest_cluster = grid[largest_cluster_key]
    local center_x = largest_cluster.sum_x / largest_cluster.count
    local center_y = largest_cluster.sum_y / largest_cluster.count
    local center = vec3:new(center_x, center_y, player_pos:z())
    center = utility.set_height_of_valid_position(center)

    -- Find the closest point to the center
    local closest_point = nil
    local min_distance = math.huge
    for x = -search_grid_size, search_grid_size, config.grid_size do
        for y = -search_grid_size, search_grid_size, config.grid_size do
            local point = vec3:new(
                center:x() + x,
                center:y() + y,
                center:z()
            )
            point = utility.set_height_of_valid_position(point)
            if utility.is_point_walkeable(point) and not self:is_point_in_explored_area(point) then
                local distance = self:calculate_distance(point, center)
                if distance < min_distance then
                    closest_point = point
                    min_distance = distance
                end
            end
        end
    end

    if closest_point then
        self.target_position = closest_point
        console.print("Central unexplored target set.")
        return closest_point
    else
        console.print("No central unexplored target found.")
        return nil
    end
end

function Explorer:find_random_explored_target()
    console.print("Finding random explored target.")
    local player_pos = get_player_position()
    local check_radius = config.max_target_distance
    local explored_points = {}

    for x = -check_radius, check_radius, config.grid_size do
        for y = -check_radius, check_radius, config.grid_size do
            local point = vec3:new(
                player_pos:x() + x,
                player_pos:y() + y,
                player_pos:z()
            )
            point = utility.set_height_of_valid_position(point)
            local grid_key = self:get_grid_key(point)
            if utility.is_point_walkeable(point) and self.explored_areas[grid_key] and not self:is_near_wall(point) then
                table.insert(explored_points, point)
            end
        end
    end

    if #explored_points == 0 then   
        return nil
    end

    return explored_points[math.random(#explored_points)]
end

function vec3.__add(v1, v2)
    --console.print("Adding two vectors.")
    return vec3:new(v1:x() + v2:x(), v1:y() + v2:y(), v1:z() + v2:z())
end

function Explorer:is_in_last_targets(point)
    local threshold = config.grid_size * 2
    local threshold_squared = threshold * threshold

    for _, target in ipairs(self.last_explored_targets) do
        local dx = point:x() - target:x()
        local dy = point:y() - target:y()
        local dz = point:z() - target:z()
        
        if (dx * dx + dy * dy + dz * dz) < threshold_squared then
            return true
        end
    end
    return false
end



function Explorer:init_last_explored_targets()
    self.last_explored_targets = {}
    for i = 1, config.max_last_targets do
        self.last_explored_targets[i] = nil
    end
end

function Explorer:add_to_last_targets(point)
    self.current_index = ((self.current_index or 0) % config.max_last_targets) + 1
    self.last_explored_targets[self.current_index] = point
end


function Explorer:find_nearest_unexplored_area(player_pos)
    local nearest_point = nil
    local min_distance = math.huge

    for i, point in ipairs(self.unexplored_areas) do
        local distance = self:calculate_distance(player_pos, point)
        if distance < min_distance then
            min_distance = distance
            nearest_point = point
        end
    end

    if nearest_point then
        -- Entfernen Sie den Punkt aus der Tabelle, da er jetzt als Ziel verwendet wird
        for i, point in ipairs(self.unexplored_areas) do
            if point == nearest_point then
                table.remove(self.unexplored_areas, i)
                break
            end
        end
    end

    return nearest_point
end

function Explorer:find_nearby_unexplored_point(center, radius)
    local check_radius = config.max_target_distance
    local player_pos = get_player_position()
    local step = config.grid_size * 2  -- Größere Schritte
    local points = {}

    for x = -check_radius, check_radius, step do
        for y = -check_radius, check_radius, step do
            table.insert(points, vec3:new(center:x() + x, center:y() + y, center:z()))
        end
    end

    -- Zufällige Reihenfolge der Punkte
    for i = #points, 2, -1 do
        local j = math.random(i)
        points[i], points[j] = points[j], points[i]
    end

    for _, point in ipairs(points) do
        point = utility.set_height_of_valid_position(point)
        if utility.is_point_walkeable(point) and not self:is_point_in_explored_area(point) then
            return point
        end
    end

    return nil
end

function Explorer:find_explored_direction_target()
    console.print("Finding explored direction target.")
    local player_pos = get_player_position()
    local max_attempts = 500
    local best_target, best_distance = nil, math.huge
    local direction_length = config.max_target_distance * 0.4

    for _ = 1, max_attempts do
        local target_point = vec3:new(
            player_pos:x() + self.exploration_direction.x * direction_length,
            player_pos:y() + self.exploration_direction.y * direction_length,
            player_pos:z()
        )
        target_point = utility.set_height_of_valid_position(target_point)

        if utility.is_point_walkeable(target_point) and self:is_point_in_explored_area(target_point) then
            local distance = self:calculate_distance(player_pos, target_point)
            if distance < best_distance and not self:is_in_last_targets(target_point) then
                best_target, best_distance = target_point, distance

                local nearby_unexplored_point = self:find_nearby_unexplored_point(target_point, config.exploration_radius)
                if nearby_unexplored_point then
                    console.print("Nearby unexplored point found. Switching to unexplored mode.")
                    self.exploration_mode = "unexplored"
                    return nearby_unexplored_point
                end
            end
        end

        -- Rotate the direction vector
        local dx, dy = self.exploration_direction.x, self.exploration_direction.y
        self.exploration_direction.x = dx * 0.9659 - dy * 0.2588  -- cos(15°), sin(15°)
        self.exploration_direction.y = dx * 0.2588 + dy * 0.9659
    end

    if best_target then
        self:add_to_last_targets(best_target)
        console.print("Found best target after " .. max_attempts .. " attempts.")
        return best_target
    else
        console.print("Could not find a valid explored target after " .. max_attempts .. " attempts.")
        return nil
    end
end



function Explorer:find_unstuck_target()
    console_print("Finding unstuck target.")
    local player_pos = get_player_position()
    
    local step = config.grid_size
    local min_distance = 2
    local max_distance_sq = config.unstuck_target_distance * config.unstuck_target_distance

    local function check_point(x, y)
        local dx, dy = x * step, y * step
        local dist_sq = dx * dx + dy * dy
        if dist_sq >= min_distance * min_distance and dist_sq <= max_distance_sq then
            local point = vec3:new(player_pos:x() + dx, player_pos:y() + dy, player_pos:z())
            point = utility.set_height_of_valid_position(point)
            return utility.is_point_walkeable(point) and point or nil
        end
        return nil
    end

    -- Spiralförmige Suche
    local x, y = 0, 0
    local dx, dy = 1, 0
    local max_iterations = math.floor((config.unstuck_target_distance * 2 / step)^2)
    
    for _ = 1, max_iterations do
        local point = check_point(x, y)
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

function Explorer:reset_unexplored_areas()
    self.unexplored_areas = {}
end

function Explorer:find_target(include_explored)
    if self.is_task_running then
        return nil
    end
    console.print("Finding target.")
    self.last_movement_direction = nil -- Reset the last movement direction

    local player_pos = get_player_position()
    local target = self:find_nearest_unexplored_area(player_pos)

    if not target then
        if self.exploration_mode == "unexplored" then
            target = self:find_central_unexplored_target()
            if not target then
                self.exploration_mode = "explored"
                console.print("No unexplored areas found. Switching to explored mode.")
                self.last_explored_targets = {} -- Reset last targets when switching modes
            end
        end

        if self.exploration_mode == "explored" or not target then
            target = self:find_explored_direction_target()
            if not target then
                console.print("No valid explored targets found. Resetting exploration.")
                self:reset_exploration()
                self.exploration_mode = "unexplored"
                target = self:find_central_unexplored_target()
            end
        end
    else
        console.print("Found nearest unexplored area from stored points.")
    end

    if target then
        self.target_position = target
    end

    return target
end

-- A* pathfinding functions
function Explorer:heuristic(a, b)
    return self:calculate_distance(a, b)
end

function Explorer:get_neighbors(point)
    local neighbors = {}
    local directions = {
        { x = 1, y = 0 }, { x = -1, y = 0 }, { x = 0, y = 1 }, { x = 0, y = -1 },
        { x = 1, y = 1 }, { x = 1, y = -1 }, { x = -1, y = 1 }, { x = -1, y = -1 }
    }
    
    for _, dir in ipairs(directions) do
        local nx, ny = point:x() + dir.x * config.grid_size, point:y() + dir.y * config.grid_size
        local neighbor = vec3:new(nx, ny, point:z())
        neighbor = utility.set_height_of_valid_position(neighbor)
        
        if utility.is_point_walkeable(neighbor) and 
           (not self.last_movement_direction or 
            dir.x ~= -self.last_movement_direction.x or 
            dir.y ~= -self.last_movement_direction.y) then
            neighbors[#neighbors + 1] = neighbor
        end
    end

    if #neighbors == 0 and self.last_movement_direction then
        local bx, by = point:x() - self.last_movement_direction.x * config.grid_size, 
                       point:y() - self.last_movement_direction.y * config.grid_size
        local back_direction = utility.set_height_of_valid_position(vec3:new(bx, by, point:z()))
        if utility.is_point_walkeable(back_direction) then
            neighbors[1] = back_direction
        end
    end

    return neighbors
end

function Explorer:reconstruct_path(came_from, current)
    local path, filtered_path = {current}, {}
    local angle_threshold = math.rad(settings.path_angle)
    
    while came_from[self:get_grid_key(current)] do
        current = came_from[self:get_grid_key(current)]
        path[#path + 1] = current
    end

    for i = #path, 2, -1 do
        local prev, curr, next = path[i], path[i-1], path[i-2]
        filtered_path[#filtered_path + 1] = curr

        if next then
            local dx1, dy1 = curr:x() - prev:x(), curr:y() - prev:y()
            local dx2, dy2 = next:x() - curr:x(), next:y() - curr:y()
            local dot_product = dx1 * dx2 + dy1 * dy2
            local magnitude1 = math.sqrt(dx1^2 + dy1^2)
            local magnitude2 = math.sqrt(dx2^2 + dy2^2)
            
            if math.acos(dot_product / (magnitude1 * magnitude2)) <= angle_threshold then
                table.remove(filtered_path)
            end
        end
    end
    
    filtered_path[#filtered_path + 1] = path[1]
    return filtered_path
end

function Explorer:a_star(start, goal)
    local closed_set = {}
    local came_from = {}
    local g_score = {[self:get_grid_key(start)] = 0}
    local f_score = {[self:get_grid_key(start)] = self:heuristic(start, goal)}
    local open_set = MinHeap.new(function(a, b)
        return f_score[self:get_grid_key(a)] < f_score[self:get_grid_key(b)]
    end)
    open_set:push(start)

    for iterations = 1, tonumber(6666) do
        if open_set:empty() then break end

        local current = open_set:pop()
        local current_key = self:get_grid_key(current)
        
        if self:calculate_distance(current, goal) < config.grid_size then
            config.max_target_distance = config.target_distance_states[1]
            self.target_distance_index = 1
            return self:reconstruct_path(came_from, current)
        end

        closed_set[current_key] = true

        for _, neighbor in ipairs(self:get_neighbors(current)) do
            local neighbor_key = self:get_grid_key(neighbor)
            if not closed_set[neighbor_key] then
                local tentative_g_score = g_score[current_key] + self:calculate_distance(current, neighbor)

                if not g_score[neighbor_key] or tentative_g_score < g_score[neighbor_key] then
                    came_from[neighbor_key] = current
                    g_score[neighbor_key] = tentative_g_score
                    f_score[neighbor_key] = tentative_g_score + self:heuristic(neighbor, goal)

                    if not open_set:contains(neighbor) then
                        open_set:push(neighbor)
                    end
                end
            end
        end
    end

    if self.target_distance_index < #config.target_distance_states then
        self.target_distance_index = self.target_distance_index + 1
        config.max_target_distance = config.target_distance_states[self.target_distance_index]
        console.print("No path found. increasing max target distance to " .. config.max_target_distance)
    else
        console.print("No path found even after increasing max target distance.Resetting exploration!")
        self:reset_exploration()
        
    end

    return nil
end





function Explorer:move_to_target()
    if self.is_task_running then
        return
    end
    
    local player_pos = get_player_position()
    
    if not self.target_position then
        self.target_position = self:find_target(false)
        return
    end

    local dist_to_target = self:calculate_distance(player_pos, self.target_position)

    if dist_to_target > 500 then
        self.target_position = self:find_target(false)
        self.current_path = {}
        self.path_index = 1
        return
    end

    local current_core_time = get_time_since_inject()
    local time_since_last_call = current_core_time - self.last_a_star_call
    
    if not self.current_path or #self.current_path == 0 or self.path_index > #self.current_path or time_since_last_call >= 0.5 then
        self.path_index = 1
        self.current_path = self:a_star(player_pos, self.target_position)
        self.last_a_star_call = current_core_time

        if not self.current_path then
            console.print("No path found to target. Finding new target.")
            self.target_position = self:find_target(false)
            return
        end
    end

    local next_point = self.current_path[self.path_index]
    if next_point and not next_point:is_zero() then
        pathfinder.request_move(next_point)

        if self:calculate_distance(player_pos, next_point) < config.grid_size then
            self.last_movement_direction = {
                x = next_point:x() - player_pos:x(),
                y = next_point:y() - player_pos:y()
            }
            self.path_index = self.path_index + 1
        end
    end

    if dist_to_target < 2 then
        local player_pos = get_player_position()
        if player_pos then
            self:mark_area_as_explored(player_pos, config.exploration_radius)
        else
            console.print("Error: Invalid player position in move_to_target")
        end
        self.target_position = nil
        self.current_path = {}
        self.path_index = 1

        if self.exploration_mode == "explored" then
            local nearby_unexplored = self:find_nearby_unexplored_point(player_pos, config.exploration_radius)
            if nearby_unexplored then
                self.exploration_mode = "unexplored"
                self.target_position = nearby_unexplored
                console.print("Found nearby unexplored area. Switching back to unexplored mode.")
                self.last_explored_targets = {}
                self.current_path = nil
                self.path_index = 1
            else
                local unexplored_target = self:find_central_unexplored_target()
                if unexplored_target then
                    self.exploration_mode = "unexplored"
                    self.target_position = unexplored_target
                    console.print("Found new unexplored area. Switching back to unexplored mode.")
                    self.last_explored_targets = {}
                end
            end
        end
    end
end


local os_time = os.time
local STUCK_THRESHOLD = 5 -- Angenommen, dass stuck_threshold 5 Sekunden ist

-- Verbesserte Steckenbleib-Erkennung
function Explorer:check_if_stuck()
    local current_pos = get_player_position()
    local current_time = os.time()

    if not self.last_position then
        self.last_position = current_pos
        self.last_move_time = current_time
        return false
    end

    if self:calculate_distance(current_pos, self.last_position) < 0.1 then
        if current_time - self.last_move_time > config.stuck_threshold then
            return true
        end
    else
        self.last_move_time = current_time
    end

    self.last_position = current_pos
    return false
end



function Explorer:set_custom_target(target)
    console.print("Setting custom target.")
    self.target_position = target
    self.current_path = {}
    self.path_index = 1
end





local excluded_worlds = {Sanctuary = true, Limbo = true}
local is_player_on_quest = utils.player_on_quest(enums.quests.pit_ongoing)
function Explorer:update()
    if not settings.enabled or self.is_task_running then
        return
    end
    local world = world.get_current_world()
    if world then
        local world_name = world:get_name()
        if world_name:match("Sanctuary") or world_name:match("Limbo") then
            return
        end
    end

    local current_core_time = get_time_since_inject()
    if current_core_time - self.last_call_time > config.update_interval then
        self.last_call_time = current_core_time

        

        
        if not is_player_on_quest then
            return
        end

        self:check_walkable_area()

        if current_core_time - self.last_stuck_check_time > config.stuck_check_interval then
            self.last_stuck_check_time = current_core_time
            if self:check_if_stuck() then
                console.print("Character was stuck. Finding new target and attempting revive")
                self.target_position = self:find_target(true)
                self.target_position = utility.set_height_of_valid_position(self.target_position)
                self.last_move_time = os.time()
                self.current_path = {}
                self.path_index = 1

                local local_player = get_local_player()
                if local_player and local_player:is_dead() then
                    revive_at_checkpoint()
                end
            end
        end
        self:check_walkable_area()
        self:move_to_target()
        self:check_pit_time()
        self:check_and_reset_dungeons()
    end
end

-- Initialisierung
local explorer = Explorer.new()

-- Hauptupdate-Hook
on_update(function()
    explorer:update()
end)

return explorer