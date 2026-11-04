-- RIOTFALL
local ctx = ...
local task = ctx.task

--[[
    Built from the game's dumps:
      * Workspace.Characters holds one model per player (named after the Player)  -> ESP / Aimbot
      * OtherPlayers.characterMeshes[player]                                      -> enemy meshes
      * Player module -> u2.player.character.{camera, fpController}               -> local state
      * Weapon.fire: weaponData.stats / weaponData.motion, animator parameters     -> weapon mods
      * Character._updateStamina: tacticalSprintStamina                            -> stamina
      * camera.cameraRotation.channels.input, camera.cframe                        -> aimbot
      * Captured "requestHitscanDamage" and "sendBullet" calls                     -> kill aura

    The camera and server code aren't dumped, so the camera input scale comes from captured
    samples, and what the server enforces is unknown.
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local Camera      = Workspace.CurrentCamera

---------------------------------------------------------------------- state
local S = {
    -- aimbot
    aimbot = false, aimKey = Enum.UserInputType.MouseButton2, aimFov = 150, aimSmooth = 5,
    aimPart = "Neck", wallCheck = true, teamCheck = true, showFov = true,
    -- esp
    esp = false, espBox = true, espNames = true, espDist = true, espHighlight = true, espTeamCheck = false,
    espColor = Color3.fromRGB(255, 70, 70), espMaxDist = 2000,
    -- weapon
    noRecoil = false, noSpread = false, infAmmo = false,
    -- movement
    infStamina = false,
    -- kill aura
    aura = false, auraRange = 100, auraDelay = 0.15, auraWallCheck = true, auraTeamCheck = true,
    auraPart = "MidUpperSpine",
}

local function track(c) return ctx:Track(c) end

-- These loops run many times a second, so each distinct error is only logged once.
local loggedErrors = {}
local function logOnce(label, err)
    local message = label .. ": " .. tostring(err)
    if not loggedErrors[message] then
        loggedErrors[message] = true
        ctx.Log(message, "error")
    end
end

---------------------------------------------------------------------- helpers
local function safe(f, ...)
    local ok, r = pcall(f, ...)
    if ok then return r end
end

local c2s = safe(function() return require(ReplicatedStorage.clientToServer) end)
local otherPlayers = safe(function() return require(ReplicatedStorage.Players.OtherPlayers) end)

--- Finds the game's `Player` object. It lasts across respawns: loadCharacter gives it a new
--- character, and it holds nil while dead. Weapons and controllers have a .character too,
--- but theirs stays on the old, dead character, so match a field only Player has.
local cachedPlayer
local lastScan = 0
local function getPlayerObj()
    if cachedPlayer then return cachedPlayer end
    if not getgc then return end
    -- getgc is expensive: until the Player exists, scan at most every 2 seconds.
    if os.clock() - lastScan < 2 then return end
    lastScan = os.clock()
    for _, t in ipairs(getgc(true)) do
        if type(t) == "table" and rawget(t, "mouseFreedSignal")
            and rawget(t, "robloxPlayer") == LocalPlayer then
            cachedPlayer = t
            return t
        end
    end
end

local function getChar()  local p = getPlayerObj() return p and p.character end
local function getFPC()   local c = getChar()      return c and c.fpController end

local function isEnemy(plr)
    if plr == LocalPlayer then return false end
    if not LocalPlayer.Team or not plr.Team then return true end
    return plr.Team ~= LocalPlayer.Team
end

local function charactersFolder() return Workspace:FindFirstChild("Characters") end

--- iterate { player, model } for every other player's character
local function eachEnemyModel(teamCheck)
    local out = {}
    local folder = charactersFolder()
    if not folder then return out end
    for _, model in ipairs(folder:GetChildren()) do
        local plr = Players:FindFirstChild(model.Name)
        if plr and plr ~= LocalPlayer and (not teamCheck or isEnemy(plr)) then
            out[#out + 1] = { plr = plr, model = model }
        end
    end
    return out
end

local function getMesh(plr)
    local meshes = otherPlayers and otherPlayers.characterMeshes
    return meshes and plr and meshes[plr]
end

local function positionOf(inst)
    if not inst then return end
    if inst:IsA("BasePart") then return inst.Position end
    if inst:IsA("Bone") then return inst.TransformedWorldCFrame.Position end
    if inst:IsA("Attachment") then return inst.WorldPosition end
end

-- Body parts live on the CharacterMesh, not the capsule in Workspace.Characters. Collision
-- parts are what bullets hit, but they go stale while collision is inactive, so in that
-- state the animated rig comes first.
local function meshSources(mesh, collisionActive)
    local geometry = mesh.collisionGeometry
    local collision = { "collisionModel", geometry and geometry.collisionModel }
    local skeleton = { "skeleton", geometry and geometry.skeleton }
    local model = { "model", mesh.model }
    if collisionActive then
        return { collision, skeleton, model }
    end
    return { skeleton, model, collision }
end

-- Results are cached because this runs per enemy, per frame; misses are retried once a second.
local partCache = setmetatable({}, { __mode = "k" })
local function findMeshPart(mesh, name)
    local cache = partCache[mesh]
    if not cache then
        cache = {}
        partCache[mesh] = cache
    end
    local geometry = mesh.collisionGeometry
    local collisionActive = geometry and geometry.isActive
    local key = collisionActive and name or name .. "#idle"
    local entry = cache[key]
    if entry then
        if entry.inst and entry.inst.Parent then return entry.inst, entry.source end
        if not entry.inst and os.clock() - entry.checked < 1 then return end
    end
    for _, source in ipairs(meshSources(mesh, collisionActive)) do
        local container = source[2]
        local inst = typeof(container) == "Instance" and container:FindFirstChild(name, true) or nil
        if positionOf(inst) then
            cache[key] = { inst = inst, source = source[1] }
            return inst, source[1]
        end
    end
    cache[key] = { checked = os.clock() }
end

-- Rough stand-ins if a part can't be found on the mesh.
local function capsulePartFor(partName)
    if partName == "Head" or partName == "Neck" then return "Top" end
    if partName:find("Leg") then return "Bottom" end
    return "Center"
end

--- Returns the world position for a body part, plus where it came from.
local function getAimPoint(model, partName)
    local mesh = getMesh(Players:FindFirstChild(model.Name))
    if mesh then
        local inst, source = findMeshPart(mesh, partName)
        if inst then
            -- Hidden players may not update their parts, so ignore one that has drifted
            -- further from the capsule than a body could reach.
            local point = positionOf(inst)
            if (point - model:GetPivot().Position).Magnitude <= 8 then
                return point, source
            end
        end
    end
    local capsuleName = capsulePartFor(partName)
    local point = positionOf(model:FindFirstChild(capsuleName))
    if point then return point, "capsule " .. capsuleName end
    local ok, pivot = pcall(function() return model:GetPivot() end)
    if ok then return pivot.Position, "pivot" end
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
local function visible(point, model)
    local origin = Camera.CFrame.Position
    local ignore = { Camera }
    -- Capsules and collision parts aren't cover, and idle collision parts can be anywhere.
    for _, name in ipairs({ "Characters", "CharacterCollisions", "WeaponRigs" }) do
        local folder = Workspace:FindFirstChild(name)
        if folder then ignore[#ignore + 1] = folder end
    end
    rayParams.FilterDescendantsInstances = ignore
    local hit = Workspace:Raycast(origin, point - origin, rayParams)
    -- Collision parts aren't under the capsule, so a ray that stops close to the target
    -- also counts as a clear shot.
    return not hit or hit.Instance:IsDescendantOf(model) or (hit.Position - point).Magnitude < 3
end

---------------------------------------------------------------------- aimbot
local fovCircle
if Drawing then
    fovCircle = Drawing.new("Circle")
    fovCircle.Thickness = 1
    fovCircle.NumSides = 64
    fovCircle.Filled = false
    fovCircle.Color = Color3.new(1, 1, 1)
    fovCircle.Visible = false
    ctx:Track(fovCircle)
end

local function aimHeld()
    if S.aimKey.EnumType == Enum.UserInputType then
        return UserInputService:IsMouseButtonPressed(S.aimKey)
    end
    return UserInputService:IsKeyDown(S.aimKey)
end

-- The player being aimed at stays the target for as long as the key is held and they
-- remain valid, so the aim doesn't jump between two nearby players.
local aimLock

local function closestTarget()
    local viewport = Camera.ViewportSize
    local center = Vector2.new(viewport.X / 2, viewport.Y / 2)
    local best, bestPoint, bestDist, bestPlayer
    local dead, offScreen, outsideFov, blocked = 0, 0, 0, 0
    for _, e in ipairs(eachEnemyModel(S.teamCheck)) do
        local mesh = getMesh(e.plr)
        if mesh and mesh.killed then
            dead = dead + 1
        else
            local point = getAimPoint(e.model, S.aimPart)
            local sp, onScreen = Camera:WorldToViewportPoint(point)
            local screenPos = Vector2.new(sp.X, sp.Y)
            local d = (screenPos - center).Magnitude
            if not onScreen then
                offScreen = offScreen + 1
            elseif d > S.aimFov then
                outsideFov = outsideFov + 1
            elseif S.wallCheck and not visible(point, e.model) then
                blocked = blocked + 1
            elseif e.plr == aimLock then
                return screenPos, center, point
            elseif not bestDist or d < bestDist then
                best, bestPoint, bestDist, bestPlayer = screenPos, point, d, e.plr
            end
        end
    end
    if not best then
        S.aimSkip = ("no target: %d off screen, %d outside FOV, %d blocked by wall check, %d dead"):format(
            offScreen, outsideFov, blocked, dead)
    end
    aimLock = bestPlayer
    return best, center, bestPoint
end

local function wrapAngle(angle)
    return (angle + math.pi) % (2 * math.pi) - math.pi
end

-- The game rebuilds camera.yaw and camera.pitch every frame from cameraRotation, a set of
-- channels that are added together: "input" (the running mouse total) and "recoil". In a
-- captured sample, yaw and pitch were about -0.001 times that total.
local CAMERA_INPUT_SCALE = 0.001

local function cameraChannels(cam)
    local rotation = cam.cameraRotation
    local channels = rotation and rotation.channels
    if not channels or typeof(channels.input) ~= "Vector2" then return end
    local recoil = typeof(channels.recoil) == "Vector2" and channels.recoil or Vector2.zero
    return rotation, channels, recoil
end

local aimState = setmetatable({}, { __mode = "k" })
local aimDriveFailed = setmetatable({}, { __mode = "k" })

--- Turns the game camera by steering its input channel. Returns false if that isn't possible.
local function aimWithCamera(cam, point, dt)
    if aimDriveFailed[cam] then return false end
    local rotation, channels, recoil = cameraChannels(cam)
    if not rotation then return false end

    local input = channels.input
    local yaw, pitch = cam:getYaw(), cam:getPitch()
    local now = os.clock()
    local state = aimState[cam]

    if not state or now - state.time > 0.2 then
        -- New aim: record the small gap between the camera and the channel total (from
        -- things like idle sway). Targets are absolute from here, so a frame of camera
        -- delay can't make the aim overshoot the way adding a correction every frame would.
        state = {
            yawOffset = yaw + (input.X + recoil.X) * CAMERA_INPUT_SCALE,
            pitchOffset = pitch + (input.Y + recoil.Y) * CAMERA_INPUT_SCALE,
            strikes = 0,
        }
        aimState[cam] = state
    elseif state.commanded and state.commanded > 0.01 then
        -- If the view barely moves for about half a second after being told to, this
        -- isn't reaching the camera. That long, so moving the mouse by hand can't trigger it.
        local moved = math.abs(wrapAngle(yaw - state.yaw)) + math.abs(pitch - state.pitch)
        state.strikes = moved < state.commanded * 0.1 and state.strikes + 1 or 0
        if state.strikes >= 30 then
            aimDriveFailed[cam] = true
            S.auraNote = "Aimbot: the camera isn't following its input channel, switching to the mouse"
            return false
        end
    end

    -- The gap isn't constant: firing kick also moves the view. Keep measuring it, but only
    -- once settled, because mid-turn the camera may still be catching up with the input.
    if state.commanded and state.commanded < 0.01 then
        local yawGap = yaw + (input.X + recoil.X) * CAMERA_INPUT_SCALE
        local pitchGap = pitch + (input.Y + recoil.Y) * CAMERA_INPUT_SCALE
        state.yawOffset = state.yawOffset + (yawGap - state.yawOffset) * 0.25
        state.pitchOffset = state.pitchOffset + (pitchGap - state.pitchOffset) * 0.25
    end

    -- FirstPersonController builds the view from Angles(0, yaw, 0) * Angles(pitch, 0, 0),
    -- so a look direction d has yaw = atan2(-d.X, -d.Z) and pitch = asin(d.Y).
    local view = cam.cframe
    local dir = (point - view.Position).Unit
    local targetYaw = yaw + wrapAngle(math.atan2(-dir.X, -dir.Z) - yaw)
    local targetPitch = math.asin(math.clamp(dir.Y, -1, 1))

    -- Weapon.fire shoots along camera.cframe.LookVector, which includes kick and animation
    -- on top of yaw and pitch, so aim that line at the target. Large differences are skipped
    -- because they only happen while the view is mid-turn.
    local look = view.LookVector
    local yawDrift = wrapAngle(yaw - math.atan2(-look.X, -look.Z))
    local pitchDrift = pitch - math.asin(math.clamp(look.Y, -1, 1))
    if math.abs(yawDrift) < 0.1 and math.abs(pitchDrift) < 0.1 then
        targetYaw = targetYaw + yawDrift
        targetPitch = targetPitch + pitchDrift
    end

    -- Subtracting recoil means the aim holds on target while the gun kicks.
    local targetInput = Vector2.new(
        (state.yawOffset - targetYaw) / CAMERA_INPUT_SCALE,
        (state.pitchOffset - targetPitch) / CAMERA_INPUT_SCALE
    ) - recoil

    -- Frame-rate independent: smoothing 1 snaps, higher values ease in.
    local alpha = 1 - (1 - 1 / math.max(S.aimSmooth, 1)) ^ (dt * 60)
    local newInput = input:Lerp(targetInput, alpha)
    if rotation.setChannel then
        rotation:setChannel("input", newInput)
    else
        channels.input = newInput
        rotation.changed = true
    end

    local step = newInput - input
    state.commanded = (math.abs(step.X) + math.abs(step.Y)) * CAMERA_INPUT_SCALE
    state.yaw, state.pitch, state.time = yaw, pitch, now
    return true
end

local function aimWithMouse(target, center)
    if not mousemoverel then return false end
    -- Pixels don't map 1:1 to camera turn at every sensitivity, and a full-distance
    -- move can overshoot and oscillate, so this always moves part of the way.
    local delta = (target - center) / math.max(S.aimSmooth, 2)
    mousemoverel(delta.X, delta.Y)
    return true
end

track(RunService.RenderStepped:Connect(function(dt)
    Camera = Workspace.CurrentCamera
    if fovCircle then
        fovCircle.Visible = S.aimbot and S.showFov
        fovCircle.Radius = S.aimFov
        fovCircle.Position = Camera.ViewportSize / 2
    end
    if not (S.aimbot and aimHeld()) then
        aimLock = nil
        return
    end

    -- Only aim while alive and in control, so menus and the mouse cursor aren't affected.
    local playerObj = getPlayerObj()
    local cam = playerObj and playerObj.character and playerObj.character.camera
    if not cam or playerObj.mouseFreed then return end

    local target, center, point = closestTarget()
    if not target then return end
    if aimWithCamera(cam, point, dt) then
        S.aimMode = "camera input"
    elseif aimWithMouse(target, center) then
        S.aimMode = "mouse movement"
    else
        S.aimMode = "unavailable: camera fields not found and no mousemoverel"
    end
end))

---------------------------------------------------------------------- ESP
local espObjects = {} -- [model] = {hl, gui, label}

local function clearEsp(model)
    local o = espObjects[model]
    if not o then return end
    if o.hl then o.hl:Destroy() end
    if o.gui then o.gui:Destroy() end
    if o.box then o.box:Remove() end
    espObjects[model] = nil
end

local function clearAllEsp()
    for m in pairs(espObjects) do clearEsp(m) end
end
ctx:OnCleanup(clearAllEsp)

local function rebuildHighlight(o, model, adornee)
    if o.hl then o.hl:Destroy() end
    o.hl = Instance.new("Highlight")
    o.hl.FillTransparency = 0.7
    o.hl.OutlineTransparency = 0
    o.hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    o.hl.Adornee = adornee
    o.hl.Parent = model
end

--- The visible mesh if it's alive and still exists, otherwise the capsule. A killed player's
--- mesh stays in characterMeshes until they respawn, and its model gets destroyed.
local function highlightTarget(plr, model)
    local mesh = getMesh(plr)
    if mesh and not mesh.killed and not mesh.destroyed
        and typeof(mesh.model) == "Instance" and mesh.model.Parent then
        return mesh.model
    end
    return model
end

local function buildEsp(model, plr)
    local o = {}
    local adornee = model:FindFirstChild("Head", true) or model.PrimaryPart
        or model:FindFirstChildWhichIsA("BasePart", true)
    o.gui = Instance.new("BillboardGui")
    o.gui.Size = UDim2.fromOffset(200, 40)
    o.gui.StudsOffset = Vector3.new(0, 2.5, 0)
    o.gui.AlwaysOnTop = true
    o.gui.Adornee = adornee
    o.gui.Parent = model
    o.label = Instance.new("TextLabel")
    o.label.BackgroundTransparency = 1
    o.label.Size = UDim2.fromScale(1, 1)
    o.label.TextStrokeTransparency = 0.4
    o.label.Font = Enum.Font.GothamBold
    o.label.TextSize = 13
    o.label.Parent = o.gui
    o.plr = plr
    if Drawing then
        o.box = Drawing.new("Square")
        o.box.Thickness = 1
        o.box.Filled = false
        o.box.Visible = false
    end
    espObjects[model] = o
end

-- Boxes use the capsule, which stays accurate when the game hides a player's visible model
-- (rendered = false), so they work where a Highlight on that model may not. The pivot sits
-- at the feet; captured neck positions were about 3.8 studs above it.
local ESP_BOX_HEIGHT = 5
track(RunService.RenderStepped:Connect(function()
    for model, o in pairs(espObjects) do
        if o.box then
            local feet = model:GetPivot().Position
            local bottom, onScreen = Camera:WorldToViewportPoint(feet)
            local top = Camera:WorldToViewportPoint(feet + Vector3.new(0, ESP_BOX_HEIGHT, 0))
            local visibleBox = S.espBox and o.show and onScreen and top.Z > 0
            o.box.Visible = visibleBox or false
            if visibleBox then
                local height = math.abs(bottom.Y - top.Y)
                local width = height * 0.55
                o.box.Size = Vector2.new(width, height)
                o.box.Position = Vector2.new(top.X - width / 2, math.min(top.Y, bottom.Y))
                o.box.Color = o.color
            end
        end
    end
end))

track(RunService.Heartbeat:Connect(function()
    if not S.esp then
        if next(espObjects) then clearAllEsp() end
        return
    end
    local seen = {}
    local myPos = Camera.CFrame.Position
    for _, e in ipairs(eachEnemyModel(S.espTeamCheck)) do
        seen[e.model] = true
        local o = espObjects[e.model]
        if not o then buildEsp(e.model, e.plr) o = espObjects[e.model] end
        local pos = getAimPoint(e.model, "MidUpperSpine") or myPos
        local dist = (pos - myPos).Magnitude
        local show = dist <= S.espMaxDist
        local color = (LocalPlayer.Team and e.plr.Team == LocalPlayer.Team) and Color3.fromRGB(80, 255, 120) or S.espColor
        -- The game adds its own highlight to a new mesh shortly after creating it, and that
        -- can hide this one. So rebuild once more after a delay, to be added after the game's.
        local target = highlightTarget(e.plr, e.model)
        if o.hlTarget ~= target then
            o.hlTarget = target
            o.hlRefreshAt = os.clock() + 1.5
            rebuildHighlight(o, e.model, target)
        elseif o.hlRefreshAt and os.clock() >= o.hlRefreshAt then
            o.hlRefreshAt = nil
            rebuildHighlight(o, e.model, target)
        end
        o.hl.Enabled = show and S.espHighlight
        o.hl.FillColor, o.hl.OutlineColor = color, color
        o.gui.Enabled = show and (S.espNames or S.espDist)
        o.show, o.color = show, color
        local text = {}
        if S.espNames then text[#text + 1] = e.plr.DisplayName end
        if S.espDist then text[#text + 1] = ("[%d]"):format(dist) end
        o.label.Text = table.concat(text, " ")
        o.label.TextColor3 = color
    end
    for m in pairs(espObjects) do
        if not seen[m] or not m.Parent then clearEsp(m) end
    end
end))

---------------------------------------------------------------------- weapon mods
-- From Weapon.fire: spread and recoil are read from weaponData (a private copy per gun, so
-- only your own guns change), and the magazine count lives in animator parameters.
-- keys is a strict proxy, so it can be indexed by name but not listed.
local gameKeys = safe(function() return require(ReplicatedStorage.constants).keys end)
local RECOIL_STATS = { "recoil" }
local RECOIL_MOTION = { "recoilKickback", "recoilKickdown", "recoilKickside", "recoilShake", "cameraImpactIntensity" }
local SPREAD_STATS = { "hipSpread", "aimedSpread" }

local savedWeaponValues = setmetatable({}, { __mode = "k" })
local function setZeroed(values, key, on)
    local saved = savedWeaponValues[values] or {}
    savedWeaponValues[values] = saved
    if on then
        if saved[key] == nil then saved[key] = values[key] end
        if saved[key] ~= nil then values[key] = 0 end
    elseif saved[key] ~= nil then
        values[key] = saved[key]
        saved[key] = nil
    end
end

local function applyWeaponMods(fpc)
    for _, weapon in ipairs(fpc.weapons) do
        local data = weapon.weaponData
        for _, name in ipairs(RECOIL_STATS) do setZeroed(data.stats, gameKeys.weaponStat[name], S.noRecoil) end
        for _, name in ipairs(RECOIL_MOTION) do setZeroed(data.motion, gameKeys.weaponMotion[name], S.noRecoil) end
        for _, name in ipairs(SPREAD_STATS) do setZeroed(data.stats, gameKeys.weaponStat[name], S.noSpread) end
    end
end

-- Fire only reloads when the magazine reaches 0 or 1, so topping it up skips reloading.
-- This is client-side: the server could still count shots, which the dumps can't show.
local function refillMagazines(fpc)
    for _, weapon in ipairs(fpc.weapons) do
        local bullets = weapon.animator:getParameter("magazineBullets")
        local capacity = weapon.animator:getParameter("magazineCapacity")
        if bullets and capacity and bullets < capacity then
            weapon.animator:setParameter("magazineBullets", capacity)
            if weapon == fpc.weapon then weapon:_updateWeaponHud() end
        end
    end
end

task.spawn(function()
    while task.wait(0.05) and ctx:Alive() do
        local fpc = getFPC()
        if fpc and gameKeys then
            local ok, err = pcall(applyWeaponMods, fpc)
            if not ok then logOnce("Weapon mods", err) end
            if S.infAmmo then
                ok, err = pcall(refillMagazines, fpc)
                if not ok then logOnce("Infinite ammo", err) end
            end
        end
        -- Character._updateStamina drains this while sprinting and stops the sprint below 0.
        -- 8 is the full value it starts at and regenerates to.
        if S.infStamina and fpc and fpc.character then
            fpc.character.tacticalSprintStamina = 8
        end
    end
end)

-- The loop above stops at shutdown, so put the guns' original values back here.
ctx:OnCleanup(function()
    S.noRecoil, S.noSpread = false, false
    local fpc = getFPC()
    if fpc and gameKeys then
        pcall(applyWeaponMods, fpc)
    end
end)

---------------------------------------------------------------------- kill aura
-- Payload layout and call order come from captured real shots: each hit is one
-- "requestHitscanDamage" followed by a "sendBullet" for the impact. Sent through
-- clientToServer because the remote is renamed at runtime and its index isn't stable.

local function characterId(capsule)
    local v = capsule and capsule:FindFirstChild("CharacterId")
    return v and v.Value
end

local function isDead(plr)
    local meshes = otherPlayers and otherPlayers.characterMeshes
    local mesh = meshes and meshes[plr]
    return mesh and mesh.killed
end

-- A death comes from the server, so it is the best sign that aura hits are landing.
local auraTarget, auraHits
local function noteAuraTargetDeath()
    local mesh = getMesh(auraTarget)
    if mesh and mesh.killed then
        S.auraNote = ("%s died after %d aura hits"):format(auraTarget.Name, auraHits)
        auraTarget = nil
    end
end

local function auraTick()
    noteAuraTargetDeath()
    local fpc = getFPC()
    local weapon = fpc and fpc.weapon
    if not weapon or fpc.equipment then
        S.auraStatus = "idle: no weapon found, or holding equipment"
        return
    end
    local ownId = characterId(fpc.character.capsule)
    if not ownId then
        S.auraStatus = "idle: own CharacterId not found"
        return
    end

    local camPos = Camera.CFrame.Position
    local best, bestPoint, bestDist
    local alive, inRange = 0, 0
    for _, e in ipairs(eachEnemyModel(S.auraTeamCheck)) do
        local point = getAimPoint(e.model, S.auraPart)
        if point and characterId(e.model) and not isDead(e.plr) then
            alive = alive + 1
            local dist = (point - camPos).Magnitude
            if dist <= S.auraRange then
                inRange = inRange + 1
                if (not bestDist or dist < bestDist)
                    and (not S.auraWallCheck or visible(point, e.model)) then
                    best, bestPoint, bestDist = e, point, dist
                end
            end
        end
    end
    if not best then
        if alive == 0 then
            S.auraStatus = "idle: no living enemies found"
        elseif inRange == 0 then
            S.auraStatus = "idle: no enemies in range"
        else
            S.auraStatus = "idle: enemies in range, but the wall check blocks them"
        end
        return
    end
    S.auraStatus = "firing at " .. best.plr.Name
    if auraTarget ~= best.plr then
        auraTarget, auraHits = best.plr, 0
    end
    auraHits = auraHits + 1

    c2s.fireServerUnsafe("requestHitscanDamage", {
        hitPartName = S.auraPart,
        damagePlayer = best.plr,
        raycastPos = bestPoint,
        weapon = weapon.weaponId,
        camPos = camPos,
        characterId = characterId(best.model),
        weaponEquipSlot = weapon.weaponEquipSlot,
        ownCharacterId = ownId,
    })

    -- In captures, direction is the unit vector from camPos to raycastPos, and the
    -- flesh impact sits exactly at raycastPos. hitMaterial is the string "Flesh" here.
    local direction = (bestPoint - camPos).Unit
    c2s.fireServerUnsafe("sendBullet", {
        direction = direction,
        hitMaterial = "Flesh",
        impactCFrame = CFrame.lookAt(bestPoint, bestPoint - direction),
    })
end

task.spawn(function()
    while ctx:Alive() do
        task.wait(S.auraDelay)
        if S.aura and c2s and c2s.fireServerUnsafe then
            local ok, err = pcall(auraTick)
            if not ok then logOnce("Kill aura", err) end
        end
    end
end)

---------------------------------------------------------------------- UI
local Main = ctx:SubTab("Main", "Lucide:house")

Main:AddSection("Aimbot", "Lucide:crosshair")
Main:AddToggle({
    Text = "Aimbot",
    Description = "Aims at the closest target in the FOV while the aim key is held",
    Icon = "Lucide:crosshair",
    Default = false,
    Flag = "aimbot",
    Callback = function(v) S.aimbot = v end,
})
local AIM_KEYS = {
    ["Right Mouse"] = Enum.UserInputType.MouseButton2,
    ["Left Mouse"]  = Enum.UserInputType.MouseButton1,
    ["E"]           = Enum.KeyCode.E,
    ["Q"]           = Enum.KeyCode.Q,
    ["Left Alt"]    = Enum.KeyCode.LeftAlt,
}
Main:AddDropdown({
    Text = "Aim Key",
    Description = "Hold this to aim",
    Icon = "Lucide:keyboard",
    Options = { "Right Mouse", "Left Mouse", "E", "Q", "Left Alt" },
    Default = "Right Mouse",
    Flag = "aim_key",
    Callback = function(v) S.aimKey = AIM_KEYS[v] or S.aimKey end,
})
Main:AddDropdown({
    Text = "Aim Part",
    Description = "The body part to aim at",
    Icon = "Lucide:target",
    Options = { "Neck", "MidUpperSpine", "LowerSpine" },
    Default = "Neck",
    Flag = "aim_part",
    Callback = function(v) S.aimPart = v end,
})
Main:AddSlider({
    Text = "Aim FOV",
    Description = "How far from the crosshair a target can be",
    Icon = "Lucide:radius",
    Min = 30,
    Max = 500,
    Default = 150,
    Increment = 5,
    Suffix = " px",
    Flag = "aim_fov",
    Callback = function(v) S.aimFov = v end,
})
Main:AddSlider({
    Text = "Aim Smoothing",
    Description = "1 snaps straight to the target and higher values ease in",
    Icon = "Lucide:gauge",
    Min = 1,
    Max = 20,
    Default = 5,
    Increment = 1,
    Flag = "aim_smooth",
    Callback = function(v) S.aimSmooth = v end,
})
Main:AddToggle({
    Text = "Aim Wall Check",
    Description = "Ignores targets behind cover",
    Icon = "Lucide:shield",
    Default = true,
    Flag = "aim_wall",
    Callback = function(v) S.wallCheck = v end,
})
Main:AddToggle({
    Text = "Aim Team Check",
    Description = "Ignores your teammates",
    Icon = "Lucide:users",
    Default = true,
    Flag = "aim_team",
    Callback = function(v) S.teamCheck = v end,
})
Main:AddToggle({
    Text = "Show FOV Circle",
    Description = "Draws the aim FOV on screen while Aimbot is on",
    Icon = "Lucide:circle",
    Default = true,
    Flag = "aim_showfov",
    Callback = function(v) S.showFov = v end,
})

Main:AddSection("Kill Aura", "Lucide:swords")
Main:AddToggle({
    Text = "Kill Aura",
    Description = "Reports hits on the closest target in range using your held gun",
    Icon = "Lucide:swords",
    Default = false,
    Flag = "aura",
    Locked = not (c2s and c2s.fireServerUnsafe),
    Callback = function(v) S.aura = v end,
})
-- Only part names seen in captured hits. Neck is the highest one captured so far.
Main:AddDropdown({
    Text = "Hit Part",
    Description = "The body part each hit is reported on",
    Icon = "Lucide:target",
    Options = {
        "MidUpperSpine", "Neck", "LowerSpine", "UpperArm.L", "UpperArm.R",
        "LowerArm.L", "LowerArm.R", "UpperLeg.L", "UpperLeg.R",
    },
    Default = "MidUpperSpine",
    Flag = "aura_part",
    Callback = function(v) S.auraPart = v end,
})
Main:AddSlider({
    Text = "Aura Range",
    Description = "How far away a target can be",
    Icon = "Lucide:radius",
    Min = 10,
    Max = 500,
    Default = 100,
    Increment = 10,
    Suffix = " studs",
    Flag = "aura_range",
    Callback = function(v) S.auraRange = v end,
})
Main:AddSlider({
    Text = "Aura Delay",
    Description = "Time between hits",
    Icon = "Lucide:timer",
    Min = 0.05,
    Max = 1,
    Default = 0.15,
    Increment = 0.05,
    Suffix = "s",
    Flag = "aura_delay",
    Callback = function(v) S.auraDelay = v end,
})
Main:AddToggle({
    Text = "Aura Wall Check",
    Description = "Ignores targets behind cover",
    Icon = "Lucide:shield",
    Default = true,
    Flag = "aura_wall",
    Callback = function(v) S.auraWallCheck = v end,
})
Main:AddToggle({
    Text = "Aura Team Check",
    Description = "Ignores your teammates",
    Icon = "Lucide:users",
    Default = true,
    Flag = "aura_team",
    Callback = function(v) S.auraTeamCheck = v end,
})

Main:AddSection("Weapon", "Lucide:wrench")
Main:AddToggle({
    Text = "No Recoil",
    Description = "Removes kick and camera shake from your guns",
    Icon = "Lucide:move",
    Default = false,
    Flag = "no_recoil",
    Callback = function(v) S.noRecoil = v end,
})
Main:AddToggle({
    Text = "No Spread",
    Description = "Removes hip and aimed bullet spread",
    Icon = "Lucide:locate-fixed",
    Default = false,
    Flag = "no_spread",
    Callback = function(v) S.noSpread = v end,
})
Main:AddToggle({
    Text = "Infinite Ammo",
    Description = "Keeps your magazine full on the client, which the server may not honour",
    Icon = "Lucide:infinity",
    Default = false,
    Flag = "inf_ammo",
    Callback = function(v) S.infAmmo = v end,
})

Main:AddSection("Movement", "Lucide:footprints")
Main:AddToggle({
    Text = "Unlimited Stamina",
    Description = "Lets you tactical sprint without running out",
    Icon = "Lucide:zap",
    Default = false,
    Flag = "inf_stamina",
    Callback = function(v) S.infStamina = v end,
})

local Visuals = ctx:SubTab("Visuals", "Lucide:eye")

Visuals:AddSection("Player ESP", "Lucide:eye")
Visuals:AddToggle({
    Text = "ESP",
    Description = "Shows other players through walls",
    Icon = "Lucide:eye",
    Default = false,
    Flag = "esp",
    Callback = function(v) S.esp = v end,
})
Visuals:AddToggle({
    Text = "Box",
    Description = "Draws a box around each player",
    Icon = "Lucide:square",
    Default = true,
    Flag = "esp_box",
    Callback = function(v) S.espBox = v end,
})
Visuals:AddToggle({
    Text = "Highlight",
    Description = "Colours each player's model",
    Icon = "Lucide:sparkles",
    Default = true,
    Flag = "esp_hl",
    Callback = function(v) S.espHighlight = v end,
})
Visuals:AddToggle({
    Text = "Names",
    Description = "Shows each player's display name",
    Icon = "Lucide:type",
    Default = true,
    Flag = "esp_names",
    Callback = function(v) S.espNames = v end,
})
Visuals:AddToggle({
    Text = "Distance",
    Description = "Shows how far away each player is",
    Icon = "Lucide:ruler",
    Default = true,
    Flag = "esp_dist",
    Callback = function(v) S.espDist = v end,
})
Visuals:AddToggle({
    Text = "Enemies Only",
    Description = "Hides your teammates from ESP",
    Icon = "Lucide:users",
    Default = false,
    Flag = "esp_team",
    Callback = function(v) S.espTeamCheck = v end,
})
Visuals:AddSlider({
    Text = "ESP Distance",
    Description = "Players farther away than this are not shown",
    Icon = "Lucide:radar",
    Min = 100,
    Max = 5000,
    Default = 2000,
    Increment = 50,
    Suffix = " studs",
    Flag = "esp_max",
    Callback = function(v) S.espMaxDist = v end,
})
Visuals:AddColorPicker({
    Text = "Enemy Color",
    Description = "The ESP color for enemies",
    Icon = "Lucide:palette",
    Default = S.espColor,
    Flag = "esp_color",
    Callback = function(c) S.espColor = c end,
})

-- Sends the status the old Debug tab showed to the hub's Debug Console.
task.spawn(function()
    local lastAuraStatus, lastAimMode
    while task.wait(0.5) and ctx:Alive() do
        local auraStatus = S.aura and S.auraStatus or nil
        if auraStatus and auraStatus ~= lastAuraStatus then
            ctx.Log("Kill Aura " .. auraStatus)
        end
        lastAuraStatus = auraStatus

        if S.aimMode and S.aimMode ~= lastAimMode then
            ctx.Log("Aimbot using " .. S.aimMode)
            lastAimMode = S.aimMode
        end

        if S.auraNote then
            ctx.Log(S.auraNote, "warn")
            S.auraNote = nil
        end
    end
end)
