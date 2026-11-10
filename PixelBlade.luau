-- PIXEL BLADE
-- Auto parry is built on the game's own client input module
-- (ReplicatedStorage.src.client.user_input). The game adds the Block component when
-- set_blocking(true) runs, and the parry window opens on that transition, so tapping
-- block repeatedly gives a fresh parry window for each incoming hit.

local ctx = ...
local task = ctx.task

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PathfindingService = game:GetService("PathfindingService")
local LocalPlayer = Players.LocalPlayer

local function getCharacter()
	return LocalPlayer.Character
end

local function getHumanoid()
	local character = LocalPlayer.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

local function getRootPart()
	local character = LocalPlayer.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end

local loggedOnce = {}
local function logOnce(key, message, level)
	if loggedOnce[key] then
		return
	end
	loggedOnce[key] = true
	ctx:Log("[PB] " .. message, level or "info")
end

-- The rig's Humanoid is always 100/100; the real health lives in the combat HUD vitals
-- figure (current/max labels), fed by the game's own Health component.
local function parseNumber(text)
	local cleaned = tostring(text):gsub("[^%d%.%-]", "")
	local value = tonumber(cleaned)
	return value
end

local function realHealth()
	local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
	local hud = playerGui and playerGui:FindFirstChild("combat_hud", true)
	if hud then
		local vitals = hud:FindFirstChild("vitals", true)
		local figure = vitals and vitals:FindFirstChild("figure", true)
		if figure then
			local current = figure:FindFirstChild("current", true)
			local max = figure:FindFirstChild("max", true)
			if current and max then
				local cur = parseNumber(current.Text)
				local mx = parseNumber(max.Text)
				if cur and mx and mx > 0 then
					return cur, mx
				end
			end
		end
	end
	local humanoid = getHumanoid()
	if humanoid then
		return humanoid.Health, humanoid.MaxHealth
	end
	return nil, nil
end

local function healthPercent()
	local cur, mx = realHealth()
	if not cur or not mx or mx <= 0 then
		return nil
	end
	return cur / mx * 100
end

ctx:Log("[PB] module loaded", "info")

local Settings = {
	AutoParry = false,
	ParryRange = 22,
	ParryInterval = 0.12,
	ParryOnWarning = true,
	DashOnWarning = true,
	DodgeProjectiles = false,
	DodgeRange = 30,
	AutoBanner = false,
	BannerPick = "Health Boost",
	AutoAttack = false,
	AttackRange = 18,
	AutoDash = false,
	AutoSkillOne = false,
	AutoSkillTwo = false,
	SkillInterval = 0.6,
	FaceTarget = false,
	AutoFarm = false,
	FarmStop = 6,
	FarmRange = 150,
	AggroFarm = false,
	AggroRange = 250,
	AggroHeight = 6,
	AutoPotion = false,
	PotionPercent = 40,
	AutoDanger = false,
	DangerPercent = 25,
	SpeedOn = false,
	Speed = 30,
	JumpOn = false,
	JumpPower = 100,
	InfiniteJump = false,
	InfiniteEnergy = false,
	EspEnemy = false,
	EspDistance = 250,
	DebugLogs = false,
}

---------------------------------------------------------------------
-- Game input bridge
---------------------------------------------------------------------

local inputModule = nil
local function getInput()
	if inputModule then
		return inputModule
	end
	local ok, module = pcall(function()
		return require(ReplicatedStorage.src.client.user_input)
	end)
	if ok and type(module) == "table" then
		inputModule = module
		return inputModule
	end
	return nil
end

-- Fall back to raw key events if the module ever moves.
local keyCodes = {
	Q = Enum.KeyCode.Q,
	E = Enum.KeyCode.E,
	R = Enum.KeyCode.R,
	F = Enum.KeyCode.F,
	One = Enum.KeyCode.One,
	W = Enum.KeyCode.W,
	A = Enum.KeyCode.A,
	S = Enum.KeyCode.S,
	D = Enum.KeyCode.D,
}

local function pressKey(keyCode)
	local ok = pcall(function()
		keypress(keyCode)
	end)
	if ok then
		task.wait(0.03)
		pcall(function()
			keyrelease(keyCode)
		end)
		return true
	end
	return pcall(function()
		local virtualInput = game:GetService("VirtualInputManager")
		virtualInput:SendKeyEvent(true, keyCode, false, game)
		task.wait(0.03)
		virtualInput:SendKeyEvent(false, keyCode, false, game)
	end)
end

local blockHeld = false
local function setBlocking(down)
	local input = getInput()
	if input then
		if blockHeld == down then
			return
		end
		blockHeld = down
		pcall(function()
			input.set_blocking(down)
		end)
		return
	end
	-- Fallback: F is the game's block key.
	if blockHeld == down then
		return
	end
	blockHeld = down
	pcall(function()
		if down then
			keypress(keyCodes.F)
		else
			keyrelease(keyCodes.F)
		end
	end)
end

local function clickMouse()
	local camera = workspace.CurrentCamera
	local size = camera and camera.ViewportSize or Vector2.new(1280, 720)
	local x = 8
	local y = math.floor(size.Y * 0.5)
	pcall(function()
		mousemoveabs(x, y)
	end)
	local ok = pcall(function()
		mouse1click()
	end)
	if ok then
		return true
	end
	return pcall(function()
		local virtualInput = game:GetService("VirtualInputManager")
		virtualInput:SendMouseButtonEvent(x, y, 0, true, game, 0)
		task.wait(0.03)
		virtualInput:SendMouseButtonEvent(x, y, 0, false, game, 0)
	end)
end

local attackHeld = false
local function setAttack(down)
	local input = getInput()
	if input then
		if attackHeld == down then
			return
		end
		attackHeld = down
		pcall(function()
			input.set_attack_held(down)
		end)
		return
	end
	-- Fallback: left mouse click is the game's attack bind.
	if down then
		clickMouse()
	else
		pcall(function()
			mouse1release()
		end)
	end
end

---------------------------------------------------------------------
-- Movement keys (the game reads WASD through its own Input package)
---------------------------------------------------------------------

local moveKeys = { W = false, A = false, S = false, D = false }

local function setMoveKey(name, down)
	if moveKeys[name] == down then
		return
	end
	moveKeys[name] = down
	local code = keyCodes[name]
	if down then
		local ok = pcall(function()
			keypress(code)
		end)
		if not ok then
			pcall(function()
				game:GetService("VirtualInputManager"):SendKeyEvent(true, code, false, game)
			end)
		end
	else
		local ok = pcall(function()
			keyrelease(code)
		end)
		if not ok then
			pcall(function()
				game:GetService("VirtualInputManager"):SendKeyEvent(false, code, false, game)
			end)
		end
	end
end

local function releaseMoveKeys()
	for name in pairs(moveKeys) do
		setMoveKey(name, false)
	end
end

---------------------------------------------------------------------
-- Enemy scanning
---------------------------------------------------------------------

local enemyCache = {}
local lastEnemyScanAt = 0

local NPC_MARKERS = {
	npc_nameplate = true,
	npc_quest_marker = true,
	PlayerNameTag = true,
	AboveHeadDialouge = true,
}

-- When an enemy is converted to your side the game recolours its name tag title to
-- Color3.fromRGB(0, 115, 207) and its health-bar fill to ally_health_fill_color
-- (79, 160, 255) instead of health_fill_color (255, 103, 103). Both are client-visible,
-- and the fill is re-evaluated every frame, so a conversion shows up immediately.
local FRIENDLY_TAG_COLOR = Color3.fromRGB(0, 115, 207)
local FRIENDLY_FILL_COLOR = Color3.fromRGB(79, 160, 255)

local function colourClose(a, b)
	return math.abs(a.R - b.R) < 0.03 and math.abs(a.G - b.G) < 0.03 and math.abs(a.B - b.B) < 0.03
end

local function isFriendlyEntity(model)
	local nameTag = model:FindFirstChild("EnemyNameTag", true)
	if nameTag then
		local title = nameTag:FindFirstChild("title", true)
		if title and title:IsA("TextLabel") and colourClose(title.TextColor3, FRIENDLY_TAG_COLOR) then
			return true
		end
	end
	local healthBar = model:FindFirstChild("EnemyHealthBar", true)
	if healthBar then
		local fill = healthBar:FindFirstChild("health_amount", true)
		if fill and fill:IsA("GuiObject") and colourClose(fill.BackgroundColor3, FRIENDLY_FILL_COLOR) then
			return true
		end
	end
	return false
end

local function isEnemyModel(model)
	if not model:IsA("Model") then
		return false
	end
	if Players:GetPlayerFromCharacter(model) then
		return false
	end
	if model == LocalPlayer.Character then
		return false
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false
	end
	if not model:FindFirstChild("HumanoidRootPart") then
		return false
	end
	-- Converted enemies must be excluded from every scan, including the farm fallback.
	if isFriendlyEntity(model) then
		return false
	end
	-- Lobby/map content (dealers, tutorial NPCs) lives under workspace.map; real enemies
	-- spawn straight into the world, e.g. Workspace.archer / Workspace.zombie.
	local ancestor = model.Parent
	while ancestor and ancestor ~= workspace do
		if ancestor.Name == "map" then
			return false
		end
		ancestor = ancestor.Parent
	end
	-- NPCs and players carry a nameplate/dialogue/name-tag billboard; enemies do not.
	for _, child in ipairs(model:GetDescendants()) do
		if child:IsA("BillboardGui") and NPC_MARKERS[child.Name] then
			return false
		end
	end
	return true
end

local function scanEnemies()
	local now = os.clock()
	if now - lastEnemyScanAt < 0.4 then
		return
	end
	lastEnemyScanAt = now
	local found = {}
	for _, descendant in ipairs(workspace:GetDescendants()) do
		if isEnemyModel(descendant) then
			found[#found + 1] = descendant
		end
	end
	enemyCache = found
end

local function nearestEnemy(maxDistance)
	local myRoot = getRootPart()
	if not myRoot then
		return nil
	end
	scanEnemies()
	local best, bestDistance = nil, math.huge
	for _, model in ipairs(enemyCache) do
		if model.Parent then
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			local root = model:FindFirstChild("HumanoidRootPart")
			if humanoid and root and humanoid.Health > 0 then
				local distance = (root.Position - myRoot.Position).Magnitude
				if distance <= maxDistance and distance < bestDistance then
					best, bestDistance = model, distance
				end
			end
		end
	end
	return best, bestDistance
end

-- The game draws EnemyNameTag / EnemyHealthBar on real enemies within 90 studs (nameplate
-- distance 75 + cull margin 15), and an AttackWarningIndicator while they wind up. Melee
-- range is well inside that, so requiring one of those markers means auto attack can only
-- ever swing at something the game itself treats as an enemy - never a friendly or NPC.
local function hasEnemyMarker(model)
	return model:FindFirstChild("EnemyNameTag", true) ~= nil
		or model:FindFirstChild("EnemyHealthBar", true) ~= nil
		or model:FindFirstChild("AttackWarningIndicator", true) ~= nil
end

local function nearestHostile(maxDistance)
	local myRoot = getRootPart()
	if not myRoot then
		return nil
	end
	scanEnemies()
	local best, bestDistance = nil, math.huge
	for _, model in ipairs(enemyCache) do
		if model.Parent and hasEnemyMarker(model) then
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			local root = model:FindFirstChild("HumanoidRootPart")
			if humanoid and root and humanoid.Health > 0 then
				local distance = (root.Position - myRoot.Position).Magnitude
				if distance <= maxDistance and distance < bestDistance then
					best, bestDistance = model, distance
				end
			end
		end
	end
	return best, bestDistance
end

---------------------------------------------------------------------
-- Combat steps
---------------------------------------------------------------------

-- The game spawns an "AttackWarningIndicator" billboard on the part where a telegraphed
-- enemy attack will land, so its presence is the real "attack is coming" signal. Parrying
-- on that instead of on proximity stops the constant block tapping while just standing
-- next to a passive enemy.
local warningCache = {}
local lastWarningScanAt = 0

local function scanAttackWarnings()
	local now = os.clock()
	if now - lastWarningScanAt < 0.1 then
		return
	end
	lastWarningScanAt = now
	local found = {}
	for _, descendant in ipairs(workspace:GetDescendants()) do
		if descendant.Name == "AttackWarningIndicator" then
			local part = descendant:IsA("BillboardGui") and descendant.Adornee or descendant.Parent
			if part and part:IsA("BasePart") then
				found[#found + 1] = part
			end
		end
	end
	warningCache = found
end

local function incomingAttackNear(maxDistance)
	local myRoot = getRootPart()
	if not myRoot then
		return false
	end
	scanAttackWarnings()
	for _, part in ipairs(warningCache) do
		if part.Parent and (part.Position - myRoot.Position).Magnitude <= maxDistance then
			return true
		end
	end
	return false
end

local nextParryAt = 0

local function autoParryStep()
	local enemy = nearestHostile(Settings.ParryRange)
	if not enemy then
		if blockHeld then
			setBlocking(false)
		end
		return
	end
	-- Only react to a telegraphed attack.
	if Settings.ParryOnWarning and not incomingAttackNear(Settings.ParryRange + 20) then
		if blockHeld then
			setBlocking(false)
		end
		return
	end
	-- Hold the block through the whole windup instead of tapping: the parry window opens on
	-- block start, and tapping could finish before the hit actually landed.
	setBlocking(true)
end

local function autoAttackStep()
	if dangerActive then
		setAttack(false)
		return
	end
	local myRoot = getRootPart()
	local enemy = nearestHostile(Settings.AttackRange)
	if not enemy or not myRoot then
		setAttack(false)
		return
	end
	local root = enemy:FindFirstChild("HumanoidRootPart")
	if not root then
		setAttack(false)
		return
	end
	-- Swings go where the character faces, so only attack with the enemy in front and
	-- turn toward it otherwise. Otherwise the swing lands on whatever friendly happens to
	-- be in front of the player.
	local toEnemy = root.Position - myRoot.Position
	local flat = Vector3.new(toEnemy.X, 0, toEnemy.Z)
	if flat.Magnitude < 0.1 then
		setAttack(true)
		return
	end
	local look = myRoot.CFrame.LookVector
	local facing = Vector3.new(look.X, 0, look.Z)
	local alignment = facing.Magnitude > 0.01 and facing.Unit:Dot(flat.Unit) or 0
	if alignment < 0.35 then
		setAttack(false)
		pcall(function()
			myRoot.CFrame = myRoot.CFrame:Lerp(
				CFrame.lookAt(myRoot.Position, myRoot.Position + flat.Unit),
				0.4
			)
		end)
		return
	end
	setAttack(true)
end

-- Some enemies shoot: look for anything fast heading at the player and sidestep it.
local function incomingProjectile(range)
	local myRoot = getRootPart()
	if not myRoot then
		return false
	end
	local parts = workspace:GetPartBoundsInRadius(myRoot.Position, range)
	for _, part in ipairs(parts) do
		local velocity = part.AssemblyLinearVelocity
		if velocity.Magnitude > 15 then
			local toMe = myRoot.Position - part.Position
			if toMe.Magnitude > 0.5 and toMe.Unit:Dot(velocity.Unit) > 0.75 then
				return true
			end
		end
	end
	return false
end

local nextDodgeAt = 0
local function dodgeProjectileStep()
	local now = os.clock()
	if now < nextDodgeAt then
		return
	end
	if not incomingProjectile(Settings.DodgeRange) then
		return
	end
	nextDodgeAt = now + 0.8
	-- Strafe sideways, then dash so the game's own movement carries us clear.
	setMoveKey("A", true)
	setMoveKey("D", false)
	pressKey(keyCodes.Q)
	task.delay(0.35, function()
		setMoveKey("A", false)
	end)
	logOnce("dodge_ok", "dodge: sidestepped an incoming projectile", "info")
end

local nextDashAt = 0
local function autoDashStep()
	local now = os.clock()
	if now < nextDashAt then
		return
	end
	-- Dash out of the way only when an attack is telegraphed, not on mere proximity.
	if Settings.DashOnWarning then
		if not incomingAttackNear(Settings.ParryRange + 12) then
			return
		end
	elseif not nearestHostile(Settings.ParryRange + 10) then
		return
	end
	nextDashAt = now + 1.2
	pressKey(keyCodes.Q)
end

local nextSkillAt = 0
local function autoSkillStep()
	local now = os.clock()
	if now < nextSkillAt then
		return
	end
	if not nearestEnemy(Settings.AttackRange) then
		return
	end
	nextSkillAt = now + Settings.SkillInterval
	if Settings.AutoSkillOne then
		pressKey(keyCodes.E)
	end
	if Settings.AutoSkillTwo then
		task.wait(0.05)
		pressKey(keyCodes.R)
	end
end

local faceConnection = nil
local function smoothFace()
	if faceConnection then
		return
	end
	faceConnection = game:GetService("RunService").Heartbeat:Connect(function()
		if not Settings.FaceTarget or not ctx:Alive() then
			faceConnection:Disconnect()
			faceConnection = nil
			return
		end
		local myRoot = getRootPart()
		local enemy = nearestEnemy(Settings.AttackRange)
		if not myRoot or not enemy then
			return
		end
		local root = enemy:FindFirstChild("HumanoidRootPart")
		if not root then
			return
		end
		local current = myRoot.CFrame
		local target = Vector3.new(root.Position.X, current.Position.Y, root.Position.Z)
		if (target - current.Position).Magnitude < 0.1 then
			return
		end
		myRoot.CFrame = current:Lerp(CFrame.lookAt(current.Position, target), 0.25)
	end)
end

local function faceStep()
	if Settings.FaceTarget then
		smoothFace()
	end
end

---------------------------------------------------------------------
-- Farm
---------------------------------------------------------------------

local farmConnection = nil

local function farmWalkTo(enemy)
	local myRoot = getRootPart()
	if not myRoot or not enemy then
		return
	end
	local root = enemy:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	local camera = workspace.CurrentCamera
	local toTarget = root.Position - myRoot.Position
	local flat = Vector3.new(toTarget.X, 0, toTarget.Z)
	if not camera or flat.Magnitude < 0.1 then
		return
	end
	local direction = flat.Unit
	local forward = camera.CFrame.LookVector
	local right = camera.CFrame.RightVector
	local forwardUnit = Vector3.new(forward.X, 0, forward.Z)
	local rightUnit = Vector3.new(right.X, 0, right.Z)
	local forwardAmount = forwardUnit.Magnitude > 0.01 and direction:Dot(forwardUnit.Unit) or 0
	local rightAmount = rightUnit.Magnitude > 0.01 and direction:Dot(rightUnit.Unit) or 0
	setMoveKey("W", forwardAmount > 0.25)
	setMoveKey("S", forwardAmount < -0.25)
	setMoveKey("D", rightAmount > 0.25)
	setMoveKey("A", rightAmount < -0.25)
end

local farmTarget = nil
local farmLastPos = nil
local farmLastProgressAt = 0
local farmLastLogAt = 0
local farmNoEnemySince = 0
local farmBlacklist = {}
local promptCache = {}
local lastPromptScanAt = 0

local function scanPrompts()
	local now = os.clock()
	if now - lastPromptScanAt < 3 then
		return
	end
	lastPromptScanAt = now
	local found = {}
	for _, descendant in ipairs(workspace:GetDescendants()) do
		if descendant:IsA("ProximityPrompt") and descendant.Enabled then
			local parent = descendant.Parent
			if parent and parent:IsA("BasePart") then
				-- Skip prompts attached to characters (revive/chest prompts live on
				-- HumanoidRootParts) so room progression only walks to real furniture.
				local owner = parent.Parent
				local isCharacterPart = owner ~= nil and owner:FindFirstChildOfClass("Humanoid") ~= nil
				if not isCharacterPart then
					found[#found + 1] = descendant
				end
			end
		end
	end
	promptCache = found
end

local function nearestPrompt(maxDistance)
	local myRoot = getRootPart()
	if not myRoot then
		return nil
	end
	scanPrompts()
	local best, bestDistance = nil, math.huge
	for _, prompt in ipairs(promptCache) do
		if prompt.Parent and prompt.Enabled then
			local parent = prompt.Parent
			local distance = (parent.Position - myRoot.Position).Magnitude
			if distance <= maxDistance and distance < bestDistance then
				best, bestDistance = prompt, distance
			end
		end
	end
	return best, bestDistance
end

local function pickFarmTarget()
	local myRoot = getRootPart()
	if not myRoot then
		return nil
	end
	local now = os.clock()
	local best, bestDistance = nil, math.huge
	-- Prefer something the game itself marks as an enemy; only fall back to the broader
	-- scan (distant, no nameplate yet) when nothing nearby is marked.
	local hostile, hostileDistance = nearestHostile(Settings.FarmRange)
	if hostile then
		best, bestDistance = hostile, hostileDistance
	else
		scanEnemies()
		for _, model in ipairs(enemyCache) do
			if model.Parent and (farmBlacklist[model] or 0) < now then
				local humanoid = model:FindFirstChildOfClass("Humanoid")
				local root = model:FindFirstChild("HumanoidRootPart")
				if humanoid and root and humanoid.Health > 0 then
					local distance = (root.Position - myRoot.Position).Magnitude
					if distance <= Settings.FarmRange and distance < bestDistance then
						best, bestDistance = model, distance
					end
				end
			end
		end
	end
	-- Hysteresis: two roughly equidistant enemies used to flip the target on every tick,
	-- which kept resetting the progress timer so the stuck recovery never fired.
	if farmTarget and farmTarget.Parent and best ~= farmTarget then
		local humanoid = farmTarget:FindFirstChildOfClass("Humanoid")
		local root = farmTarget:FindFirstChild("HumanoidRootPart")
		if humanoid and humanoid.Health > 0 and root and (farmBlacklist[farmTarget] or 0) < now then
			local currentDistance = (root.Position - myRoot.Position).Magnitude
			if currentDistance <= Settings.FarmRange and currentDistance <= bestDistance + 6 then
				return farmTarget, currentDistance
			end
		end
	end
	return best, bestDistance
end

local function walkTowardPoint(position)
	local myRoot = getRootPart()
	local camera = workspace.CurrentCamera
	if not myRoot or not camera then
		return
	end
	local flat = Vector3.new(position.X - myRoot.Position.X, 0, position.Z - myRoot.Position.Z)
	if flat.Magnitude < 0.1 then
		return
	end
	local chosen = flat.Unit
	-- This map gives PathfindingService NoPath, so steer around walls with a short
	-- raycast fan: take the first direction that is not blocked.
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { LocalPlayer.Character }
	local origin = myRoot.Position + Vector3.new(0, 1, 0)
	for _, offset in ipairs({ 0, 30, -30, 60, -60, 90, -90, 120, -120 }) do
		local rotated = (CFrame.Angles(0, math.rad(offset), 0) * CFrame.new(flat.Unit * 10)).Position
		local direction = Vector3.new(rotated.X, 0, rotated.Z)
		if direction.Magnitude > 0.01 then
			local result = workspace:Raycast(origin, direction.Unit * 8, params)
			if not result then
				chosen = direction.Unit
				break
			end
		end
	end
	local forward = camera.CFrame.LookVector
	local right = camera.CFrame.RightVector
	local forwardUnit = Vector3.new(forward.X, 0, forward.Z)
	local rightUnit = Vector3.new(right.X, 0, right.Z)
	local forwardAmount = forwardUnit.Magnitude > 0.01 and chosen:Dot(forwardUnit.Unit) or 0
	local rightAmount = rightUnit.Magnitude > 0.01 and chosen:Dot(rightUnit.Unit) or 0
	setMoveKey("W", forwardAmount > 0.25)
	setMoveKey("S", forwardAmount < -0.25)
	setMoveKey("D", rightAmount > 0.25)
	setMoveKey("A", rightAmount < -0.25)
end

local farmPath = nil
local farmWaypointIndex = 1
local farmPathTarget = nil
local farmLastRepathAt = 0
local farmStuckCount = 0
-- Set while health is critically low: the farm and attacks back off so the retreat can work.
local dangerActive = false
local dangerStartedAt = 0

local function clearFarmPath()
	farmPath = nil
	farmWaypointIndex = 1
	farmPathTarget = nil
	farmLastRepathAt = 0
end

local function buildFarmPath(targetPosition)
	local myRoot = getRootPart()
	if not myRoot then
		return false
	end
	local path = PathfindingService:CreatePath({
		AgentRadius = 3,
		AgentHeight = 5,
		AgentCanJump = true,
		AgentJumpHeight = 7,
		AgentMaxSlope = 45,
	})
	local ok = pcall(function()
		path:ComputeAsync(myRoot.Position, targetPosition)
	end)
	if not ok or path.Status ~= Enum.PathStatus.Success then
		clearFarmPath()
		return false
	end
	farmPath = path
	farmWaypointIndex = 2
	farmPathTarget = targetPosition
	return true
end

-- Walk the current path one waypoint at a time instead of beelining into a wall.
local function farmWalkPath()
	local myRoot = getRootPart()
	local humanoid = getHumanoid()
	if not myRoot or not farmPath then
		return false
	end
	local waypoints = farmPath:GetWaypoints()
	if not waypoints or farmWaypointIndex > #waypoints then
		clearFarmPath()
		return false
	end
	local waypoint = waypoints[farmWaypointIndex]
	if waypoint.Action == Enum.PathWaypointAction.Jump and humanoid then
		humanoid.Jump = true
	end
	local flat = Vector3.new(waypoint.Position.X - myRoot.Position.X, 0, waypoint.Position.Z - myRoot.Position.Z)
	if flat.Magnitude < 3 then
		farmWaypointIndex = farmWaypointIndex + 1
		return true
	end
	walkTowardPoint(waypoint.Position)
	return true
end

local function autoFarmStep()
	local myRoot = getRootPart()
	local humanoid = getHumanoid()
	if not myRoot or not humanoid then
		return
	end
	local now = os.clock()
	if dangerActive then
		releaseMoveKeys()
		return
	end
	if farmLastPos and (myRoot.Position - farmLastPos).Magnitude > 1.5 then
		farmLastPos = myRoot.Position
		farmLastProgressAt = now
	end

	local enemy, distance = pickFarmTarget()
	if not enemy or not distance then
		releaseMoveKeys()
		farmTarget = nil
		clearFarmPath()
		if farmNoEnemySince == 0 then
			farmNoEnemySince = now
		end
		-- Nothing left to kill: walk to the nearest interactable so the run can progress
		-- into the next room instead of standing still.
		if now - farmNoEnemySince > 2 then
			local prompt, promptDistance = nearestPrompt(200)
			if prompt and promptDistance then
				if promptDistance > 8 then
					walkTowardPoint(prompt.Parent.Position)
				else
					releaseMoveKeys()
					pcall(function()
						fireproximityprompt(prompt)
					end)
				end
				if now - farmLastLogAt > 5 then
					farmLastLogAt = now
					ctx:Log(string.format("[PB] auto farm: no enemies, heading to %s (%.0f studs)", prompt.Parent.Name, promptDistance), "info")
				end
			end
		end
		return
	end
	farmNoEnemySince = 0

	-- Judge progress on the horizontal distance: these rooms stack floors, and a 3D
	-- distance keeps reading "far" when the enemy is directly below on the next level.
	local enemyRootPart = enemy:FindFirstChild("HumanoidRootPart")
	local flatDistance = distance
	if enemyRootPart then
		local delta = Vector3.new(
			enemyRootPart.Position.X - myRoot.Position.X,
			0,
			enemyRootPart.Position.Z - myRoot.Position.Z
		)
		flatDistance = delta.Magnitude
	end

	-- The enemy is on another floor (rooms stack levels). Walking cannot fix a vertical
	-- gap, so drop straight onto the enemy's own floor.
	if enemyRootPart then
		local verticalGap = math.abs(enemyRootPart.Position.Y - myRoot.Position.Y)
		if verticalGap > 12 and flatDistance < Settings.FarmStop + 8 then
			local rayParams = RaycastParams.new()
			rayParams.FilterType = Enum.RaycastFilterType.Exclude
			rayParams.FilterDescendantsInstances = { LocalPlayer.Character }
			local floor = workspace:Raycast(enemyRootPart.Position + Vector3.new(0, 6, 0), Vector3.new(0, -30, 0), rayParams)
			local landing = floor and floor.Position or enemyRootPart.Position
			pcall(function()
				myRoot.CFrame = CFrame.new(landing + Vector3.new(0, 3, 0))
			end)
			ctx:Log("[PB] auto farm: dropped to the enemy's floor", "info")
			return
		end
	end

	if enemy ~= farmTarget then
		farmTarget = enemy
		farmLastPos = myRoot.Position
		farmLastProgressAt = now
		farmStuckCount = 0
		clearFarmPath()
	elseif now - farmLastProgressAt > 1.5 and distance > Settings.FarmStop then
		-- Stuck against geometry: drop the path, hop, and re-plan before giving up on the
		-- target. Only blacklist it after several failed re-plans.
		farmStuckCount = farmStuckCount + 1
		farmLastProgressAt = now
		clearFarmPath()
		-- Walking cannot get out of these room corners, so jump straight to the target
		-- rather than hopping forward a few studs at a time.
		local enemyRoot = enemy:FindFirstChild("HumanoidRootPart")
		if enemyRoot then
			local toEnemy = enemyRoot.Position - myRoot.Position
			toEnemy = Vector3.new(toEnemy.X, 0, toEnemy.Z)
			local destination = enemyRoot.Position
			if toEnemy.Magnitude > 0.1 then
				destination = enemyRoot.Position - toEnemy.Unit * Settings.FarmStop
			end
			local rayParams = RaycastParams.new()
			rayParams.FilterType = Enum.RaycastFilterType.Exclude
			rayParams.FilterDescendantsInstances = { LocalPlayer.Character }
			-- Cast from just above the enemy's own height so we land on ITS floor, not on
			-- the level above it.
			local floor = workspace:Raycast(
				enemyRoot.Position + Vector3.new(0, 6, 0),
				Vector3.new(0, -30, 0),
				rayParams
			)
			local landing = floor and floor.Position or enemyRoot.Position
			pcall(function()
				myRoot.CFrame = CFrame.new(landing + Vector3.new(0, 3, 0))
			end)
			ctx:Log("[PB] auto farm: teleported to the target", "info")
		end
		if humanoid then
			humanoid.Jump = true
		end
		if farmStuckCount >= 3 then
			farmBlacklist[enemy] = now + 6
			farmTarget = nil
			farmLastPos = nil
			farmStuckCount = 0
			releaseMoveKeys()
			ctx:Log("[PB] auto farm: stuck on " .. tostring(enemy.Name) .. ", switching target", "warn")
		else
			ctx:Log("[PB] auto farm: stuck, re-planning the path", "warn")
		end
		return
	end

	if distance > Settings.FarmStop then
		local enemyRoot = enemy:FindFirstChild("HumanoidRootPart")
		if enemyRoot then
			local targetPos = enemyRoot.Position
			local needsRepath = not farmPath
				or (farmPathTarget and (targetPos - farmPathTarget).Magnitude > 10)
				or now - farmLastRepathAt > 1.5
			if needsRepath then
				farmLastRepathAt = now
				buildFarmPath(targetPos)
			end
			if not (farmPath and farmWalkPath()) then
				-- Pathfinding unavailable here: walk straight at it as a last resort.
				farmWalkTo(enemy)
			end
		else
			farmWalkTo(enemy)
		end
	else
		releaseMoveKeys()
	end

	if now - farmLastLogAt > 5 then
		farmLastLogAt = now
		ctx:Log(string.format("[PB] auto farm: target %s at %.0f studs", tostring(enemy.Name), distance), "info")
	end
end

---------------------------------------------------------------------
-- Aggressive farm: hover above the target instead of walking to it
---------------------------------------------------------------------

local aggroTarget = nil
local nextAggroAt = 0
local lastHealthLogAt = 0
local lastLoggedHealth = nil
local aggroDangerLogged = false

-- While hovering, ground-AoE and ranged attacks still connect, so lift clear of the
-- telegraph and keep a potion topped up.
local lastAggroPotionAt = 0
local aggroDodgeUntil = 0
local aggroDodgeLogged = false

local function aggressiveFarmStep()
	local myRoot = getRootPart()
	local humanoid = getHumanoid()
	if not myRoot or not humanoid or humanoid.Health <= 0 then
		return
	end
	local healthPercentNow = humanoid.Health / math.max(humanoid.MaxHealth, 1) * 100
	local now = os.clock()
	-- Report the REAL health from the HUD vitals, plus any sudden drop.
	local currentHp, maxHp = realHealth()
	local hpPercent = healthPercent() or healthPercentNow
	if lastLoggedHealth and lastLoggedHealth - hpPercent >= 8 then
		ctx:Log(
			string.format(
				"[PB] hp dropped %.0f%% -> %.0f%% while hovering %.0f studs above %s",
				lastLoggedHealth,
				hpPercent,
				Settings.AggroHeight,
				tostring(aggroTarget and aggroTarget.Name or "none")
			),
			"warn"
		)
		lastLoggedHealth = hpPercent
	end
	if now - lastHealthLogAt >= 1 then
		lastHealthLogAt = now
		lastLoggedHealth = hpPercent
		ctx:Log(
			string.format(
				"[PB] hp %.0f/%.0f (%.0f%%) | hovering %.0f above %s",
				currentHp or -1,
				maxHp or -1,
				hpPercent,
				Settings.AggroHeight,
				tostring(aggroTarget and aggroTarget.Name or "none")
			),
			"info"
		)
	end
	-- While the panic retreat has us in danger mode, stop attacking so it can escape.
	if dangerActive then
		setAttack(false)
		if not aggroDangerLogged then
			aggroDangerLogged = true
			ctx:Log(string.format("[PB] aggressive farm paused at %.0f%% health", healthPercent), "warn")
		end
		return
	end
	aggroDangerLogged = false
	-- Hold the current target until it dies, then move to the next one.
	if aggroTarget then
		local current = aggroTarget:FindFirstChildOfClass("Humanoid")
		if not aggroTarget.Parent or not current or current.Health <= 0 then
			aggroTarget = nil
		end
	end
	if not aggroTarget then
		local enemy = nearestHostile(Settings.AggroRange)
		if not enemy then
			enemy = nearestEnemy(Settings.AggroRange)
		end
		aggroTarget = enemy
	end
	if not aggroTarget then
		setAttack(false)
		releaseMoveKeys()
		return
	end
	local enemyRoot = aggroTarget:FindFirstChild("HumanoidRootPart")
	if not enemyRoot then
		aggroTarget = nil
		return
	end
	if now < nextAggroAt then
		return
	end
	nextAggroAt = now + 0.2
	-- Drink automatically when hurt, whether or not Auto Potion is on.
	if hpPercent <= Settings.PotionPercent and now - lastAggroPotionAt > 3 then
		lastAggroPotionAt = now
		tryDrinkPotion("aggressive farm")
		ctx:Log(string.format("[PB] aggressive farm: drank a potion at %.0f%%", hpPercent), "info")
	end
	-- A telegraph means an AoE/ranged hit is about to land: rise clear of it, then drop
	-- back down to melee height.
	if incomingAttackNear(Settings.AggroHeight + 25) then
		aggroDodgeUntil = now + 0.6
		if not aggroDodgeLogged then
			aggroDodgeLogged = true
			ctx:Log("[PB] aggressive farm: lifted clear of an incoming attack", "warn")
		end
	end
	local hoverHeight = Settings.AggroHeight
	if now < aggroDodgeUntil then
		hoverHeight = Settings.AggroHeight + 22
	else
		aggroDodgeLogged = false
	end
	pcall(function()
		myRoot.CFrame = CFrame.new(enemyRoot.Position + Vector3.new(0, hoverHeight, 0))
	end)
	setAttack(true)
	logOnce("aggro_ok", "aggressive farm: hovering above the target", "info")
end

---------------------------------------------------------------------
-- Player
---------------------------------------------------------------------

local function applySpeed()
	local humanoid = getHumanoid()
	if humanoid and humanoid.WalkSpeed ~= Settings.Speed then
		humanoid.WalkSpeed = Settings.Speed
	end
end

local function applyJump()
	local humanoid = getHumanoid()
	if humanoid and humanoid.UseJumpPower and humanoid.JumpPower ~= Settings.JumpPower then
		humanoid.JumpPower = Settings.JumpPower
	end
end

local function infiniteJumpStep()
	local humanoid = getHumanoid()
	if humanoid and humanoid:GetState() == Enum.HumanoidStateType.Freefall then
		local input = getInput()
		if input then
			pcall(function()
				input.set_jump_held(true)
			end)
		else
			pcall(function()
				humanoid.Jump = true
			end)
		end
	end
end

-- Potion stock lives in the combat HUD as "xN"; drinking with none left does nothing, so
-- report that instead of failing silently.
local noPotionLogged = false

local function potionCount()
	local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
	local hud = playerGui and playerGui:FindFirstChild("combat_hud", true)
	local button = hud and hud:FindFirstChild("PotionOne", true)
	local slot = button and button:FindFirstChild("slot", true)
	local count = slot and slot:FindFirstChild("count", true)
	if count then
		local digits = tostring(count.Text):gsub("[^%d]", "")
		return tonumber(digits) or 0
	end
	return nil
end

-- Drinking goes through the game's own input signal; pressing the number key only works
-- when the window has focus, which is why the key-only version did nothing.
local function usePotion(slot)
	local input = getInput()
	if input and input.use_potion then
		local ok = pcall(function()
			input.use_potion:Fire(slot or 1)
		end)
		if ok then
			return true
		end
	end
	return pressKey(keyCodes.One)
end

local function tryDrinkPotion(reason)
	local count = potionCount()
	if count == 0 then
		if not noPotionLogged then
			noPotionLogged = true
			ctx:Log("[PB] potion: none left in slot 1 - " .. tostring(reason), "warn")
		end
		return false
	end
	noPotionLogged = false
	usePotion(1)
	return true
end

local nextPotionAt = 0
local function autoPotionStep()
	local now = os.clock()
	if now < nextPotionAt then
		return
	end
	local humanoid = getHumanoid()
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	local percent = healthPercent()
	if not percent or percent > Settings.PotionPercent then
		return
	end
	nextPotionAt = now + 2
	tryDrinkPotion("auto potion")
	logOnce("potion_ok", "auto potion: drinking while low", "info")
end

local nextDangerAt = 0
local dangerLogged = false

local function dangerStep()
	local humanoid = getHumanoid()
	local myRoot = getRootPart()
	if not humanoid or not myRoot or humanoid.Health <= 0 then
		return
	end
	local percent = healthPercent() or (humanoid.Health / math.max(humanoid.MaxHealth, 1) * 100)
	if percent <= Settings.DangerPercent and potionCount() == 0 then
		-- Nothing to heal with, so retreating only bounces us between pause and teleport.
		-- Keep fighting: killing the room is the only way out.
		dangerActive = false
		dangerStartedAt = 0
		logOnce("danger_nopotion", "danger: no potions left, fighting instead of retreating", "warn")
		return
	end
	if percent <= Settings.DangerPercent then
		if not dangerActive then
			dangerStartedAt = os.clock()
		end
		dangerActive = true
	elseif percent >= Settings.DangerPercent + 25 then
		dangerActive = false
		dangerLogged = false
		dangerStartedAt = 0
	end
	-- With no potions and no regeneration the escape can never succeed. Standing still
	-- keeps us in the fight but not healing, which deadlocks the farm forever, so give up
	-- after a few seconds and let it fight again.
	if dangerActive and dangerStartedAt > 0 and os.clock() - dangerStartedAt > 6 then
		dangerActive = false
		dangerLogged = false
		dangerStartedAt = 0
		ctx:Log("[PB] danger: no recovery available, resuming the fight", "warn")
	end
	if not dangerActive then
		return
	end
	local now = os.clock()
	if now < nextDangerAt then
		return
	end
	nextDangerAt = now + 1.2
	tryDrinkPotion("panic retreat")
	-- Get away from whatever is hitting us so the potion can actually tick.
	local enemy = nearestHostile(Settings.FarmRange)
	if enemy then
		local enemyRoot = enemy:FindFirstChild("HumanoidRootPart")
		if enemyRoot then
			local away = myRoot.Position - enemyRoot.Position
			away = Vector3.new(away.X, 0, away.Z)
			if away.Magnitude > 0.1 then
				local destination = myRoot.Position + away.Unit * 45
				local rayParams = RaycastParams.new()
				rayParams.FilterType = Enum.RaycastFilterType.Exclude
				rayParams.FilterDescendantsInstances = { LocalPlayer.Character }
				local floor = workspace:Raycast(destination + Vector3.new(0, 40, 0), Vector3.new(0, -120, 0), rayParams)
				local landing = floor and floor.Position or destination
				pcall(function()
					myRoot.CFrame = CFrame.new(landing + Vector3.new(0, 3, 0))
				end)
			end
		end
	end
	if not dangerLogged then
		dangerLogged = true
		ctx:Log(string.format("[PB] danger: retreated and drank a potion at %.0f%% health", percent), "warn")
	end
end

---------------------------------------------------------------------
-- ESP
---------------------------------------------------------------------

local espEntries = {}

local function createEsp(model, part, color, text)
	local highlight = Instance.new("Highlight")
	highlight.Adornee = part
	highlight.FillColor = color
	highlight.FillTransparency = 0.6
	highlight.OutlineColor = color
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Parent = part

	local gui = Instance.new("BillboardGui")
	gui.Adornee = part
	gui.Size = UDim2.new(0, 140, 0, 40)
	gui.StudsOffset = Vector3.new(0, 3, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 1000

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 1, 0)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 13
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.2
	label.Text = text
	label.Parent = gui

	gui.Parent = part
	return { Highlight = highlight, Gui = gui, Label = label }
end

local function espStep()
	local myRoot = getRootPart()
	if not myRoot then
		return
	end
	scanEnemies()
	local visible = {}
	for _, model in ipairs(enemyCache) do
		if model.Parent then
			local part = model:FindFirstChild("HumanoidRootPart")
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			if part and humanoid and humanoid.Health > 0 then
				local distance = (part.Position - myRoot.Position).Magnitude
				if distance <= Settings.EspDistance then
					local text = string.format("%s\n%d HP  %d studs", model.Name, math.ceil(humanoid.Health), math.floor(distance))
					visible[model] = true
					local entry = espEntries[model]
					if not entry then
						entry = createEsp(model, part, Color3.fromRGB(255, 90, 90), text)
						espEntries[model] = entry
					end
					entry.Gui.Adornee = part
					entry.Label.Text = text
				end
			end
		end
	end
	for model, entry in pairs(espEntries) do
		if not visible[model] then
			entry.Gui:Destroy()
			entry.Highlight:Destroy()
			espEntries[model] = nil
		end
	end
end

---------------------------------------------------------------------
-- Auto banner select
-- Clicking the offered card is the only path that both picks the banner AND lets the
-- client close its picker: the card handler fires banner_intents.pick_banner, which the
-- banner_picker system then turns into network.select_banner plus its own UI teardown.
-- Firing the remote directly picks server-side but leaves the GUI on screen.
---------------------------------------------------------------------

local function findBannerPicker()
	local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
	if not playerGui then
		return nil
	end
	local direct = playerGui:FindFirstChild("banner_picker", true)
	if direct then
		return direct
	end
	for _, descendant in ipairs(playerGui:GetDescendants()) do
		if descendant:IsA("ScreenGui") and descendant.Name:lower():find("banner", 1, true) then
			return descendant
		end
	end
	return nil
end

-- Executor signal firing does not cross script contexts reliably here, so click the card
-- with a real mouse event at its screen position: that runs the game's own handler, which
-- picks the banner and tears its picker down.
local function clickBannerCard(screen)
	for _, descendant in ipairs(screen:GetDescendants()) do
		if descendant:IsA("TextButton") and descendant.Visible then
			local size = descendant.AbsoluteSize
			if size.X > 0 and size.Y > 0 then
				local center = descendant.AbsolutePosition + size * 0.5
				pcall(function()
					mousemoveabs(center.X, center.Y)
				end)
				task.wait(0.05)
				local ok = pcall(function()
					mouse1click()
				end)
				if not ok then
					pcall(function()
						local virtualInput = game:GetService("VirtualInputManager")
						virtualInput:SendMouseButtonEvent(center.X, center.Y, 0, true, game, 0)
						task.wait(0.05)
						virtualInput:SendMouseButtonEvent(center.X, center.Y, 0, false, game, 0)
					end)
				end
				return descendant
			end
		end
	end
	return nil
end

local BANNER_ID_BY_NAME = {
	["Thorns"] = "Thorns",
	["Element Circle"] = "ElementCircle",
	["Health Boost"] = "HealthBoost",
	["Critical Boost"] = "CriticalBoost",
	["Flame Element"] = "FlameElement",
	["Frost Element"] = "FrostElement",
	["Poison Element"] = "PoisonElement",
	["Spirit Capacity"] = "SpiritCapacity",
	["Rage Spirits"] = "RageSpirits",
	["Life Steal"] = "LifeSteal",
	["Stamina"] = "Stamina",
	["Agility"] = "Agility",
	["Recovery"] = "Recovery",
}

local function fireBanner(id)
	local ok, network = pcall(function()
		return require(ReplicatedStorage.src.network)
	end)
	if not ok or type(network) ~= "table" or not network.select_banner then
		return false
	end
	pcall(function()
		network.select_banner.fire(id)
	end)
	return true
end

-- Any banner the picker is showing, in no particular order.
local function offeredBannerIds(screen)
	local offered = {}
	for _, descendant in ipairs(screen:GetDescendants()) do
		if descendant:IsA("TextLabel") and descendant.Visible then
			local text = string.upper(tostring(descendant.Text))
			for name, id in pairs(BANNER_ID_BY_NAME) do
				if text:find(string.upper(name), 1, true) then
					offered[id] = true
				end
			end
		end
	end
	return offered
end

local function closePicker(screen)
	pcall(function()
		if screen:IsA("ScreenGui") then
			screen.Enabled = false
		else
			screen.Visible = false
		end
	end)
end

local nextBannerAt = 0

local function autoBannerStep()
	local now = os.clock()
	if now < nextBannerAt then
		return
	end
	local screen = findBannerPicker()
	if not screen then
		return
	end
	if screen:IsA("ScreenGui") and not screen.Enabled then
		return
	end
	-- Mouse clicks never reach the cards in this environment (mousemoveabs/mouse1click are
	-- no-ops here), so pick an offered banner through the remote and close the picker
	-- ourselves. Leaving it open blocks the run.
	local offered = offeredBannerIds(screen)
	local choice = nil
	for id in pairs(offered) do
		choice = id
		break
	end
	if not choice then
		-- Card labels unreadable: still send a valid id so something is chosen.
		choice = "HealthBoost"
	end
	fireBanner(choice)
	closePicker(screen)
	nextBannerAt = now + 2
	ctx:Log("[PB] banner: picked " .. tostring(choice) .. " and closed the picker", "info")
end

---------------------------------------------------------------------
-- Debug
---------------------------------------------------------------------

local function debugStep()
	local humanoid = getHumanoid()
	local enemy, distance = nearestEnemy(Settings.FarmRange)
	local percent = humanoid and math.floor(humanoid.Health / math.max(humanoid.MaxHealth, 1) * 100) or -1
	ctx:Log(
		string.format(
			"[PB][debug] parry=%s attack=%s dash=%s farm=%s | hp=%d%% | enemy=%s dist=%s",
			tostring(Settings.AutoParry),
			tostring(Settings.AutoAttack),
			tostring(Settings.AutoDash),
			tostring(Settings.AutoFarm),
			percent,
			enemy and enemy.Name or "none",
			distance and string.format("%.0f", distance) or "-"
		),
		"info"
	)
end

---------------------------------------------------------------------
-- Infinite energy
-- Skills spend stamina through skill_energy_util.try_spend_for, which subtracts from the
-- player's Energy component. Wrapping that function to report success without spending
-- keeps the bar full without needing to reach into the ECS world.
---------------------------------------------------------------------

local energyPatched = false
local originalTrySpendFor = nil
local originalCost = nil

local function setInfiniteEnergy(enabled)
	local ok, skillEnergy = pcall(function()
		return require(ReplicatedStorage.src.skill_energy_util)
	end)
	if not ok or type(skillEnergy) ~= "table" then
		logOnce("energy_missing", "skill_energy_util not available", "warn")
		return false
	end
	if enabled then
		if energyPatched then
			return true
		end
		originalTrySpendFor = skillEnergy.try_spend_for
		originalCost = skillEnergy.cost
		skillEnergy.try_spend_for = function(world, entity, cost)
			if Settings.InfiniteEnergy then
				return true
			end
			if originalTrySpendFor then
				return originalTrySpendFor(world, entity, cost)
			end
			return true
		end
		-- Every "Out of Energy" check compares Energy.value against this cost, including
		-- the ability slot, dash, blade leap and spear charge paths that never call
		-- try_spend_for. A zero cost satisfies all of them and deducts nothing.
		skillEnergy.cost = function(world, entity, baseCost)
			if Settings.InfiniteEnergy then
				return 0
			end
			if originalCost then
				return originalCost(world, entity, baseCost)
			end
			return baseCost
		end
		energyPatched = true
		ctx:Log("[PB] infinite energy enabled", "info")
		return true
	end
	if energyPatched and originalTrySpendFor then
		skillEnergy.try_spend_for = originalTrySpendFor
		if originalCost then
			skillEnergy.cost = originalCost
		end
		energyPatched = false
		originalTrySpendFor = nil
		originalCost = nil
		ctx:Log("[PB] infinite energy disabled", "info")
	end
	return true
end

---------------------------------------------------------------------
-- UI
---------------------------------------------------------------------

local Player = ctx:SubTab("Player", "Lucide:user")
local Combat = ctx:SubTab("Combat", "Lucide:swords")
local Farm = ctx:SubTab("Farm", "Lucide:coins")
local Visuals = ctx:SubTab("Visuals", "Lucide:eye")
local DebugTab = ctx:SubTab("Debug", "Lucide:bug")

Player:AddSection("Movement", "Lucide:footprints")
Player:AddToggle({
	Text = "Speed Boost",
	Description = "Overrides your walk speed",
	Icon = "Lucide:gauge",
	Default = false,
	Flag = "pb_speed_on",
	Callback = function(value)
		Settings.SpeedOn = value
	end,
})
Player:AddSlider({
	Text = "Walk Speed",
	Icon = "Lucide:footprints",
	Min = 8,
	Max = 120,
	Default = 30,
	Increment = 1,
	Flag = "pb_speed",
	Callback = function(value)
		Settings.Speed = value
	end,
})
Player:AddToggle({
	Text = "Jump Boost",
	Description = "Overrides your jump power",
	Icon = "Lucide:arrow-up",
	Default = false,
	Flag = "pb_jump_on",
	Callback = function(value)
		Settings.JumpOn = value
	end,
})
Player:AddSlider({
	Text = "Jump Power",
	Icon = "Lucide:arrow-up",
	Min = 50,
	Max = 300,
	Default = 100,
	Increment = 5,
	Flag = "pb_jump",
	Callback = function(value)
		Settings.JumpPower = value
	end,
})
Player:AddToggle({
	Text = "Infinite Jump",
	Description = "Keeps requesting jumps while airborne",
	Icon = "Lucide:chevrons-up",
	Default = false,
	Flag = "pb_infinite_jump",
	Callback = function(value)
		Settings.InfiniteJump = value
	end,
})

Player:AddToggle({
	Text = "Infinite Energy",
	Description = "Skills never consume stamina",
	Icon = "Lucide:battery-charging",
	Default = false,
	Flag = "pb_infinite_energy",
	Callback = function(value)
		Settings.InfiniteEnergy = value
		setInfiniteEnergy(value)
	end,
})

Player:AddSection("Survival", "Lucide:heart-pulse")
Player:AddToggle({
	Text = "Panic Retreat",
	Description = "When health gets critical: drink a potion and teleport away",
	Icon = "Lucide:heart-crack",
	Default = false,
	Flag = "pb_danger",
	Callback = function(value)
		Settings.AutoDanger = value
		if not value then
			dangerActive = false
		end
	end,
})
Player:AddSlider({
	Text = "Panic HP",
	Description = "Health percent that triggers the retreat",
	Icon = "Lucide:gauge",
	Min = 10,
	Max = 60,
	Default = 25,
	Increment = 5,
	Suffix = "%",
	Flag = "pb_danger_pct",
	Callback = function(value)
		Settings.DangerPercent = value
	end,
})
Player:AddToggle({
	Text = "Auto Potion",
	Description = "Drinks potion slot 1 when health is low",
	Icon = "Lucide:flask-conical",
	Default = false,
	Flag = "pb_auto_potion",
	Callback = function(value)
		Settings.AutoPotion = value
	end,
})
Player:AddSlider({
	Text = "Potion HP",
	Description = "Health percent that triggers the potion",
	Icon = "Lucide:gauge",
	Min = 10,
	Max = 90,
	Default = 40,
	Increment = 5,
	Suffix = "%",
	Flag = "pb_potion_pct",
	Callback = function(value)
		Settings.PotionPercent = value
	end,
})

Combat:AddSection("Parry", "Lucide:shield")
Combat:AddToggle({
	Text = "Auto Parry",
	Description = "Taps block so every incoming hit lands inside a parry window",
	Icon = "Lucide:shield-check",
	Default = false,
	Flag = "pb_auto_parry",
	Callback = function(value)
		Settings.AutoParry = value
	end,
})
Combat:AddSlider({
	Text = "Parry Range",
	Description = "Only parry when an enemy is this close",
	Icon = "Lucide:radar",
	Min = 5,
	Max = 60,
	Default = 22,
	Increment = 1,
	Suffix = " studs",
	Flag = "pb_parry_range",
	Callback = function(value)
		Settings.ParryRange = value
	end,
})
Combat:AddSlider({
	Text = "Parry Rate",
	Description = "Seconds between block taps (lower = more windows)",
	Icon = "Lucide:timer",
	Min = 0.06,
	Max = 0.4,
	Default = 0.12,
	Increment = 0.02,
	Suffix = "s",
	Flag = "pb_parry_rate",
	Callback = function(value)
		Settings.ParryInterval = value
	end,
})

Combat:AddToggle({
	Text = "Parry On Warning",
	Description = "Only parry when a telegraphed attack is landing nearby",
	Icon = "Lucide:alert-triangle",
	Default = true,
	Flag = "pb_parry_warning",
	Callback = function(value)
		Settings.ParryOnWarning = value
	end,
})

Combat:AddToggle({
	Text = "Dodge Projectiles",
	Description = "Sidesteps and dashes when something fast is flying at you",
	Icon = "Lucide:move-horizontal",
	Default = false,
	Flag = "pb_dodge",
	Callback = function(value)
		Settings.DodgeProjectiles = value
	end,
})
Combat:AddSlider({
	Text = "Dodge Range",
	Description = "How far away incoming projectiles are noticed",
	Icon = "Lucide:radar",
	Min = 10,
	Max = 60,
	Default = 30,
	Increment = 2,
	Suffix = " studs",
	Flag = "pb_dodge_range",
	Callback = function(value)
		Settings.DodgeRange = value
	end,
})

Combat:AddSection("Attack", "Lucide:swords")
Combat:AddToggle({
	Text = "Auto Attack",
	Description = "Holds the attack input while an enemy is in range",
	Icon = "Lucide:swords",
	Default = false,
	Flag = "pb_auto_attack",
	Callback = function(value)
		Settings.AutoAttack = value
	end,
})
Combat:AddSlider({
	Text = "Attack Range",
	Icon = "Lucide:radar",
	Min = 5,
	Max = 40,
	Default = 18,
	Increment = 1,
	Suffix = " studs",
	Flag = "pb_attack_range",
	Callback = function(value)
		Settings.AttackRange = value
	end,
})
Combat:AddToggle({
	Text = "Auto Dash",
	Description = "Presses Q when an enemy is near",
	Icon = "Lucide:wind",
	Default = false,
	Flag = "pb_auto_dash",
	Callback = function(value)
		Settings.AutoDash = value
	end,
})
Combat:AddToggle({
	Text = "Dash On Warning",
	Description = "Only dash when an attack is telegraphed",
	Icon = "Lucide:alert-triangle",
	Default = true,
	Flag = "pb_dash_warning",
	Callback = function(value)
		Settings.DashOnWarning = value
	end,
})
Combat:AddToggle({
	Text = "Face Nearest Enemy",
	Description = "Smoothly turns toward the closest enemy",
	Icon = "Lucide:crosshair",
	Default = false,
	Flag = "pb_face",
	Callback = function(value)
		Settings.FaceTarget = value
	end,
})

Combat:AddSection("Skills", "Lucide:sparkles")
Combat:AddToggle({
	Text = "Auto Skill 1",
	Description = "Casts skill one (E) on enemies",
	Icon = "Lucide:zap",
	Default = false,
	Flag = "pb_skill_one",
	Callback = function(value)
		Settings.AutoSkillOne = value
	end,
})
Combat:AddToggle({
	Text = "Auto Skill 2",
	Description = "Casts skill two (R) on enemies",
	Icon = "Lucide:zap",
	Default = false,
	Flag = "pb_skill_two",
	Callback = function(value)
		Settings.AutoSkillTwo = value
	end,
})
Combat:AddSlider({
	Text = "Skill Interval",
	Icon = "Lucide:timer",
	Min = 0.2,
	Max = 5,
	Default = 0.6,
	Increment = 0.1,
	Suffix = "s",
	Flag = "pb_skill_interval",
	Callback = function(value)
		Settings.SkillInterval = value
	end,
})

Combat:AddSection("Banner", "Lucide:flag")
Combat:AddToggle({
	Text = "Auto Banner",
	Description = "Clicks whichever banner cards the picker offers",
	Icon = "Lucide:flag",
	Default = false,
	Flag = "pb_auto_banner",
	Callback = function(value)
		Settings.AutoBanner = value
	end,
})

Farm:AddSection("Farm", "Lucide:coins")
Farm:AddToggle({
	Text = "Auto Farm",
	Description = "Walks to the nearest enemy and fights it",
	Icon = "Lucide:swords",
	Default = false,
	Flag = "pb_auto_farm",
	Callback = function(value)
		Settings.AutoFarm = value
	end,
})
Farm:AddSlider({
	Text = "Farm Range",
	Description = "How far away enemies are targeted",
	Icon = "Lucide:radar",
	Min = 20,
	Max = 400,
	Default = 150,
	Increment = 10,
	Suffix = " studs",
	Flag = "pb_farm_range",
	Callback = function(value)
		Settings.FarmRange = value
	end,
})
Farm:AddSlider({
	Text = "Farm Stop Distance",
	Description = "Stops walking once the enemy is this close",
	Icon = "Lucide:footprints",
	Min = 3,
	Max = 30,
	Default = 6,
	Increment = 1,
	Suffix = " studs",
	Flag = "pb_farm_stop",
	Callback = function(value)
		Settings.FarmStop = value
	end,
})

Farm:AddSection("Aggressive", "Lucide:zap")
Farm:AddToggle({
	Text = "Aggressive Farm",
	Description = "Hovers above the target and kills it, then jumps to the next one",
	Icon = "Lucide:zap",
	Default = false,
	Flag = "pb_aggro_farm",
	Callback = function(value)
		Settings.AggroFarm = value
		if not value then
			aggroTarget = nil
			setAttack(false)
		end
	end,
})
Farm:AddSlider({
	Text = "Aggro Range",
	Description = "How far away targets are picked up",
	Icon = "Lucide:radar",
	Min = 30,
	Max = 600,
	Default = 250,
	Increment = 10,
	Suffix = " studs",
	Flag = "pb_aggro_range",
	Callback = function(value)
		Settings.AggroRange = value
	end,
})
Farm:AddSlider({
	Text = "Hover Height",
	Description = "How far above the enemy you sit (higher = safer, too high = no hits)",
	Icon = "Lucide:arrow-up",
	Min = 3,
	Max = 14,
	Default = 6,
	Increment = 1,
	Suffix = " studs",
	Flag = "pb_aggro_height",
	Callback = function(value)
		Settings.AggroHeight = value
	end,
})

Visuals:AddSection("ESP", "Lucide:eye")
Visuals:AddToggle({
	Text = "Enemy ESP",
	Description = "Highlights enemies with health and distance",
	Icon = "Lucide:eye",
	Default = false,
	Flag = "pb_esp_enemy",
	Callback = function(value)
		Settings.EspEnemy = value
	end,
})
Visuals:AddSlider({
	Text = "ESP Distance",
	Icon = "Lucide:radar",
	Min = 50,
	Max = 1000,
	Default = 250,
	Increment = 25,
	Suffix = " studs",
	Flag = "pb_esp_distance",
	Callback = function(value)
		Settings.EspDistance = value
	end,
})

DebugTab:AddSection("Logging", "Lucide:terminal")
DebugTab:AddToggle({
	Text = "Debug Logs",
	Description = "Prints parry/attack/farm state every couple of seconds",
	Icon = "Lucide:bug",
	Default = false,
	Flag = "pb_debug",
	Callback = function(value)
		Settings.DebugLogs = value
	end,
})
DebugTab:AddButton({
	Text = "Print Enemy Count",
	Description = "Logs how many enemies the scanner currently sees",
	Icon = "Lucide:list",
	Callback = function()
		scanEnemies()
		ctx:Log("[PB] enemies visible: " .. tostring(#enemyCache), "info")
	end,
})

---------------------------------------------------------------------
-- Main loop
---------------------------------------------------------------------

task.spawn(function()
	while ctx:Alive() do
		if Settings.SpeedOn then
			pcall(applySpeed)
		end
		if Settings.JumpOn then
			pcall(applyJump)
		end
		if Settings.AutoParry then
			pcall(autoParryStep)
		end
		if Settings.AutoAttack then
			pcall(autoAttackStep)
		end
		if Settings.AutoDash then
			pcall(autoDashStep)
		end
		if Settings.DodgeProjectiles then
			pcall(dodgeProjectileStep)
		end
		if Settings.AutoSkillOne or Settings.AutoSkillTwo then
			pcall(autoSkillStep)
		end
		if Settings.FaceTarget then
			pcall(faceStep)
		end
		if Settings.AutoFarm and not Settings.AggroFarm then
			pcall(autoFarmStep)
		end
		if Settings.AggroFarm then
			pcall(aggressiveFarmStep)
		end
		if Settings.AutoPotion then
			pcall(autoPotionStep)
		end
		if Settings.AutoDanger then
			pcall(dangerStep)
		end
		if Settings.AutoBanner then
			pcall(autoBannerStep)
		end
		if Settings.InfiniteJump then
			pcall(infiniteJumpStep)
		end
		if Settings.EspEnemy then
			pcall(espStep)
		end
		if Settings.DebugLogs then
			pcall(debugStep)
		end
		task.wait(0.08)
	end
end)

ctx:OnCleanup(function()
	Settings.AutoParry = false
	Settings.AutoAttack = false
	Settings.AutoFarm = false
	Settings.AggroFarm = false
	aggroTarget = nil
	Settings.EspEnemy = false
	Settings.InfiniteEnergy = false
	setInfiniteEnergy(false)
	Settings.AutoDanger = false
	dangerActive = false
	dangerStartedAt = 0
	setBlocking(false)
	setAttack(false)
	releaseMoveKeys()
	if faceConnection then
		faceConnection:Disconnect()
		faceConnection = nil
	end
	for model, entry in pairs(espEntries) do
		entry.Gui:Destroy()
		entry.Highlight:Destroy()
		espEntries[model] = nil
	end
end)
