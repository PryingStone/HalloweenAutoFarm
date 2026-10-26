-- Halloween Auto-Farm for YOUR Roblox Studio experience
-- Place this LocalScript in StarterPlayer > StarterPlayerScripts.
--
-- Uses existing prompts in workspace.Map["HALLOWEEN-MainMap"].
-- This client script handles navigation and candy-visual collection.
-- For a genuinely fully automatic farm, the existing game must expose a
-- server-validated way to invoke the door interaction. Standard client APIs
-- cannot programmatically force-trigger arbitrary ProximityPrompts.
--
-- Set DOOR_INTERACT_REMOTE to the name of YOUR game's existing RemoteEvent
-- if your server already uses one for door interactions. Do not create a
-- client-trusted reward remote; the server must validate distance, door state,
-- night state, and award the reward itself.
local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer
-- CONFIG
local MAP_ROOT = Workspace:WaitForChild("Map"):WaitForChild("HALLOWEEN-MainMap")
local NIGHT_START, NIGHT_END = 18, 6
local DOOR_STOP_DISTANCE = 7
local CANDY_STOP_DISTANCE = 0.8
local HOUSE_TELEPORT_OFFSET = 5
local TELEPORT_SETTLE_DELAY = 1.0
local CANDY_SPAWN_WAIT = 0.9
local DOOR_TIMEOUT = 20
local CANDY_TIMEOUT = 15
local CANDY_SWEEP_SECONDS = 12
local CANDY_RETRY_WAIT = 0.75
local CANDY_RADIUS = 24
local POLL = 0.35

-- Daytime wandering: choose nearby destinations repeatedly so the character
-- naturally explores the map without teleporting.
local WANDER_MIN_DISTANCE = 35
local WANDER_MAX_DISTANCE = 90
local WANDER_PAUSE_MIN = 1.0
local WANDER_PAUSE_MAX = 3.0
local WANDER_MOVE_TIMEOUT = 8
-- Optional: assign the exact existing server RemoteEvent used by your own game.
-- Leave nil to use the normal existing ProximityPrompt and wait for the player.
local DOOR_INTERACT_REMOTE_NAME = nil -- e.g. "KnockDoor"
local running = true
local busy = false
local usedPrompts = {}
local usedHouses = {} -- instance tracking
local usedHouseKeys = {} -- stable house-path tracking
local candyHandled = {}
local isNightLastTick = false
local statusLabel
local logLabel
local targetText = "Starting"
if not player then
    warn("[HalloweenFarm] Must run as a LocalScript.")
    return
end
local playerGui = player:WaitForChild("PlayerGui")
local old = playerGui:FindFirstChild("HalloweenAutoFarm")
if old then old:Destroy() end
-- Status GUI
local gui = Instance.new("ScreenGui")
gui.Name = "HalloweenAutoFarm"
gui.ResetOnSpawn = false
gui.DisplayOrder = 1000
gui.Parent = playerGui
local panel = Instance.new("Frame")
panel.Size = UDim2.fromOffset(380, 180)
panel.Position = UDim2.new(0, 18, 0.33, 0)
panel.BackgroundColor3 = Color3.fromRGB(29, 25, 35)
panel.BorderSizePixel = 0
panel.Parent = gui
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 9)
local heading = Instance.new("TextLabel")
heading.Size = UDim2.new(1, -20, 0, 28)
heading.Position = UDim2.fromOffset(10, 7)
heading.BackgroundTransparency = 1
heading.Font = Enum.Font.GothamBold
heading.TextSize = 15
heading.TextXAlignment = Enum.TextXAlignment.Left
heading.TextColor3 = Color3.fromRGB(255, 190, 90)
heading.Text = "HALLOWEEN AUTO-FARM"
heading.Parent = panel
statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, -20, 0, 95)
statusLabel.Position = UDim2.fromOffset(10, 38)
statusLabel.BackgroundColor3 = Color3.fromRGB(42, 37, 49)
statusLabel.BorderSizePixel = 0
statusLabel.Font = Enum.Font.Code
statusLabel.TextSize = 12
statusLabel.TextColor3 = Color3.fromRGB(238, 235, 242)
statusLabel.TextWrapped = true
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextYAlignment = Enum.TextYAlignment.Top
statusLabel.Text = "Initializing..."
statusLabel.Parent = panel
Instance.new("UICorner", statusLabel).CornerRadius = UDim.new(0, 5)
local stop = Instance.new("TextButton")
stop.Size = UDim2.fromOffset(105, 28)
stop.Position = UDim2.new(0, 10, 1, -37)
stop.BackgroundColor3 = Color3.fromRGB(126, 49, 57)
stop.BorderSizePixel = 0
stop.Font = Enum.Font.GothamBold
stop.TextSize = 12
stop.TextColor3 = Color3.new(1, 1, 1)
stop.Text = "STOP"
stop.Parent = panel
Instance.new("UICorner", stop).CornerRadius = UDim.new(0, 5)
local function log(...)
    print("[HalloweenFarm]", ...)
end
local function characterParts()
    local char = player.Character
    if not char then return nil end
    local hum = char:FindFirstChildOfClass("Humanoid")
    local root = char:FindFirstChild("HumanoidRootPart")
    if hum and root then return char, hum, root end
    return nil
end
local function isNight()
    local t = Lighting.ClockTime
    return t >= NIGHT_START or t < NIGHT_END
end
local function positionOf(obj)
    if not obj then return nil end
    if obj:IsA("BasePart") then return obj.Position end
    if obj:IsA("Attachment") then return obj.WorldPosition end
    if obj:IsA("Model") then
        local ok, pivot = pcall(function() return obj:GetPivot() end)
        if ok then return pivot.Position end
    end
    local part = obj:FindFirstChildWhichIsA("BasePart", true)
    return part and part.Position or nil
end
local function promptPart(prompt)
    local parent = prompt.Parent
    if parent and parent:IsA("Attachment") then return parent.Parent end
    return parent
end
local function allPrompts()
    local found = {}
    for _, inst in ipairs(MAP_ROOT:GetDescendants()) do
        if inst:IsA("ProximityPrompt") and inst.Name == "ProximityPrompt"
            and inst.Enabled and positionOf(promptPart(inst)) then
            table.insert(found, inst)
        end
    end
    return found
end
local function updateStatus(extra)
    local _, _, root = characterParts()
    local t = Lighting.ClockTime
    local nearest = "?"
    if root then
        local best
        for _, prompt in ipairs(allPrompts()) do
            local p = positionOf(promptPart(prompt))
            if p then
                local d = (p - root.Position).Magnitude
                if not best or d < best then best = d end
            end
        end
        if best then nearest = string.format("%.1f studs", best) end
    end
    statusLabel.Text = string.format(
        "Mode: %s | Clock %.2f (%s)\nExisting prompts: %d | Nearest: %s\nTarget: %s\n%s",
        running and "RUNNING" or "STOPPED", t, isNight() and "NIGHT" or "DAY",
        #allPrompts(), nearest, targetText, extra or ""
    )
end
local function moveTo(goal, stopDistance, timeout)
    local _, humanoid, root = characterParts()
    if not humanoid or not root then return false end
    if (root.Position - goal).Magnitude <= stopDistance then return true end
    -- Fast path first: for nearby candy drops, direct MoveTo avoids the delay
    -- caused by calculating a full path for every tiny pickup. Fall back to
    -- Pathfinding only if direct movement does not get close quickly.
    humanoid:MoveTo(goal)
    local directUntil = os.clock() + math.min(2.5, timeout * 0.55)
    while running and isNight() and os.clock() < directUntil do
        local _, _, currentRoot = characterParts()
        if not currentRoot then return false end
        if (currentRoot.Position - goal).Magnitude <= stopDistance then return true end
        task.wait(0.06)
    end
    local _, _, currentRoot = characterParts()
    if not currentRoot then return false end
    local path = PathfindingService:CreatePath({
        AgentRadius = 2,
        AgentHeight = 5,
        AgentCanJump = true,
        AgentCanClimb = true,
    })
    local ok = pcall(function() path:ComputeAsync(currentRoot.Position, goal) end)
    if not ok or path.Status ~= Enum.PathStatus.Success then
        humanoid:MoveTo(goal)
        local start = os.clock()
        while running and isNight() and os.clock() - start < timeout do
            local _, _, r = characterParts()
            if not r then return false end
            if (r.Position - goal).Magnitude <= stopDistance then return true end
            task.wait(0.06)
        end
        return false
    end
    local start = os.clock()
    for _, waypoint in ipairs(path:GetWaypoints()) do
        if not running or not isNight() then return false end
        local _, hum, r0 = characterParts()
        if not hum or not r0 then return false end
        if (r0.Position - goal).Magnitude <= stopDistance then return true end
        if waypoint.Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
        hum:MoveTo(waypoint.Position)
        local done, reached = false, false
        local conn = hum.MoveToFinished:Connect(function(okReached)
            reached, done = okReached, true
        end)
        while running and isNight() and not done and os.clock() - start < timeout do
            local _, _, r = characterParts()
            if r and (r.Position - goal).Magnitude <= stopDistance then
                done, reached = true, true
                break
            end
            task.wait(0.06)
        end
        conn:Disconnect()
        if not reached then return false end
    end
    local _, _, finalRoot = characterParts()
    return finalRoot ~= nil and (finalRoot.Position - goal).Magnitude <= stopDistance + 2
end
-- Candy finder: prioritize objects whose names explicitly mention candy/corn,
-- then use the visual heuristic for newly spawned unlabelled drops.
local function looksLikeCandycorn(part, baselineParts)
    if not part or not part:IsA("BasePart") or part.Transparency >= 1 then return false end
    if part.Size.Magnitude > 5 or part.Size.Magnitude < 0.12 then return false end
    local n = string.lower(part.Name)
    -- Explicit candy names are the strongest signal.
    if string.find(n, "candy", 1, true) or string.find(n, "corn", 1, true) then
        return true
    end
    -- Generic-named drops must be new, small, and candy-colored.
    if not baselineParts or baselineParts[part] then return false end
    local c = part.Color
    local candyColor = c.R >= 0.62 and c.G >= 0.28 and c.G <= 0.92 and c.B <= 0.48
    return candyColor and part.Size.Magnitude <= 3.5
end
local function candyPriority(part, baselineParts)
    local n = string.lower(part.Name)
    if string.find(n, "candy", 1, true) or string.find(n, "corn", 1, true) then
        return 0
    end
    if baselineParts and not baselineParts[part] then return 1 end
    return 2
end
-- Aim the actual in-game camera at the door briefly after teleporting.
-- This does not change movement, pathfinding, candy handling, or the GUI.
local CAMERA_AIM_SECONDS = 1.5
local cameraAimToken = 0
local function aimCameraAtDoor(doorPosition)
    cameraAimToken += 1
    local thisToken = cameraAimToken
    local started = os.clock()
    task.spawn(function()
        while thisToken == cameraAimToken
            and os.clock() - started < CAMERA_AIM_SECONDS do
            local camera = Workspace.CurrentCamera
            if camera then
                local cameraPosition = camera.CFrame.Position
                if (doorPosition - cameraPosition).Magnitude > 0.01 then
                    camera.CFrame = CFrame.lookAt(cameraPosition, doorPosition)
                end
            end
            RunService.RenderStepped:Wait()
        end
    end)
end
local function teleportToHouse(prompt)
    if not prompt or not prompt.Parent then return false end
    local char, humanoid, root = characterParts()
    local doorPart = promptPart(prompt)
    local doorPos = positionOf(doorPart)
    if not char or not humanoid or not root or not doorPos then return false end
    -- Choose a position beside the door using the door's own orientation,
    -- then raycast down to find real ground. Never blindly teleport to a fixed
    -- world-space X offset (that can place the player over the void).
    local side = Vector3.new(1, 0, 0)
    if doorPart and doorPart:IsA("BasePart") then
        side = doorPart.CFrame.RightVector
    end
    local flatSide = Vector3.new(side.X, 0, side.Z)
    if flatSide.Magnitude < 0.01 then flatSide = Vector3.new(1, 0, 0) end
    flatSide = flatSide.Unit
    local candidates = {
        doorPos + flatSide * HOUSE_TELEPORT_OFFSET,
        doorPos - flatSide * HOUSE_TELEPORT_OFFSET,
        doorPos + Vector3.new(0, 0, HOUSE_TELEPORT_OFFSET),
        doorPos - Vector3.new(0, 0, HOUSE_TELEPORT_OFFSET),
    }
    local safePosition
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = {char}
    params.IgnoreWater = false
    for _, candidate in ipairs(candidates) do
        local origin = candidate + Vector3.new(0, 18, 0)
        local result = Workspace:Raycast(origin, Vector3.new(0, -100, 0), params)
        if result and result.Normal.Y > 0.55 then
            -- Put the character's root a little above the detected floor.
            safePosition = result.Position + Vector3.new(0, 3.2, 0)
            break
        end
    end
    if not safePosition then
        log("No safe ground beside door; skipping teleport and walking instead:", prompt:GetFullName())
        return false
    end
    local ok, err = pcall(function()
        char:PivotTo(CFrame.lookAt(safePosition, Vector3.new(doorPos.X, safePosition.Y, doorPos.Z)))
        -- Turn the CAMERA toward the door too (not just the character).
        aimCameraAtDoor(doorPos)
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end)
    if not ok then
        log("House teleport failed:", err)
        return false
    end
    -- Give physics/network ownership time to settle before issuing MoveTo.
    task.wait(TELEPORT_SETTLE_DELAY)
    local _, newHumanoid, newRoot = characterParts()
    if not newHumanoid or not newRoot then return false end
    if newRoot.Position.Y < Workspace.FallenPartsDestroyHeight + 10 then
        log("Teleport landed too low; refusing to continue.")
        return false
    end
    return true
end
local function getCandyCornModels()
    local effects = Workspace:FindFirstChild("Effects")
    if not effects then
        return {}
    end
    local models = {}
    for _, obj in ipairs(effects:GetDescendants()) do
        if obj:IsA("Model") and string.lower(obj.Name) == "candycorn" then
            -- Count each visual model once, never its Cube.001/Cube.002 parts.
            table.insert(models, obj)
        end
    end
    return models
end
local function nearestCandyCorn()
    local _, _, root = characterParts()
    if not root then
        return nil
    end
    local best, bestDistance
    for _, model in ipairs(getCandyCornModels()) do
        if model.Parent then
            local pos = positionOf(model)
            if pos then
                local distance = (pos - root.Position).Magnitude
                if not bestDistance or distance < bestDistance then
                    best, bestDistance = model, distance
                end
            end
        end
    end
    return best
end
local function teleportFiveStudsAboveGround(model)
    local char, _, root = characterParts()
    local candyPos = positionOf(model)
    if not char or not root or not candyPos then
        return false
    end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = {char, model}
    params.IgnoreWater = false
    -- Raycast below the candy to locate the floor, then land 5 studs above it.
    local origin = Vector3.new(candyPos.X, candyPos.Y + 20, candyPos.Z)
    local result = Workspace:Raycast(origin, Vector3.new(0, -120, 0), params)
    local destination
    if result and result.Normal.Y > 0.55 then
        destination = result.Position + Vector3.new(0, 5, 0)
    else
        -- If ground cannot be found, use the candy position as a cautious fallback.
        destination = candyPos + Vector3.new(0, 5, 0)
    end
    local ok, err = pcall(function()
        char:PivotTo(CFrame.new(destination))
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end)
    if not ok then
        log("Candy teleport failed:", err)
        return false
    end
    task.wait(TELEPORT_SETTLE_DELAY)
    return characterParts() ~= nil
end
local function collectVisualCandy(_doorPosition, _baselineParts)
    -- STRICT PRIORITY: while any CandyCorn visual model exists, do not knock.
    -- Keep processing until the live model count reaches zero.
    local previousTarget = nil
    while running and isNight() do
        local models = getCandyCornModels()
        if #models == 0 then
            targetText = "Candy count: 0 — resume knocking"
            updateStatus("No CandyCorn visuals remain; door work may resume.")
            return
        end
        local model = nearestCandyCorn()
        if not model then
            task.wait(CANDY_RETRY_WAIT)
            continue
        end
        local candyPos = positionOf(model)
        if not candyPos then
            task.wait(CANDY_RETRY_WAIT)
            continue
        end
        targetText = string.format("CANDY PRIORITY | %d remaining", #models)
        updateStatus("Candy priority active. Knocking is suspended until the count reaches zero.")
        if model ~= previousTarget then
            log("Candy priority target:", model:GetFullName(), "remaining:", #models)
            previousTarget = model
        end
        -- Teleport with a 5-stud ground clearance, then slowly approach the visual.
        teleportFiveStudsAboveGround(model)
        if running and isNight() and model.Parent then
            local currentPos = positionOf(model)
            if currentPos then
                moveTo(currentPos + Vector3.new(0, 1.0, 0), CANDY_STOP_DISTANCE, CANDY_TIMEOUT)
            end
        end
        -- Give the game's normal pickup logic time to remove the visual.
        local waitUntil = os.clock() + 1.0
        while running and isNight() and model.Parent and os.clock() < waitUntil do
            task.wait(0.1)
        end
        -- Do not mark a still-existing candy as handled: retry it next iteration.
        task.wait(CANDY_RETRY_WAIT)
    end
end
local function snapshotVisuals()
    -- Snapshot EVERY existing BasePart, not just candy-colored parts. Otherwise
    -- every door/wall part looks "new" and the farm teleports back to the door.
    local snapshot = {}
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("BasePart") then
            snapshot[obj] = true
        end
    end
    return snapshot
end
local function tryDoorInteraction(prompt)
    if not prompt or not prompt.Parent then return false, "Prompt disappeared" end
    local part = promptPart(prompt)
    local pos = positionOf(part)
    local _, _, root = characterParts()
    if not pos or not root then return false, "Door/player position unavailable" end
    local distance = (root.Position - pos).Magnitude
    log("Prompt test:", prompt:GetFullName(),
        "Enabled=", prompt.Enabled,
        "Distance=", string.format("%.2f", distance),
        "MaxActivationDistance=", prompt.MaxActivationDistance,
        "KeyboardKeyCode=", tostring(prompt.KeyboardKeyCode),
        "HoldDuration=", prompt.HoldDuration,
        "RequiresLineOfSight=", prompt.RequiresLineOfSight)
    if not prompt.Enabled then return false, "Prompt is disabled" end
    if distance > prompt.MaxActivationDistance then
        return false, string.format("Out of range (%.1f > %.1f)", distance, prompt.MaxActivationDistance)
    end
    local triggered = false
    local connection = prompt.Triggered:Connect(function(who)
        if who == player then
            triggered = true
            log("Observed prompt Triggered event for local player.")
        end
    end)
    targetText = "Trying existing prompt input"
    updateStatus("Attempting ProximityPrompt InputHoldBegin/End.")
    -- Trial: use Roblox's ProximityPrompt input methods on the existing prompt.
    -- These may not activate a server interaction in every game; the server's
    -- existing prompt handler remains responsible for granting the reward.
    local began, beginErr = pcall(function() prompt:InputHoldBegin() end)
    log("InputHoldBegin:", began, beginErr or "ok")
    task.wait(math.max(prompt.HoldDuration, 0.15) + 0.1)
    local ended, endErr = pcall(function() prompt:InputHoldEnd() end)
    log("InputHoldEnd:", ended, endErr or "ok")
    local started = os.clock()
    while running and not triggered and os.clock() - started < 3 do
        task.wait(0.1)
    end
    connection:Disconnect()
    if triggered then return true, "Prompt interaction observed" end
    return false, "InputHold calls returned but no Triggered event was observed; game may require real input or server-side interaction integration"
end
local function houseForPrompt(prompt)
    -- Existing hierarchy example: HouseModel81.Door_Rig.RootPart.Attachment.ProximityPrompt
    -- Use the nearest HouseModel ancestor so multiple prompts/door parts in one
    -- house cannot send the character back to the same house again.
    local node = prompt
    local fallback = nil
    while node and node ~= MAP_ROOT do
        if node:IsA("Model") then
            if string.match(node.Name, "^HouseModel") then
                return node
            end
            if string.find(string.lower(node.Name), "house", 1, true) then
                fallback = fallback or node
            end
        end
        node = node.Parent
    end
    return fallback
end
local function houseKeyForPrompt(prompt)
    local house = houseForPrompt(prompt)
    if house then return house:GetFullName() end
    local node = prompt
    while node and node.Parent and node.Parent ~= MAP_ROOT do
        local parent = node.Parent
        if parent:IsA("Model") and (string.find(string.lower(parent.Name), "house", 1, true)
            or string.find(string.lower(parent.Name), "pumpkin", 1, true)) then
            return parent:GetFullName()
        end
        node = parent
    end
    return prompt:GetFullName()
end
local function chooseNearest()
    local _, _, root = characterParts()
    if not root then return nil end
    local best, bestDistance
    for _, prompt in ipairs(allPrompts()) do
        local house = houseForPrompt(prompt)
        local houseKey = houseKeyForPrompt(prompt)
        if not usedPrompts[prompt] and not usedHouseKeys[houseKey]
            and not (house and usedHouses[house]) then
            local p = positionOf(promptPart(prompt))
            if p then
                local d = (p - root.Position).Magnitude
                if not bestDistance or d < bestDistance then best, bestDistance = prompt, d end
            end
        end
    end
    return best, bestDistance
end
local function processDoor(prompt)
    local doorPos = positionOf(promptPart(prompt))
    if not doorPos then usedPrompts[prompt] = true; return end
    targetText = prompt:GetFullName()
    updateStatus("Safely approaching unused house.")
    -- Hybrid approach: teleport only to a raycast-verified ground position beside
    -- this house. If no safe landing spot is found, pathfind from the current spot.
    local teleported = teleportToHouse(prompt)
    if not teleported then
        updateStatus("No safe landing spot; pathfinding to house.")
        if not moveTo(doorPos, DOOR_STOP_DISTANCE, DOOR_TIMEOUT) then
            log("Could not approach door safely:", prompt:GetFullName())
            return
        end
    else
        -- A small settle pause prevents starting the prompt interaction mid-physics.
        task.wait(0.25)
        local _, _, nearRoot = characterParts()
        if not nearRoot or nearRoot.Position.Y < Workspace.FallenPartsDestroyHeight + 10 then
            log("Unsafe character position after house teleport; aborting this door.")
            return
        end
        -- Ensure we're within the existing prompt's activation area without
        -- forcing an interaction through unsupported client-only APIs.
        if (nearRoot.Position - doorPos).Magnitude > DOOR_STOP_DISTANCE + 3 then
            if not moveTo(doorPos, DOOR_STOP_DISTANCE, DOOR_TIMEOUT) then
                log("Could not finish approaching door:", prompt:GetFullName())
                return
            end
        end
    end
    local baseline = snapshotVisuals()
    targetText = "At door"
    updateStatus("Waiting for existing door interaction.")
    local interacted, reason = tryDoorInteraction(prompt)
    log(reason)
    if interacted then
        -- Wait briefly for the server to spawn/replicate drops and for the
        -- character physics to settle before starting the candy sweep.
        task.wait(CANDY_SPAWN_WAIT)
        local _, _, afterKnockRoot = characterParts()
        if not afterKnockRoot or afterKnockRoot.Position.Y < Workspace.FallenPartsDestroyHeight + 10 then
            log("Character is below safe height after knock; aborting candy sweep for safety.")
            return
        end
        usedPrompts[prompt] = true
        local house = houseForPrompt(prompt)
        local houseKey = houseKeyForPrompt(prompt)
        usedHouseKeys[houseKey] = true
        log("Marked stable house key as visited:", houseKey)
        if house then
            usedHouses[house] = true
            -- Mark every prompt inside this same house as used, not only the
            -- exact prompt instance that triggered the knock.
            for _, otherPrompt in ipairs(allPrompts()) do
                if houseForPrompt(otherPrompt) == house then
                    usedPrompts[otherPrompt] = true
                end
            end
            log("Marked whole house as visited:", house:GetFullName())
        end
        collectVisualCandy(doorPos, baseline)
    else
        -- Don't mark it used if no knock occurred; retry it on the next loop.
        task.wait(0.5)
    end
end
-- Walk to a random ground point during daytime. This uses normal Humanoid movement;
-- it deliberately does not run during night farming or teleport the character.
local function wanderDuringDay()
    if not running or isNight() then return end

    local _, humanoid, root = characterParts()
    if not humanoid or not root then
        task.wait(0.5)
        return
    end

    local origin = root.Position
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { player.Character }
    params.IgnoreWater = false

    local destination
    for attempt = 1, 12 do
        local angle = math.random() * math.pi * 2
        local distance = math.random(WANDER_MIN_DISTANCE, WANDER_MAX_DISTANCE)
        local x = origin.X + math.cos(angle) * distance
        local z = origin.Z + math.sin(angle) * distance
        local rayOrigin = Vector3.new(x, origin.Y + 100, z)
        local hit = Workspace:Raycast(rayOrigin, Vector3.new(0, -250, 0), params)
        if hit and hit.Normal.Y > 0.55 then
            local candidate = hit.Position + Vector3.new(0, 3, 0)
            if (candidate - origin).Magnitude >= WANDER_MIN_DISTANCE then
                destination = candidate
                break
            end
        end
    end

    if not destination then
        targetText = "Day: looking for safe walking point"
        updateStatus("Daytime wandering is active; searching for nearby ground.")
        task.wait(1)
        return
    end

    targetText = "DAY WANDER"
    updateStatus("Walking to a random point during daytime.")
    humanoid:MoveTo(destination)

    local started = os.clock()
    while running and not isNight() and os.clock() - started < WANDER_MOVE_TIMEOUT do
        local _, _, currentRoot = characterParts()
        if not currentRoot then break end
        if (currentRoot.Position - destination).Magnitude <= 5 then break end
        task.wait(0.15)
    end

    -- Stop any leftover movement when night starts or the movement times out.
    local _, currentHumanoid = characterParts()
    if currentHumanoid and (not running or isNight()) then
        currentHumanoid:MoveTo(currentHumanoid.Parent.HumanoidRootPart.Position)
    end
    if running and not isNight() then
        task.wait(WANDER_PAUSE_MIN + math.random() * (WANDER_PAUSE_MAX - WANDER_PAUSE_MIN))
    end
end

local function setRunning(value)
    running = value
    if running then
        stop.Text = "STOP"
        stop.BackgroundColor3 = Color3.fromRGB(126, 49, 57)
        targetText = "Starting farm"
        updateStatus("Farm enabled.")
        log("Started by user.")
    else
        stop.Text = "START"
        stop.BackgroundColor3 = Color3.fromRGB(48, 125, 78)
        targetText = "Stopped"
        updateStatus("Farm paused. Press START to resume.")
        log("Stopped by user.")
    end
end
stop.Activated:Connect(function()
    setRunning(not running)
end)
task.spawn(function()
    while true do
        if not running then
            task.wait(0.2)
        else
            local night = isNight()
            if night and not isNightLastTick then
                table.clear(usedPrompts)
                table.clear(usedHouses)
                table.clear(usedHouseKeys)
                table.clear(candyHandled)
                log("Night began; reset door/house/candy tracking.")
            end
            isNightLastTick = night
            if not night then
                -- During daytime, wander around the map instead of standing idle.
                if not busy then
                    busy = true
                    wanderDuringDay()
                    busy = false
                else
                    task.wait(POLL)
                end
            elseif not busy then
                busy = true
                -- Candy always has priority over door work.
                if #getCandyCornModels() > 0 then
                    collectVisualCandy(nil, nil)
                else
                    local prompt = chooseNearest()
                    if prompt then
                        processDoor(prompt)
                    else
                        targetText = "No unused enabled prompts"
                        updateStatus("Rechecking in 2 seconds.")
                        task.wait(2)
                    end
                end
                busy = false
            else
                task.wait(0.2)
            end
        end
    end
end)
print("[HalloweenFarm] Auto-started. Press STOP to pause. Existing prompts:", #allPrompts())
updateStatus("Farm auto-started. Press STOP to pause.")
