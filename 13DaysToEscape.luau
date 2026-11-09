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
}

---------------------------------------------------------------------
-- Combat
---------------------------------------------------------------------

local swingCount = 0
local nextPunchAt = 0
local nextToolAt = 0

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
-- Visuals (ESP + schedule)
---------------------------------------------------------------------

local espFolder = ctx:Track(Instance.new("Folder"))
espFolder.Name = "Sk8rne13DEsp"
espFolder.Parent = (gethui and gethui()) or game:GetService("CoreGui")

local espEntries = {}

local ESP_COLORS = {
	Guard = Color3.fromRGB(255, 96, 96),
	Camera = Color3.fromRGB(255, 200, 80),
	Warden = Color3.fromRGB(200, 96, 255),
	Sentry = Color3.fromRGB(96, 220, 255),
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
	return model:FindFirstChild("HumanoidRootPart")
		or model:FindFirstChild("Lens")
		or model.PrimaryPart
end

local function createEsp(model, part, category)
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(220, 46)
	gui.StudsOffset = Vector3.new(0, 3.2, 0)
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
end

local function clearEsp()
	for _, entry in pairs(espEntries) do
		entry.Gui:Destroy()
	end
	table.clear(espEntries)
end

local function anyEspEnabled()
	return Settings.GuardEsp or Settings.CameraEsp or Settings.WardenEsp or Settings.SentryEsp
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

Visuals:AddSection("Schedule", "Lucide:timer")
local schedulePara = Visuals:AddParagraph({
	Title = "Prison Schedule",
	Icon = "Lucide:timer",
	Text = getScheduleText(),
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
			task.wait(0.25)
		end
	end
end)

task.spawn(function()
	while ctx:Alive() do
		local ok, text = pcall(getScheduleText)
		if ok then
			schedulePara:Set(text)
		end
		task.wait(1)
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
