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

ctx:Log("[PB] module loaded", "info")

local Settings = {
	AutoParry = false,
	ParryRange = 22,
	ParryInterval = 0.12,
	ParryOnWarning = true,
	DashOnWarning = true,
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
	AutoPotion = false,
	PotionPercent = 40,
	SpeedOn = false,
	Speed = 30,
	JumpOn = false,
	JumpPower = 100,
	InfiniteJump = false,
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
local parryTap = false

local function autoParryStep()
	local now = os.clock()
	if now < nextParryAt then
		return
	end
	local enemy = nearestHostile(Settings.ParryRange)
	if not enemy then
		if parryTap then
			parryTap = false
			setBlocking(false)
		end
		return
	end
	-- Only react when a telegraphed attack is actually landing nearby.
	if Settings.ParryOnWarning and not incomingAttackNear(Settings.ParryRange + 12) then
		if parryTap then
			parryTap = false
			setBlocking(false)
		end
		return
	end
	-- Tap block: each rising edge opens a new parry window.
	parryTap = not parryTap
	setBlocking(parryTap)
	nextParryAt = now + Settings.ParryInterval
end

local function autoAttackStep()
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
				found[#found + 1] = descendant
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
	-- Prefer something the game itself marks as an enemy; only fall back to the broader
	-- scan (distant, no nameplate yet) when nothing nearby is marked.
	local hostile, hostileDistance = nearestHostile(Settings.FarmRange)
	if hostile then
		return hostile, hostileDistance
	end
	scanEnemies()
	local now = os.clock()
	local best, bestDistance = nil, math.huge
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

local farmPath = nil
local farmWaypointIndex = 1
local farmPathTarget = nil
local farmLastRepathAt = 0
local farmStuckCount = 0

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

	-- Progress tracking: if the character stops moving while chasing, hop and drop the
	-- target so it does not grind against a wall forever.
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
	local percent = humanoid.Health / math.max(humanoid.MaxHealth, 1) * 100
	if percent > Settings.PotionPercent then
		return
	end
	nextPotionAt = now + 2
	pressKey(keyCodes.One)
	logOnce("potion_ok", "auto potion: drinking while low", "info")
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
	-- Preferred path: click whichever card is offered so the game itself does the pick and
	-- closes its own picker.
	local card = clickBannerCard(screen)
	if card then
		nextBannerAt = now + 1.5
		ctx:Log("[PB] banner: clicked an offered card", "info")
		return
	end
	-- Fallback for when mouse input is swallowed (unfocused window / executor limits):
	-- pick any offered banner through the remote and hide the picker ourselves so it does
	-- not stay on screen.
	local offered = offeredBannerIds(screen)
	local choice = nil
	for id in pairs(offered) do
		choice = id
		break
	end
	if choice then
		fireBanner(choice)
		closePicker(screen)
		nextBannerAt = now + 1.5
		ctx:Log("[PB] banner: picked " .. tostring(choice) .. " and closed the picker", "info")
	end
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

Player:AddSection("Survival", "Lucide:heart-pulse")
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
		if Settings.AutoSkillOne or Settings.AutoSkillTwo then
			pcall(autoSkillStep)
		end
		if Settings.FaceTarget then
			pcall(faceStep)
		end
		if Settings.AutoFarm then
			pcall(autoFarmStep)
		end
		if Settings.AutoPotion then
			pcall(autoPotionStep)
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
	Settings.EspEnemy = false
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
