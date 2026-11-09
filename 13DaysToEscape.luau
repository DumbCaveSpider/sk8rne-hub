-- 13 Days to Escape
local ctx = ...
local task = ctx.task

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local LocalPlayer = Players.LocalPlayer

-- Best-effort require of shared config modules (all are pure frozen tables).
local Shared = ReplicatedStorage:FindFirstChild("Shared")
local function tryRequire(name)
	if not Shared then
		return nil
	end
	local module = Shared:FindFirstChild(name)
	if not module then
		return nil
	end
	local ok, result = pcall(require, module)
	return ok and result or nil
end

local PrisonSchedule = tryRequire("PrisonSchedule")
local OJTrade = tryRequire("OJTrade")
local SecurityCameraDamage = tryRequire("SecurityCameraDamage")

-- Tool categories and cooldowns, matching the game's UtensilConfig.
local DIG_TOOLS = { Spoon = true, Trowel = true, Drill = true }
local MELEE_TOOLS = { Knife = true, Screwdriver = true, Bat = true }
local BARRIER_TOOLS = { Hammer = true }

local TOOL_COOLDOWNS = {
	Knife = 0.7,
	Screwdriver = 0.7,
	Bat = 0.85,
	Hammer = 0.85,
	Spoon = 0.45,
	Trowel = 0.36,
	Drill = 0.1,
}

local POTATOES = 5 -- EconomyConfig.Potatoes (masks per potato)
local CHOP_CUTS = 28 -- VegetableRules.Cuts (cuts per vegetable)
local CHOP_INTERVAL = 0.3 -- VegetableRules.Interval
local DEFAULT_WALK_SPEED = 16
local DEFAULT_FOV = 70

local function getRemote(name)
	return ReplicatedStorage:FindFirstChild(name)
end

local function getRootPart()
	local char = LocalPlayer.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

local function getHumanoid()
	local char = LocalPlayer.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

-- True while the player is admitted to a live match and not in a cutscene.
local function actionsUnblocked()
	if LocalPlayer:GetAttribute("MatchAdmitted") ~= true then
		return false
	end
	if LocalPlayer:GetAttribute("EntryPhase") ~= "GameReady" then
		return false
	end
	if LocalPlayer:GetAttribute("RunEnded") or LocalPlayer:GetAttribute("DeathPresented") then
		return false
	end
	if LocalPlayer:GetAttribute("IntroPlaying") or LocalPlayer:GetAttribute("WakePlaying") then
		return false
	end
	return true
end

local function getToolType()
	local char = LocalPlayer.Character
	local tool = char and char:FindFirstChildOfClass("Tool")
	if not tool then
		return nil
	end
	if tool:GetAttribute("GuardBat") == true then
		return "Bat"
	end
	local reward = tool:GetAttribute("OJReward")
	if type(reward) == "string" and reward ~= "" then
		return reward
	end
	return nil
end

local function canPunch()
	if LocalPlayer:GetAttribute("StealingBook") then
		return false
	end
	if not actionsUnblocked() then
		return false
	end
	local char = LocalPlayer.Character
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not (humanoid and humanoid.Health > 0 and root and not root.Anchored) then
		return false
	end
	if char:GetAttribute("MealHolding") or char:GetAttribute("BasketballHolding") then
		return false
	end
	if char:FindFirstChildOfClass("Tool") then
		return false
	end
	return true
end

local function readyToolType()
	if LocalPlayer:GetAttribute("StealingBook") or LocalPlayer:GetAttribute("DraggingBody") then
		return nil
	end
	if not actionsUnblocked() then
		return nil
	end
	local char = LocalPlayer.Character
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not (humanoid and humanoid.Health > 0 and root and not root.Anchored) then
		return nil
	end
	if char:GetAttribute("MealHolding") or char:GetAttribute("BasketballHolding") then
		return nil
	end
	return getToolType()
end

local function isTarget(npc, targetName)
	if npc.Name == targetName then
		return true
	end
	local kind1, num1 = targetName:match("^(%a+)(%d+)$")
	local kind2, num2 = npc.Name:match("^(%a+)(%d+)$")
	return kind1 ~= nil and kind1 == kind2 and tonumber(num1) == tonumber(num2)
end

-- The NPC named by the current OJ assassination offer, if the offer is an assassination.
local function findAssignedTarget()
	if not OJTrade then
		return nil
	end
	local ok, offer = pcall(OJTrade.decode, LocalPlayer:GetAttribute("OJTradeOffer"))
	if not ok or not offer or offer.Need ~= "Assassination" then
		return nil
	end
	local targetName = offer.Target
	if not targetName then
		return nil
	end
	for _, npc in ipairs(CollectionService:GetTagged("PrisonAmbientNPC")) do
		if isTarget(npc, targetName) then
			local humanoid = npc:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health > 0 then
				return npc
			end
		end
	end
	return nil
end

local Settings = {
	AutoPunch = false,
	AutoAttack = false,
	AutoDig = false,
	AutoBreak = false,
	AutoChop = false,
	AutoPeel = false,
	GuardEsp = false,
	CameraEsp = false,
	WardenEsp = false,
	SentryEsp = false,
	EspDistance = 500,
	SpeedBoost = false,
	WalkSpeed = 30,
	FovBoost = false,
	Fov = 100,
	TargetEsp = false,
	FreezeSuspicion = false,
	AutoKillTarget = false,
	KillRange = 6,
	ShowSchedule = false,
	AutoCash = false,
	AutoBooks = false,
	BreakCameras = false,
	TrashPickup = false,
	TrashRange = 12,
	BookEsp = false,
	AutoEscape = false,
	MoneyEsp = false,
	AutoSaw = false,
}

---------------------------------------------------------------------
-- Combat
---------------------------------------------------------------------

local swingCount = 0
local nextPunchAt = 0
local nextToolAt = 0
local nextKillAt = 0

local function toolCooldown(toolType)
	return TOOL_COOLDOWNS[toolType] or 0.5
end

local function firePunch()
	local now = os.clock()
	if now < nextPunchAt then
		return
	end
	if not canPunch() then
		return
	end
	local camera = workspace.CurrentCamera
	local remote = getRemote("PrisonPunch")
	if not (camera and remote) then
		return
	end
	nextPunchAt = now + 0.55 + 0.03 -- PunchConfig.Cooldown
	remote:FireServer(camera.CFrame.LookVector)
end

local function fireTool()
	local now = os.clock()
	if now < nextToolAt then
		return
	end
	local toolType = readyToolType()
	if not toolType then
		return
	end
	local want
	if DIG_TOOLS[toolType] then
		want = Settings.AutoDig
	elseif MELEE_TOOLS[toolType] then
		want = Settings.AutoAttack
	elseif BARRIER_TOOLS[toolType] then
		want = Settings.AutoBreak
	end
	if not want then
		return
	end
	local camera = workspace.CurrentCamera
	local remote = getRemote("PrisonUtensilUse")
	if not (camera and remote) then
		return
	end
	nextToolAt = now + toolCooldown(toolType) + 0.03
	swingCount += 1
	-- Dig tools and the hammer report the camera position; melee tools do not.
	local position = (DIG_TOOLS[toolType] or BARRIER_TOOLS[toolType]) and camera.CFrame.Position or nil
	remote:FireServer(camera.CFrame.LookVector, swingCount, position)
end

-- Walks to, aims at and repeatedly strikes the current OJ assassination target.
local function autoKillStep()
	if LocalPlayer:GetAttribute("StealingBook") or LocalPlayer:GetAttribute("DraggingBody") then
		return
	end
	if not actionsUnblocked() then
		return
	end
	local myRoot = getRootPart()
	local humanoid = getHumanoid()
	if not (myRoot and humanoid and humanoid.Health > 0) then
		return
	end
	if humanoid.Sit then
		return
	end
	local npc = findAssignedTarget()
	if not npc then
		return
	end
	local targetRoot = npc:FindFirstChild("HumanoidRootPart")
	if not targetRoot then
		return
	end
	-- The game resolves melee from the head/eye, so the reach check and swing vector use it.
	local head = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Head")
	local origin = (head and head.Position) or myRoot.Position
	local distance = (targetRoot.Position - origin).Magnitude
	if distance > 200 then
		return
	end
	-- Keep closing in so the character faces the target and stays in melee range.
	humanoid:MoveTo(targetRoot.Position)
	if distance > Settings.KillRange then
		return
	end
	local now = os.clock()
	if now < nextKillAt then
		return
	end
	local direction = (targetRoot.Position - origin).Unit
	local toolType = getToolType()
	if toolType then
		if not MELEE_TOOLS[toolType] then
			return
		end
		nextKillAt = now + toolCooldown(toolType) + 0.03
		swingCount += 1
		local remote = getRemote("PrisonUtensilUse")
		if remote then
			remote:FireServer(direction, swingCount, nil)
		end
	else
		nextKillAt = now + 0.55 + 0.03
		local remote = getRemote("PrisonPunch")
		if remote then
			remote:FireServer(direction)
		end
	end
end

---------------------------------------------------------------------
-- Economy (kitchen jobs)
---------------------------------------------------------------------

local chopToken = nil
local chopCuts = 0
local nextChopAt = 0
local peel = { token = nil, nextMask = 1, nextAt = 0 }

local function onEconomy(message, a, b, c)
	if message == "ChopStart" then
		chopToken = a
		chopCuts = (c and c.cuts) or 0
	elseif message == "ChopProgress" and a == chopToken then
		chopCuts = (b and b.cuts) or 0
	elseif message == "ChopStop" and a == chopToken then
		chopToken = nil
		chopCuts = 0
	elseif message == "PeelStart" then
		peel.token = a
		peel.nextMask = 1
		peel.nextAt = os.clock()
	elseif message == "PeelStop" and a == peel.token then
		peel.token = nil
	end
end

task.spawn(function()
	local remote = ReplicatedStorage:WaitForChild("PrisonEconomy", 10)
	if remote and ctx:Alive() then
		ctx:Connect(remote.OnClientEvent, onEconomy)
	end
end)

local function fireChop()
	local now = os.clock()
	if now < nextChopAt then
		return
	end
	if not (chopToken and chopCuts < CHOP_CUTS) then
		return
	end
	local remote = getRemote("PrisonEconomy")
	if not remote then
		return
	end
	nextChopAt = now + CHOP_INTERVAL
	remote:FireServer("Chop", chopToken)
end

local function firePeel()
	local now = os.clock()
	if not peel.token then
		return
	end
	if now < peel.nextAt then
		return
	end
	if peel.nextMask > POTATOES then
		return
	end
	local remote = getRemote("PrisonEconomy")
	if not remote then
		return
	end
	remote:FireServer("PeelComplete", peel.token, peel.nextMask)
	peel.nextMask += 1
	peel.nextAt = now + 0.2
end

---------------------------------------------------------------------
-- Prompt jobs (cash piles and library books)
---------------------------------------------------------------------

-- Prompt references are cached so a per-tick pass never walks the whole map.
local cashPrompts = {}
local takeBookPrompts = {}
local yardPickupPrompts = {}
local libraryJobPrompt = nil

local function trackPrompt(instance)
	if not instance:IsA("ProximityPrompt") then
		return
	end
	if instance.Name == "StealCash" then
		cashPrompts[instance] = true
	elseif instance.Name == "TakeBook" then
		takeBookPrompts[instance] = true
	elseif instance.Name == "YardPickup" then
		yardPickupPrompts[instance] = true
	elseif instance.Name == "LibraryJob" then
		libraryJobPrompt = instance
	end
end

ctx:Connect(workspace.DescendantAdded, trackPrompt)
for _, descendant in ipairs(workspace:GetDescendants()) do
	trackPrompt(descendant)
end

-- fireproximityprompt skips the client's distance/aim gate. Executors without it fall back
-- to a simulated hold, forcing the prompt enabled because the game disables far ones.
local function triggerPrompt(prompt)
	if not prompt then
		return false
	end
	-- Enable first: the game disables prompts while they are off-screen, and
	-- fireproximityprompt ignores a disabled prompt.
	prompt.Enabled = true
	if type(fireproximityprompt) == "function" then
		local ok = pcall(fireproximityprompt, prompt)
		if ok then
			return true
		end
	end
	pcall(function()
		prompt:InputHoldBegin()
		task.delay(math.max(0.05, (prompt.HoldDuration or 0) + 0.05), function()
			pcall(prompt.InputHoldEnd, prompt)
		end)
	end)
	return true
end

local function cashAmount(prompt)
	local text = prompt.ObjectText or ""
	return tonumber(text:match("%d+")) or 0
end

-- Prompts often live inside an Attachment (BookPickupPoint etc.) under the real part,
-- so walk up the tree to the BasePart that should carry the marker.
local function nearestPart(instance)
	local current = instance
	while current and current ~= workspace do
		if current:IsA("BasePart") then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function promptPosition(prompt)
	local part = nearestPart(prompt)
	if part then
		return part.Position
	end
	local parent = prompt.Parent
	if parent and parent:IsA("Model") then
		return parent:GetPivot().Position
	end
	return nil
end

-- The server reports the number of the book being read as this event's last argument.
-- Tracking it lets the farm tell whether the book it holds is the one the job asked for.
local pickedBookNumber = nil
task.spawn(function()
	local remote = ReplicatedStorage:WaitForChild("PrisonBookPickup", 10)
	if remote and ctx:Alive() then
		ctx:Connect(remote.OnClientEvent, function(message, player, _, _, _, _, bookNumber)
			if message == "Start" and player == LocalPlayer then
				pickedBookNumber = tonumber(bookNumber)
			end
		end)
	end
end)

local nextCashAt = 0
local nextBookAt = 0
local nextBookReturnAt = 0
local nextTrashAt = 0
local lastCashTry = {}

local function cashStep()
	if LocalPlayer:GetAttribute("RunEnded") or LocalPlayer:GetAttribute("DeathPresented") then
		return
	end
	local now = os.clock()
	if now < nextCashAt then
		return
	end
	nextCashAt = now + 0.25
	local myRoot = getRootPart()
	if not myRoot then
		return
	end
	local best, bestPart, bestDistance = nil, nil, math.huge
	for prompt in pairs(cashPrompts) do
		if prompt:IsDescendantOf(workspace) then
			if cashAmount(prompt) > 0 then
				local part = nearestPart(prompt)
				if part then
					local distance = (part.Position - myRoot.Position).Magnitude
					if distance < bestDistance then
						best, bestPart, bestDistance = prompt, part, distance
					end
				end
			end
		else
			cashPrompts[prompt] = nil
			lastCashTry[prompt] = nil
		end
	end
	if not best then
		return
	end
	if bestDistance > 7 then
		local humanoid = getHumanoid()
		if humanoid then
			humanoid:MoveTo(bestPart.Position)
		end
		return
	end
	if now - (lastCashTry[best] or 0) >= 3 then
		lastCashTry[best] = now
		triggerPrompt(best)
		nextCashAt = now + 0.7
	end
end

local function bookStep()
	if not actionsUnblocked() then
		return
	end
	local now = os.clock()
	if now < nextBookAt then
		return
	end
	local requested = tonumber(LocalPlayer:GetAttribute("LibraryJobBook"))
	local done = tonumber(LocalPlayer:GetAttribute("LibraryJobsDone")) or 0
	if not requested or done >= 3 then
		nextBookAt = now + 1
		return
	end
	local character = LocalPlayer.Character
	local tool = character and character:FindFirstChildOfClass("Tool")
	if tool and tool:GetAttribute("PrisonBook") then
		if now < nextBookReturnAt then
			nextBookAt = now + 0.5
			return
		end
		-- The server told us which book this is. If it is not the requested one, return it.
		if pickedBookNumber and pickedBookNumber ~= requested then
			for prompt in pairs(takeBookPrompts) do
				if prompt:IsDescendantOf(workspace) and prompt:GetAttribute("BookReturnOnly") == true then
					prompt.Enabled = true
					triggerPrompt(prompt)
					nextBookReturnAt = now + 1.5
					nextBookAt = now + 1.5
					return
				end
			end
			nextBookAt = now + 1
			return
		end
		-- Holding the requested book: hand it to the clerk.
		if libraryJobPrompt and libraryJobPrompt:IsDescendantOf(workspace) then
			triggerPrompt(libraryJobPrompt)
			nextBookAt = now + 0.8
		else
			nextBookAt = now + 0.5
		end
		return
	end
	pickedBookNumber = nil
	for prompt in pairs(takeBookPrompts) do
		if prompt:IsDescendantOf(workspace) then
			if
				tonumber(prompt:GetAttribute("BookNumber")) == requested
				and prompt:GetAttribute("BookBusy") ~= true
				and prompt:GetAttribute("BookReturnOnly") ~= true
				and (tonumber(prompt:GetAttribute("BookStock")) or 0) > 0
			then
				prompt.Enabled = true
				triggerPrompt(prompt)
				nextBookAt = now + 0.8
				return
			end
		else
			takeBookPrompts[prompt] = nil
		end
	end
	nextBookAt = now + 0.5
end

local function trashStep()
	if not actionsUnblocked() then
		return
	end
	if LocalPlayer:GetAttribute("YardJobAvailable") ~= true or LocalPlayer:GetAttribute("YardJobDone") == true then
		return
	end
	if (tonumber(LocalPlayer:GetAttribute("YardLitterCount")) or 0) >= 8 then
		return
	end
	local myRoot = getRootPart()
	if not myRoot then
		return
	end
	local now = os.clock()
	if now < nextTrashAt then
		return
	end
	nextTrashAt = now + 0.3
	local best, bestDistance = nil, Settings.TrashRange
	for prompt in pairs(yardPickupPrompts) do
		if prompt:IsDescendantOf(workspace) then
			local position = promptPosition(prompt)
			if position then
				local distance = (position - myRoot.Position).Magnitude
				if distance <= bestDistance then
					best, bestDistance = prompt, distance
				end
			end
		else
			yardPickupPrompts[prompt] = nil
		end
	end
	if best then
		best.Enabled = true
		triggerPrompt(best)
	end
end

---------------------------------------------------------------------
-- Escape (toilet -> panel -> tunnel)
---------------------------------------------------------------------

local function getCellToilet()
	local cellNumber = LocalPlayer:GetAttribute("AssignedCellNumber") or 13
	local island = workspace:FindFirstChild("PrisonIsland")
	if not island then
		return nil
	end
	for _, blockName in ipairs({ "CellBlockB", "CellBlockA" }) do
		local block = island:FindFirstChild(blockName)
		local cell = block and block:FindFirstChild("Cell" .. tostring(cellNumber))
		local toilet = cell and cell:FindFirstChild("Toilet")
		if toilet then
			return toilet
		end
	end
	return nil
end

local function findTool(toolType)
	local character = LocalPlayer.Character
	local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
	for _, container in ipairs({ character, backpack }) do
		if container then
			for _, child in ipairs(container:GetChildren()) do
				if child:IsA("Tool") and child:GetAttribute("OJReward") == toolType then
					return child
				end
			end
		end
	end
	return nil
end

local function equipTool(tool)
	if not tool then
		return
	end
	local humanoid = getHumanoid()
	if humanoid and tool.Parent ~= LocalPlayer.Character then
		pcall(humanoid.EquipTool, humanoid, tool)
	end
end

local nextEscapeAt = 0

local function escapeStep()
	if not actionsUnblocked() then
		return
	end
	local now = os.clock()
	if now < nextEscapeAt then
		return
	end
	local toilet = getCellToilet()
	if not toilet then
		return
	end
	local myRoot = getRootPart()
	local humanoid = getHumanoid()
	if not (myRoot and humanoid) then
		return
	end

	-- 1. Unscrew every anchor bolt (a screwdriver must be equipped).
	local bolt
	for _, child in ipairs(toilet:GetChildren()) do
		if child:IsA("BasePart") and child.Name == "AnchorBolt" and child:GetAttribute("Loose") ~= true then
			bolt = child
			break
		end
	end
	if bolt then
		local prompt = bolt:FindFirstChild("UnscrewPrompt")
		if prompt and prompt:IsA("ProximityPrompt") then
			if getToolType() ~= "Screwdriver" then
				equipTool(findTool("Screwdriver"))
				nextEscapeAt = now + 0.5
				return
			end
			if (myRoot.Position - bolt.Position).Magnitude <= 10 then
				prompt.Enabled = true
				triggerPrompt(prompt)
				nextEscapeAt = now + 1.7
			else
				humanoid:MoveTo(bolt.Position)
				nextEscapeAt = now + 0.5
			end
		end
		return
	end

	-- 2. Move the toilet panel aside.
	local plate = toilet:FindFirstChild("MountingPlate")
	local movePrompt = plate and plate:FindFirstChild("MovePanelPrompt")
	if movePrompt and movePrompt:IsA("ProximityPrompt") and toilet:GetAttribute("PanelOpen") ~= true then
		if (myRoot.Position - plate.Position).Magnitude <= 10 then
			movePrompt.Enabled = true
			triggerPrompt(movePrompt)
			nextEscapeAt = now + 1
		else
			humanoid:MoveTo(plate.Position)
			nextEscapeAt = now + 0.5
		end
		return
	end

	-- 3. Dig out the tunnel while holding a digging tool.
	local toolType = getToolType()
	if not (toolType and DIG_TOOLS[toolType]) then
		local digTool = findTool("Drill") or findTool("Trowel") or findTool("Spoon")
		if digTool then
			equipTool(digTool)
		end
		nextEscapeAt = now + 0.5
		return
	end
	local cell = toilet.Parent
	local digCover = cell and cell:FindFirstChild("DigCover")
	local target = digCover or toilet
	local targetPos
	if target:IsA("BasePart") then
		targetPos = target.Position
	else
		targetPos = target:GetPivot().Position
	end
	local camera = workspace.CurrentCamera
	if camera then
		local direction = (targetPos - camera.CFrame.Position).Unit
		if now >= nextToolAt then
			nextToolAt = now + toolCooldown(toolType) + 0.03
			swingCount += 1
			local remote = getRemote("PrisonUtensilUse")
			if remote then
				remote:FireServer(direction, swingCount, camera.CFrame.Position)
			end
		end
	end
end

local function getRaidWindow()
	local cellNumber = LocalPlayer:GetAttribute("AssignedCellNumber") or 13
	local island = workspace:FindFirstChild("PrisonIsland")
	if not island then
		return nil
	end
	for _, blockName in ipairs({ "CellBlockB", "CellBlockA" }) do
		local block = island:FindFirstChild(blockName)
		local cell = block and block:FindFirstChild("Cell" .. tostring(cellNumber))
		local window = cell and cell:FindFirstChild("RaidWindow")
		if window then
			return window
		end
	end
	return nil
end

local nextSawAt = 0

local function sawStep()
	if not actionsUnblocked() then
		return
	end
	local now = os.clock()
	if now < nextSawAt then
		return
	end
	local window = getRaidWindow()
	if not window then
		return
	end
	local barsControl = window:FindFirstChild("BarsControl")
	if window:GetAttribute("BarsOpen") ~= true then
		local prompt = barsControl and barsControl:FindFirstChild("SawBarsPrompt")
		if not (prompt and prompt:IsA("ProximityPrompt")) then
			return
		end
		if getToolType() ~= "Saw" then
			equipTool(findTool("Saw"))
			nextSawAt = now + 0.5
			return
		end
		prompt.Enabled = true
		triggerPrompt(prompt)
		nextSawAt = now + 3.4 -- the saw prompt holds for 3.2s per cut
		return
	end
	-- Bars are cut through: climb out of the window.
	local climbControl = window:FindFirstChild("ClimbControl")
	local climbPrompt = climbControl and climbControl:FindFirstChildWhichIsA("ProximityPrompt")
	if climbPrompt then
		climbPrompt.Enabled = true
		triggerPrompt(climbPrompt)
		nextSawAt = now + 1.5
	end
end

---------------------------------------------------------------------
-- Cameras
---------------------------------------------------------------------

-- SecurityCameraDamage is shared, so breakModel runs on the client too: it sets the attributes
-- the camera and surveillance scripts read and visually wrecks the model (locally only).
local function breakCamera(cameraModel)
	if SecurityCameraDamage and SecurityCameraDamage.breakModel then
		local ok, broke = pcall(SecurityCameraDamage.breakModel, cameraModel)
		if ok then
			return broke
		end
	end
	pcall(function()
		cameraModel:SetAttribute("Enabled", false)
		cameraModel:SetAttribute("SecurityCameraBroken", true)
		cameraModel:SetAttribute("CameraVisibleUntil", 0)
		cameraModel:SetAttribute("CameraAlertUntil", 0)
	end)
	return true
end

local function cameraStep()
	local island = workspace:FindFirstChild("PrisonIsland")
	local folder = island and island:FindFirstChild("SecurityCameras")
	if not folder then
		return
	end
	for _, cameraModel in ipairs(folder:GetChildren()) do
		if
			cameraModel:GetAttribute("SecurityCameraManaged") == true
			and not cameraModel:GetAttribute("SecurityCameraBroken")
		then
			breakCamera(cameraModel)
		end
	end
end

---------------------------------------------------------------------
-- Visuals (ESP + schedule)
---------------------------------------------------------------------

local espFolder = ctx:Track(Instance.new("Folder"))
espFolder.Name = "Sk8rne13DEsp"
espFolder.Parent = LocalPlayer:WaitForChild("PlayerGui")

local espEntries = {}

local ESP_COLORS = {
	Guard = Color3.fromRGB(255, 96, 96),
	Camera = Color3.fromRGB(255, 200, 80),
	Warden = Color3.fromRGB(200, 96, 255),
	Sentry = Color3.fromRGB(96, 220, 255),
	Target = Color3.fromRGB(255, 220, 60),
	Book = Color3.fromRGB(96, 220, 255),
	Money = Color3.fromRGB(120, 255, 120),
}

local function guardAlertLevel(guard, now, manhunt)
	if manhunt then
		return 3
	end
	if type(guard:GetAttribute("GuardAlert3Until")) == "number" and now < guard:GetAttribute("GuardAlert3Until") then
		return 3
	end
	if type(guard:GetAttribute("GuardAlert2Until")) == "number" and now < guard:GetAttribute("GuardAlert2Until") then
		return 2
	end
	if type(guard:GetAttribute("GuardAlert1Until")) == "number" and now < guard:GetAttribute("GuardAlert1Until") then
		return 1
	end
	return 0
end

local function espAnchor(model)
	if model:IsA("BasePart") then
		return model
	end
	return model:FindFirstChild("HumanoidRootPart")
		or model:FindFirstChild("Lens")
		or model.PrimaryPart
end

local function createEsp(model, part, category)
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(220, 46)
	gui.StudsOffset = Vector3.new(0, category == "Book" and 1.4 or 3.2, 0)
	gui.AlwaysOnTop = true
	gui.Adornee = part
	gui.Parent = espFolder

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 12
	label.TextColor3 = ESP_COLORS[category] or Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0.4
	label.Parent = gui

	local entry = { Gui = gui, Label = label }
	espEntries[model] = entry
	return entry
end

local function findTargetBook()
	local requested = tonumber(LocalPlayer:GetAttribute("LibraryJobBook"))
	if not requested then
		return nil
	end
	for prompt in pairs(takeBookPrompts) do
		if
			prompt:IsDescendantOf(workspace)
			and tonumber(prompt:GetAttribute("BookNumber")) == requested
			and prompt:GetAttribute("BookReturnOnly") ~= true
		then
			return nearestPart(prompt)
		end
	end
	return nil
end

local npcHighlight = nil
local bookHighlight = nil
local moneyHighlights = {}

local function updateHighlight(current, model, color)
	if not model then
		if current then
			current:Destroy()
		end
		return nil
	end
	if current and current.Parent == model then
		return current
	end
	if current then
		current:Destroy()
	end
	local highlight = Instance.new("Highlight")
	highlight.Name = "Sk8rne13DHighlight"
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.FillTransparency = 0.65
	highlight.FillColor = color
	highlight.OutlineColor = color
	highlight.Adornee = model
	highlight.Parent = model
	return highlight
end

local function updateTargetHighlights()
	local npc = Settings.TargetEsp and findAssignedTarget() or nil
	npcHighlight = updateHighlight(npcHighlight, npc, ESP_COLORS.Target)
	local book = Settings.BookEsp and findTargetBook() or nil
	bookHighlight = updateHighlight(bookHighlight, book, ESP_COLORS.Book)
end

local function updateMoneyHighlights()
	local keep = {}
	if Settings.MoneyEsp then
		for prompt in pairs(cashPrompts) do
			if prompt:IsDescendantOf(workspace) then
				local amount = cashAmount(prompt)
				if amount > 0 and os.clock() - (lastCashTry[prompt] or 0) >= 1.5 then
					local part = nearestPart(prompt)
					if part then
						keep[part] = true
						if not moneyHighlights[part] then
							local highlight = Instance.new("Highlight")
							highlight.Name = "Sk8rne13DMoney"
							highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
							highlight.FillColor = ESP_COLORS.Money
							highlight.FillTransparency = 0.7
							highlight.OutlineColor = ESP_COLORS.Money
							highlight.Adornee = part
							highlight.Parent = part
							moneyHighlights[part] = highlight
						end
					end
				end
			end
		end
	end
	for part, highlight in pairs(moneyHighlights) do
		if not keep[part] then
			highlight:Destroy()
			moneyHighlights[part] = nil
		end
	end
end

local function collectEspTargets()
	local targets = {}
	local myRoot = getRootPart()
	if not myRoot then
		return targets
	end

	local function add(model, category, text)
		local part = espAnchor(model)
		if part then
			table.insert(targets, { Model = model, Part = part, Category = category, Text = text })
		end
	end

	local now = (PrisonSchedule and PrisonSchedule.now(workspace)) or workspace:GetServerTimeNow()
	local manhunt = workspace:GetAttribute("PrisonManhuntActive") == true

	if Settings.GuardEsp then
		for _, npc in ipairs(CollectionService:GetTagged("PrisonAmbientNPC")) do
			if npc:GetAttribute("Role") == "Guard" then
				local humanoid = npc:FindFirstChildOfClass("Humanoid")
				local root = npc:FindFirstChild("HumanoidRootPart")
				if humanoid and humanoid.Health > 0 and root then
					local distance = (root.Position - myRoot.Position).Magnitude
					if distance <= Settings.EspDistance then
						local level = guardAlertLevel(npc, now, manhunt)
						add(npc, "Guard", string.format("%s\nAlert %d  %d studs", npc.Name, level, math.floor(distance)))
					end
				end
			end
		end
	end

	if Settings.CameraEsp then
		local island = workspace:FindFirstChild("PrisonIsland")
		local folder = island and island:FindFirstChild("SecurityCameras")
		if folder then
			for _, camera in ipairs(folder:GetChildren()) do
				if camera:GetAttribute("SecurityCameraManaged") == true then
					local lens = camera:FindFirstChild("Lens") or camera.PrimaryPart
					if lens then
						local distance = (lens.Position - myRoot.Position).Magnitude
						if distance <= Settings.EspDistance then
							local state
							if camera:GetAttribute("SecurityCameraBroken") == true then
								state = "BROKEN"
							elseif camera:GetAttribute("Enabled") ~= false then
								state = "ACTIVE"
							else
								state = "OFF"
							end
							add(camera, "Camera", string.format("Camera %s\n%d studs", state, math.floor(distance)))
						end
					end
				end
			end
		end
	end

	if Settings.WardenEsp then
		local warden = workspace:FindFirstChild("NightWarden")
		if warden and warden.PrimaryPart then
			local distance = (warden.PrimaryPart.Position - myRoot.Position).Magnitude
			if distance <= Settings.EspDistance then
				add(warden, "Warden", string.format("Warden\n%d studs", math.floor(distance)))
			end
		end
	end

	if Settings.SentryEsp then
		for _, sentry in ipairs(CollectionService:GetTagged("PrisonTowerSentry")) do
			local part = sentry:IsA("BasePart") and sentry or espAnchor(sentry)
			if part then
				local distance = (part.Position - myRoot.Position).Magnitude
				if distance <= Settings.EspDistance then
					add(sentry, "Sentry", string.format("Sentry\n%d studs", math.floor(distance)))
				end
			end
		end
	end

	if Settings.TargetEsp then
		local targetName = nil
		if OJTrade then
			local ok, offer = pcall(OJTrade.decode, LocalPlayer:GetAttribute("OJTradeOffer"))
			if ok and offer and offer.Need == "Assassination" then
				targetName = offer.Target
			end
		end
		if targetName then
			for _, npc in ipairs(CollectionService:GetTagged("PrisonAmbientNPC")) do
				if isTarget(npc, targetName) then
					local humanoid = npc:FindFirstChildOfClass("Humanoid")
					local root = npc:FindFirstChild("HumanoidRootPart")
					if humanoid and humanoid.Health > 0 and root then
						local distance = (root.Position - myRoot.Position).Magnitude
						if distance <= Settings.EspDistance then
							add(npc, "Target", string.format("TARGET %s\n%d studs", targetName, math.floor(distance)))
						end
					end
				end
			end
		end
	end

	if Settings.BookEsp then
		local bookModel = findTargetBook()
		if bookModel then
			local part = espAnchor(bookModel)
			if part then
				local distance = (part.Position - myRoot.Position).Magnitude
				if distance <= Settings.EspDistance then
					local requested = tonumber(LocalPlayer:GetAttribute("LibraryJobBook")) or 0
					add(bookModel, "Book", string.format("BOOK #%03d\n%d studs", requested, math.floor(distance)))
				end
			end
		end
	end

	if Settings.MoneyEsp then
		for prompt in pairs(cashPrompts) do
			if prompt:IsDescendantOf(workspace) then
				local amount = cashAmount(prompt)
				if amount > 0 and os.clock() - (lastCashTry[prompt] or 0) >= 1.5 then
					local part = nearestPart(prompt)
					if part then
						local distance = (part.Position - myRoot.Position).Magnitude
						if distance <= Settings.EspDistance then
							add(part, "Money", string.format("MONEY $%d\n%d studs", amount, math.floor(distance)))
						end
					end
				end
			end
		end
	end

	return targets
end

local function espStep()
	local targets = collectEspTargets()
	local visible = {}
	for _, target in ipairs(targets) do
		visible[target.Model] = true
		local entry = espEntries[target.Model]
		if not entry then
			entry = createEsp(target.Model, target.Part, target.Category)
		end
		entry.Gui.Adornee = target.Part
		entry.Label.Text = target.Text
		entry.Label.TextColor3 = ESP_COLORS[target.Category] or Color3.fromRGB(255, 255, 255)
	end
	for model, entry in pairs(espEntries) do
		if not visible[model] then
			entry.Gui:Destroy()
			espEntries[model] = nil
		end
	end
	updateTargetHighlights()
	updateMoneyHighlights()
end

local function clearEsp()
	for _, entry in pairs(espEntries) do
		entry.Gui:Destroy()
	end
	table.clear(espEntries)
	if npcHighlight then
		npcHighlight:Destroy()
		npcHighlight = nil
	end
	if bookHighlight then
		bookHighlight:Destroy()
		bookHighlight = nil
	end
	for _, highlight in pairs(moneyHighlights) do
		highlight:Destroy()
	end
	table.clear(moneyHighlights)
end

local function anyEspEnabled()
	return Settings.GuardEsp
		or Settings.CameraEsp
		or Settings.WardenEsp
		or Settings.SentryEsp
		or Settings.TargetEsp
		or Settings.BookEsp
		or Settings.MoneyEsp
end

local function getScheduleText()
	if not PrisonSchedule then
		return "Schedule unavailable"
	end
	local epoch = workspace:GetAttribute("PrisonScheduleEpoch")
	if epoch == nil then
		return "No match running"
	end
	local ok, sample = pcall(function()
		return PrisonSchedule.sample(PrisonSchedule.now(workspace) - epoch, workspace:GetAttribute("PrisonMapId"))
	end)
	if not ok or not sample then
		return "Waiting for schedule..."
	end
	local lines = {
		string.format("Day %d - %s", sample.Day, sample.Phase.Title),
		string.format("%s to %s", PrisonSchedule.formatTime(sample.Remaining), sample.Next and sample.Next.Title or "next phase"),
	}
	if workspace:GetAttribute("PrisonManhuntActive") == true then
		table.insert(lines, "MANHUNT ACTIVE")
	end
	if workspace:GetAttribute("PrisonLightsOut") == true then
		table.insert(lines, "LIGHTS OUT")
	end
	return table.concat(lines, "\n")
end

-- Plain on-screen schedule readout. VindUI controls can't be written from this module's
-- task threads on some executors (they throw a capability error), so this uses our own
-- instances, which updates from a task thread can safely touch.
local scheduleHud = ctx:Track(Instance.new("ScreenGui"))
scheduleHud.Name = "Sk8rne13DSchedule"
scheduleHud.ResetOnSpawn = false
scheduleHud.IgnoreGuiInset = true
scheduleHud.DisplayOrder = 80
scheduleHud.Enabled = false
scheduleHud.Parent = LocalPlayer:WaitForChild("PlayerGui")

local scheduleLabel = Instance.new("TextLabel")
scheduleLabel.Size = UDim2.fromOffset(280, 62)
scheduleLabel.Position = UDim2.fromOffset(12, 100)
scheduleLabel.BackgroundColor3 = Color3.fromRGB(10, 10, 10)
scheduleLabel.BackgroundTransparency = 0.35
scheduleLabel.BorderSizePixel = 0
scheduleLabel.Font = Enum.Font.GothamBold
scheduleLabel.TextSize = 12
scheduleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
scheduleLabel.TextStrokeTransparency = 0.5
scheduleLabel.TextWrapped = true
scheduleLabel.TextXAlignment = Enum.TextXAlignment.Left
scheduleLabel.TextYAlignment = Enum.TextYAlignment.Top
scheduleLabel.Text = ""
scheduleLabel.Parent = scheduleHud

local scheduleCorner = Instance.new("UICorner")
scheduleCorner.CornerRadius = UDim.new(0, 8)
scheduleCorner.Parent = scheduleLabel

---------------------------------------------------------------------
-- Player
---------------------------------------------------------------------

local function applyWalkSpeed()
	local humanoid = getHumanoid()
	if humanoid then
		humanoid.WalkSpeed = Settings.SpeedBoost and Settings.WalkSpeed or DEFAULT_WALK_SPEED
	end
end

local function applyFov()
	local camera = workspace.CurrentCamera
	if camera then
		camera.FieldOfView = Settings.FovBoost and Settings.Fov or DEFAULT_FOV
	end
end

-- Pins the client's displayed suspicion to zero while enabled.
local suspicionFrozen = false
ctx:Connect(LocalPlayer:GetAttributeChangedSignal("Suspicion"), function()
	if suspicionFrozen and LocalPlayer:GetAttribute("Suspicion") ~= 0 then
		LocalPlayer:SetAttribute("Suspicion", 0)
	end
end)

---------------------------------------------------------------------
-- UI
---------------------------------------------------------------------

local Combat = ctx:SubTab("Combat", "Lucide:swords")
local Escape = ctx:SubTab("Escape", "Lucide:pickaxe")
local Farm = ctx:SubTab("Farm", "Lucide:coins")
local Visuals = ctx:SubTab("Visuals", "Lucide:eye")
local Player = ctx:SubTab("Player", "Lucide:user")

Combat:AddSection("Attacking", "Lucide:sword")
Combat:AddToggle({
	Text = "Auto Punch",
	Description = "Fires punches repeatedly while your fists are out",
	Icon = "Lucide:hand",
	Default = false,
	Flag = "13de_auto_punch",
	Callback = function(value)
		Settings.AutoPunch = value
	end,
})
Combat:AddToggle({
	Text = "Auto Attack",
	Description = "Swings the equipped knife, bat or screwdriver automatically",
	Icon = "Lucide:sword",
	Default = false,
	Flag = "13de_auto_attack",
	Callback = function(value)
		Settings.AutoAttack = value
	end,
})

Combat:AddSection("Assassination", "Lucide:target")
Combat:AddToggle({
	Text = "Auto Kill Target",
	Description = "Walks to and attacks your current OJ assassination target",
	Icon = "Lucide:crosshair",
	Default = false,
	Flag = "13de_auto_kill_target",
	Callback = function(value)
		Settings.AutoKillTarget = value
	end,
})
Combat:AddSlider({
	Text = "Kill Range",
	Description = "How close you must be before attacking the target",
	Icon = "Lucide:target",
	Min = 3,
	Max = 15,
	Default = 6,
	Increment = 1,
	Suffix = " studs",
	Flag = "13de_kill_range",
	Callback = function(value)
		Settings.KillRange = value
	end,
})

Escape:AddSection("Full Escape", "Lucide:map-pin")
Escape:AddToggle({
	Text = "Auto Escape",
	Description = "Unscrews the toilet, opens the panel and digs the tunnel",
	Icon = "Lucide:map-pin",
	Default = false,
	Flag = "13de_auto_escape",
	Callback = function(value)
		Settings.AutoEscape = value
	end,
})
Escape:AddToggle({
	Text = "Auto Saw Bars",
	Description = "Equips the saw and cuts through your cell window bars",
	Icon = "Lucide:scissors",
	Default = false,
	Flag = "13de_auto_saw",
	Callback = function(value)
		Settings.AutoSaw = value
	end,
})

Escape:AddSection("Digging", "Lucide:shovel")
Escape:AddToggle({
	Text = "Auto Dig",
	Description = "Digs repeatedly with the equipped spoon, trowel or drill",
	Icon = "Lucide:shovel",
	Default = false,
	Flag = "13de_auto_dig",
	Callback = function(value)
		Settings.AutoDig = value
	end,
})
Escape:AddToggle({
	Text = "Auto Break",
	Description = "Breaks vents and barriers repeatedly with the hammer",
	Icon = "Lucide:wrench",
	Default = false,
	Flag = "13de_auto_break",
	Callback = function(value)
		Settings.AutoBreak = value
	end,
})

Farm:AddSection("Kitchen Jobs", "Lucide:coins")
Farm:AddToggle({
	Text = "Auto Chop",
	Description = "Chops vegetables automatically while at the kitchen station",
	Icon = "Lucide:cog",
	Default = false,
	Flag = "13de_auto_chop",
	Callback = function(value)
		Settings.AutoChop = value
	end,
})
Farm:AddToggle({
	Text = "Auto Peel",
	Description = "Finishes peeling potatoes automatically while at the kitchen station",
	Icon = "Lucide:zap",
	Default = false,
	Flag = "13de_auto_peel",
	Callback = function(value)
		Settings.AutoPeel = value
	end,
})

Farm:AddSection("Cash", "Lucide:wallet")
Farm:AddToggle({
	Text = "Auto Collect Cash",
	Description = "Triggers every cash pile's steal prompt, regardless of distance",
	Icon = "Lucide:coins",
	Default = false,
	Flag = "13de_auto_cash",
	Callback = function(value)
		Settings.AutoCash = value
	end,
})

Farm:AddSection("Yard", "Lucide:trash-2")
Farm:AddToggle({
	Text = "Auto Pickup Trash",
	Description = "Collects trash litter near you during the yard job",
	Icon = "Lucide:trash-2",
	Default = false,
	Flag = "13de_auto_trash",
	Callback = function(value)
		Settings.TrashPickup = value
	end,
})
Farm:AddSlider({
	Text = "Trash Range",
	Description = "How close litter must be before it is collected",
	Icon = "Lucide:target",
	Min = 3,
	Max = 30,
	Default = 12,
	Increment = 1,
	Suffix = " studs",
	Flag = "13de_trash_range",
	Callback = function(value)
		Settings.TrashRange = value
	end,
})

Farm:AddSection("Library", "Lucide:scroll-text")
Farm:AddToggle({
	Text = "Auto Farm Books",
	Description = "Takes your requested library book and delivers it to the clerk",
	Icon = "Lucide:book",
	Default = false,
	Flag = "13de_auto_books",
	Callback = function(value)
		Settings.AutoBooks = value
	end,
})

Visuals:AddSection("Schedule", "Lucide:timer")
Visuals:AddToggle({
	Text = "Show Schedule HUD",
	Description = "Shows the current day, phase and lockdown state on screen",
	Icon = "Lucide:timer",
	Default = false,
	Flag = "13de_schedule_hud",
	Callback = function(value)
		Settings.ShowSchedule = value
		scheduleHud.Enabled = value
		if value then
			local ok, text = pcall(getScheduleText)
			if ok then
				scheduleLabel.Text = text
			end
		end
	end,
})

Visuals:AddSection("Enemies", "Lucide:skull")
Visuals:AddToggle({
	Text = "Guard ESP",
	Description = "Shows guards with their alert level through walls",
	Icon = "Lucide:eye",
	Default = false,
	Flag = "13de_guard_esp",
	Callback = function(value)
		Settings.GuardEsp = value
	end,
})
Visuals:AddToggle({
	Text = "Sentry ESP",
	Description = "Shows tower sentries",
	Icon = "Lucide:crosshair",
	Default = false,
	Flag = "13de_sentry_esp",
	Callback = function(value)
		Settings.SentryEsp = value
	end,
})

Visuals:AddSection("Targets", "Lucide:crosshair")
Visuals:AddToggle({
	Text = "Target ESP",
	Description = "Highlights your current OJ assassination target",
	Icon = "Lucide:target",
	Default = false,
	Flag = "13de_target_esp",
	Callback = function(value)
		Settings.TargetEsp = value
	end,
})
Visuals:AddToggle({
	Text = "Book ESP",
	Description = "Highlights the library book your job asks for",
	Icon = "Lucide:book",
	Default = false,
	Flag = "13de_book_esp",
	Callback = function(value)
		Settings.BookEsp = value
	end,
})

Visuals:AddSection("Money", "Lucide:wallet")
Visuals:AddToggle({
	Text = "Money ESP",
	Description = "Labels cash piles you can steal with their value",
	Icon = "Lucide:wallet",
	Default = false,
	Flag = "13de_money_esp",
	Callback = function(value)
		Settings.MoneyEsp = value
	end,
})

Visuals:AddSection("Cameras", "Lucide:camera")
Visuals:AddToggle({
	Text = "Camera ESP",
	Description = "Shows security cameras and whether they are active",
	Icon = "Lucide:camera",
	Default = false,
	Flag = "13de_camera_esp",
	Callback = function(value)
		Settings.CameraEsp = value
	end,
})
Visuals:AddToggle({
	Text = "Break Cameras",
	Description = "Marks every security camera broken on your client",
	Icon = "Lucide:camera",
	Default = false,
	Flag = "13de_break_cameras",
	Callback = function(value)
		Settings.BreakCameras = value
	end,
})

Visuals:AddSection("Warden", "Lucide:ghost")
Visuals:AddToggle({
	Text = "Warden ESP",
	Description = "Shows the night warden's position",
	Icon = "Lucide:ghost",
	Default = false,
	Flag = "13de_warden_esp",
	Callback = function(value)
		Settings.WardenEsp = value
	end,
})

Visuals:AddSlider({
	Text = "ESP Distance",
	Description = "How far away ESP targets are drawn",
	Icon = "Lucide:radar",
	Min = 50,
	Max = 2000,
	Default = 500,
	Increment = 50,
	Suffix = " studs",
	Flag = "13de_esp_distance",
	Callback = function(value)
		Settings.EspDistance = value
	end,
})

Player:AddSection("Movement", "Lucide:gauge")
Player:AddToggle({
	Text = "Speed Boost",
	Description = "Sets your walking speed to the value below",
	Icon = "Lucide:rabbit",
	Default = false,
	Flag = "13de_speed_boost",
	Callback = function(value)
		Settings.SpeedBoost = value
		applyWalkSpeed()
	end,
})
Player:AddSlider({
	Text = "Walk Speed",
	Description = "Speed used while Speed Boost is on",
	Icon = "Lucide:gauge",
	Min = 16,
	Max = 100,
	Default = 30,
	Increment = 1,
	Suffix = " studs",
	Flag = "13de_walk_speed",
	Callback = function(value)
		Settings.WalkSpeed = value
		applyWalkSpeed()
	end,
})

Player:AddSection("View", "Lucide:eye")
Player:AddToggle({
	Text = "FOV Boost",
	Description = "Widens the camera field of view",
	Icon = "Lucide:eye",
	Default = false,
	Flag = "13de_fov_boost",
	Callback = function(value)
		Settings.FovBoost = value
		applyFov()
	end,
})
Player:AddSlider({
	Text = "FOV",
	Description = "Field of view used while FOV Boost is on",
	Icon = "Lucide:eye",
	Min = 70,
	Max = 140,
	Default = 100,
	Increment = 1,
	Flag = "13de_fov",
	Callback = function(value)
		Settings.Fov = value
		applyFov()
	end,
})

Player:AddSection("Comfort", "Lucide:ghost")
Player:AddToggle({
	Text = "Reduce Jumpscares",
	Description = "Softens horror and anomaly effects with the game's reduced motion setting",
	Icon = "Lucide:ghost",
	Default = false,
	Flag = "13de_reduced_motion",
	Callback = function(value)
		ctx:SetAttribute(LocalPlayer, "ReducedMotion", value)
	end,
})

Player:AddSection("Stealth", "Lucide:shield")
Player:AddToggle({
	Text = "Freeze Suspicion",
	Description = "Pins the suspicion meter to zero",
	Icon = "Lucide:eye-off",
	Default = false,
	Flag = "13de_freeze_suspicion",
	Callback = function(value)
		suspicionFrozen = value
		if value then
			LocalPlayer:SetAttribute("Suspicion", 0)
		end
	end,
})

---------------------------------------------------------------------
-- Background loops
---------------------------------------------------------------------

task.spawn(function()
	while ctx:Alive() do
		if Settings.AutoPunch then
			pcall(firePunch)
			task.wait(0.05)
		else
			task.wait(0.2)
		end
	end
end)

task.spawn(function()
	while ctx:Alive() do
		if Settings.AutoAttack or Settings.AutoDig or Settings.AutoBreak then
			pcall(fireTool)
			task.wait(0.05)
		else
			task.wait(0.2)
		end
	end
end)

task.spawn(function()
	while ctx:Alive() do
		if Settings.AutoKillTarget then
			pcall(autoKillStep)
			task.wait(0.1)
		else
			task.wait(0.2)
		end
	end
end)

task.spawn(function()
	while ctx:Alive() do
		if LocalPlayer:GetAttribute("RunEnded") or LocalPlayer:GetAttribute("DeathPresented") then
			chopToken = nil
			chopCuts = 0
			peel.token = nil
		end
		if Settings.AutoChop then
			pcall(fireChop)
		end
		if Settings.AutoPeel then
			pcall(firePeel)
		end
		task.wait(0.1)
	end
end)

task.spawn(function()
	while ctx:Alive() do
		if Settings.SpeedBoost then
			pcall(applyWalkSpeed)
		end
		if Settings.FovBoost then
			pcall(applyFov)
		end
		task.wait(0.5)
	end
end)

task.spawn(function()
	while ctx:Alive() do
		if anyEspEnabled() then
			pcall(espStep)
			task.wait(0.1)
		else
			pcall(clearEsp)
			task.wait(0.5)
		end
	end
end)

task.spawn(function()
	while ctx:Alive() do
		if Settings.ShowSchedule and scheduleHud.Enabled then
			local ok, text = pcall(getScheduleText)
			if ok then
				pcall(function()
					scheduleLabel.Text = text
				end)
			end
		end
		task.wait(1)
	end
end)

task.spawn(function()
	while ctx:Alive() do
		if Settings.AutoCash then
			pcall(cashStep)
		end
		task.wait(0.15)
	end
end)

task.spawn(function()
	while ctx:Alive() do
		if Settings.AutoBooks then
			pcall(bookStep)
		end
		task.wait(0.15)
	end
end)

task.spawn(function()
	while ctx:Alive() do
		if Settings.BreakCameras then
			pcall(cameraStep)
		end
		task.wait(0.5)
	end
end)

task.spawn(function()
	while ctx:Alive() do
		if Settings.TrashPickup then
			pcall(trashStep)
		end
		task.wait(0.15)
	end
end)

task.spawn(function()
	while ctx:Alive() do
		if Settings.AutoEscape then
			pcall(escapeStep)
		end
		task.wait(0.2)
	end
end)

task.spawn(function()
	while ctx:Alive() do
		if Settings.AutoSaw then
			pcall(sawStep)
		end
		task.wait(0.2)
	end
end)

ctx:Connect(LocalPlayer.CharacterAdded, function(character)
	if Settings.SpeedBoost then
		local humanoid = character:WaitForChild("Humanoid", 5)
		if humanoid then
			humanoid.WalkSpeed = Settings.WalkSpeed
		end
	end
end)

ctx:Connect(workspace:GetPropertyChangedSignal("CurrentCamera"), applyFov)

---------------------------------------------------------------------
-- Shutdown
---------------------------------------------------------------------

ctx:OnCleanup(function()
	Settings.AutoPunch, Settings.AutoAttack, Settings.AutoDig, Settings.AutoBreak = false, false, false, false
	Settings.AutoKillTarget = false
	Settings.ShowSchedule = false
	Settings.AutoCash, Settings.AutoBooks = false, false
	Settings.BreakCameras = false
	Settings.TrashPickup = false
	Settings.AutoEscape = false
	Settings.AutoSaw = false
	Settings.AutoChop, Settings.AutoPeel = false, false
	chopToken = nil
	chopCuts = 0
	peel.token = nil
	clearEsp()
	local humanoid = getHumanoid()
	if humanoid then
		humanoid.WalkSpeed = DEFAULT_WALK_SPEED
	end
	local camera = workspace.CurrentCamera
	if camera then
		camera.FieldOfView = DEFAULT_FOV
	end
end)
