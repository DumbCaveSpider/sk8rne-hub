-- BATTLEPATH!
local ctx = ...
local task = ctx.task

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local LocalPlayer = Players.LocalPlayer

local function tryRequire(name)
	local module = ReplicatedStorage:FindFirstChild(name)
	if not module then
		return nil
	end
	local ok, result = pcall(require, module)
	return ok and result or nil
end

-- The game's input modules each expose Begin/End BindableEvents we can fire to simulate keys.
local DashInput = tryRequire("LShiftInput")
local SlideInput = tryRequire("LCtrlInput")
local ParryInput = tryRequire("FInput")

local Settings = {
	SpeedOn = false,
	Speed = 30,
	JumpOn = false,
	JumpPower = 90,
	InfiniteDash = false,
	AutoDash = false,
	AutoSlide = false,
	EnemyEsp = false,
	TixEsp = false,
	ParryEsp = false,
	EspDistance = 500,
	AutoParry = false,
	AutoFire = false,
	HitAll = false,
}

local function getCharacter()
	return LocalPlayer.Character
end

local function getRootPart()
	local character = LocalPlayer.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end

local function getHumanoid()
	local character = LocalPlayer.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

local function isPlayerAlive()
	local humanoid = getHumanoid()
	return humanoid ~= nil and humanoid.Health > 0
end

---------------------------------------------------------------------
-- ESP
---------------------------------------------------------------------

local espFolder = ctx:Track(Instance.new("Folder"))
espFolder.Name = "Sk8rneBattlepathEsp"
espFolder.Parent = LocalPlayer:WaitForChild("PlayerGui")

local espEntries = {}

local function createEsp(model, part, text, color)
	local gui = Instance.new("BillboardGui")
	gui.Name = "Sk8rneEsp"
	gui.Size = UDim2.fromOffset(200, 42)
	gui.StudsOffset = Vector3.new(0, 3, 0)
	gui.AlwaysOnTop = true
	gui.Adornee = part
	gui.Parent = espFolder

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 13
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.4
	label.Text = text
	label.Parent = gui

	local entry = { Gui = gui, Label = label }
	espEntries[model] = entry
	return entry
end

local ENEMY_COLOR = Color3.fromRGB(255, 120, 120)
local TIX_COLOR = Color3.fromRGB(255, 220, 60)
local PARRY_COLOR = Color3.fromRGB(80, 200, 255)

local function collectTargets()
	local targets = {}
	local myRoot = getRootPart()
	if not myRoot then
		return targets
	end

	if Settings.EnemyEsp then
		local active = workspace:FindFirstChild("Active")
		if active then
			for _, model in ipairs(active:GetChildren()) do
				local humanoid = model:FindFirstChildOfClass("Humanoid")
				local root = model:FindFirstChild("HumanoidRootPart")
				if humanoid and humanoid.Health > 0 and root then
					local distance = (root.Position - myRoot.Position).Magnitude
					if distance <= Settings.EspDistance then
						table.insert(targets, {
							Model = model,
							Part = root,
							Color = ENEMY_COLOR,
							Text = string.format("%s\n%d HP  %d studs", model.Name, math.ceil(humanoid.Health), math.floor(distance)),
						})
					end
				end
			end
		end
	end

	if Settings.TixEsp then
		for _, child in ipairs(workspace:GetChildren()) do
			if child:IsA("BasePart") and child.Name == "Tix" then
				local distance = (child.Position - myRoot.Position).Magnitude
				if distance <= Settings.EspDistance then
					table.insert(targets, {
						Model = child,
						Part = child,
						Color = TIX_COLOR,
						Text = string.format("TIX\n%d studs", math.floor(distance)),
					})
				end
			end
		end
	end

	if Settings.ParryEsp then
		for _, player in ipairs(Players:GetPlayers()) do
			if player ~= LocalPlayer and player.Character and CollectionService:HasTag(player, "Parry") then
				local root = player.Character:FindFirstChild("HumanoidRootPart")
				if root then
					local distance = (root.Position - myRoot.Position).Magnitude
					if distance <= Settings.EspDistance then
						table.insert(targets, {
							Model = player.Character,
							Part = root,
							Color = PARRY_COLOR,
							Text = string.format("%s\nPARRY", player.Name),
						})
					end
				end
			end
		end
	end

	return targets
end

local function espStep()
	local targets = collectTargets()
	local visible = {}
	for _, target in ipairs(targets) do
		visible[target.Model] = true
		local entry = espEntries[target.Model]
		if not entry then
			entry = createEsp(target.Model, target.Part, target.Text, target.Color)
		end
		entry.Gui.Adornee = target.Part
		entry.Label.Text = target.Text
		entry.Label.TextColor3 = target.Color
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
	return Settings.EnemyEsp or Settings.TixEsp or Settings.ParryEsp
end

---------------------------------------------------------------------
-- Player
---------------------------------------------------------------------

local function applySpeed()
	local humanoid = getHumanoid()
	if humanoid then
		humanoid.WalkSpeed = Settings.SpeedOn and Settings.Speed or 16
	end
end

local function applyJump()
	local humanoid = getHumanoid()
	if humanoid then
		humanoid.UseJumpPower = true
		humanoid.JumpPower = Settings.JumpOn and Settings.JumpPower or 70
	end
end

local function applyDash()
	if not Settings.InfiniteDash then
		return
	end
	local character = getCharacter()
	local dashCount = character and character:FindFirstChild("DashCount")
	if dashCount and dashCount:IsA("IntValue") then
		dashCount.Value = 99
	end
end

local function fireEvent(module, eventName)
	if not module then
		return
	end
	local event = module[eventName]
	if event and event:IsA("BindableEvent") then
		event:Fire()
	end
end

local function autoDash()
	if DashInput then
		fireEvent(DashInput, "Began")
	end
end

local function autoSlide()
	if SlideInput then
		fireEvent(SlideInput, "Began")
		task.delay(0.15, function()
			fireEvent(SlideInput, "Ended")
		end)
	end
end

local function autoParry()
	if ParryInput then
		fireEvent(ParryInput, "Began")
		task.delay(0.1, function()
			fireEvent(ParryInput, "Ended")
		end)
	end
end

local nextFireAt = 0
local FIRE_INTERVAL = 0.12

local function autoFire()
	local now = os.clock()
	if now < nextFireAt then
		return
	end
	nextFireAt = now + FIRE_INTERVAL
	local character = getCharacter()
	local tool = character and character:FindFirstChildOfClass("Tool")
	if tool then
		pcall(function()
			tool:Activate()
		end)
	end
end

---------------------------------------------------------------------
-- Blaster hit-all hook
---------------------------------------------------------------------

-- The blaster raycasts client-side and sends the hit humanoids to the server, so we can
-- widen that table to include every live enemy.
local Blaster = ReplicatedStorage:FindFirstChild("Blaster")
local BlasterRemotes = Blaster and Blaster:FindFirstChild("Remotes")
local ShootRemote = BlasterRemotes and BlasterRemotes:FindFirstChild("Shoot")

if ShootRemote then
	ctx:HookMeta(ShootRemote, "__namecall", function(old, self, ...)
		if self == ShootRemote and getnamecallmethod() == "FireServer" and Settings.HitAll then
			local args = table.pack(...)
			if type(args[4]) == "table" then
				local hits = {}
				local index = 0
				local active = workspace:FindFirstChild("Active")
				if active then
					for _, model in ipairs(active:GetChildren()) do
						local humanoid = model:FindFirstChildOfClass("Humanoid")
						if humanoid and humanoid.Health > 0 then
							index += 1
							hits[tostring(index)] = humanoid
						end
					end
				end
				args[4] = hits
			end
			return old(self, table.unpack(args, 1, args.n))
		end
		return old(self, ...)
	end)
end

---------------------------------------------------------------------
-- UI
---------------------------------------------------------------------

local Player = ctx:SubTab("Player", "Lucide:user")
local Combat = ctx:SubTab("Combat", "Lucide:swords")
local Visuals = ctx:SubTab("Visuals", "Lucide:eye")

Player:AddSection("Movement", "Lucide:gauge")
Player:AddToggle({
	Text = "Speed Boost",
	Description = "Overrides your walk speed",
	Icon = "Lucide:rabbit",
	Default = false,
	Flag = "bp_speed_on",
	Callback = function(value)
		Settings.SpeedOn = value
		applySpeed()
	end,
})
Player:AddSlider({
	Text = "Walk Speed",
	Description = "Speed used while Speed Boost is on",
	Icon = "Lucide:gauge",
	Min = 16,
	Max = 120,
	Default = 30,
	Increment = 1,
	Suffix = " studs",
	Flag = "bp_speed",
	Callback = function(value)
		Settings.Speed = value
		applySpeed()
	end,
})
Player:AddToggle({
	Text = "Jump Boost",
	Description = "Overrides your jump power",
	Icon = "Lucide:arrow-up",
	Default = false,
	Flag = "bp_jump_on",
	Callback = function(value)
		Settings.JumpOn = value
		applyJump()
	end,
})
Player:AddSlider({
	Text = "Jump Power",
	Description = "Jump power used while Jump Boost is on",
	Icon = "Lucide:arrow-up",
	Min = 70,
	Max = 300,
	Default = 90,
	Increment = 5,
	Flag = "bp_jump",
	Callback = function(value)
		Settings.JumpPower = value
		applyJump()
	end,
})

Player:AddSection("Dash", "Lucide:zap")
Player:AddToggle({
	Text = "Infinite Dash",
	Description = "Keeps your dash charge topped up",
	Icon = "Lucide:zap",
	Default = false,
	Flag = "bp_infinite_dash",
	Callback = function(value)
		Settings.InfiniteDash = value
	end,
})
Player:AddToggle({
	Text = "Auto Dash",
	Description = "Fires the dash input automatically",
	Icon = "Lucide:zap",
	Default = false,
	Flag = "bp_auto_dash",
	Callback = function(value)
		Settings.AutoDash = value
	end,
})
Player:AddToggle({
	Text = "Auto Slide",
	Description = "Fires the slide input automatically",
	Icon = "Lucide:move-down",
	Default = false,
	Flag = "bp_auto_slide",
	Callback = function(value)
		Settings.AutoSlide = value
	end,
})

Combat:AddSection("Attack", "Lucide:swords")
Combat:AddToggle({
	Text = "Auto Parry",
	Description = "Spams the parry input",
	Icon = "Lucide:shield",
	Default = false,
	Flag = "bp_auto_parry",
	Callback = function(value)
		Settings.AutoParry = value
	end,
})
Combat:AddToggle({
	Text = "Auto Fire",
	Description = "Activates your equipped tool repeatedly",
	Icon = "Lucide:crosshair",
	Default = false,
	Flag = "bp_auto_fire",
	Callback = function(value)
		Settings.AutoFire = value
	end,
})

Combat:AddSection("Blaster", "Lucide:crosshair")
Combat:AddToggle({
	Text = "Hit All Enemies",
	Description = "Sends every live enemy to the blaster as a hit",
	Icon = "Lucide:target",
	Default = false,
	Flag = "bp_hit_all",
	Callback = function(value)
		Settings.HitAll = value
	end,
})

Visuals:AddSection("ESP", "Lucide:eye")
Visuals:AddToggle({
	Text = "Enemy ESP",
	Description = "Shows active enemies with health and distance",
	Icon = "Lucide:skull",
	Default = false,
	Flag = "bp_enemy_esp",
	Callback = function(value)
		Settings.EnemyEsp = value
	end,
})
Visuals:AddToggle({
	Text = "Tix ESP",
	Description = "Shows floating Tix pickups",
	Icon = "Lucide:coins",
	Default = false,
	Flag = "bp_tix_esp",
	Callback = function(value)
		Settings.TixEsp = value
	end,
})
Visuals:AddToggle({
	Text = "Parry ESP",
	Description = "Shows players currently tagged for parry",
	Icon = "Lucide:shield",
	Default = false,
	Flag = "bp_parry_esp",
	Callback = function(value)
		Settings.ParryEsp = value
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
	Flag = "bp_esp_distance",
	Callback = function(value)
		Settings.EspDistance = value
	end,
})

---------------------------------------------------------------------
-- Background loops
---------------------------------------------------------------------

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
		if Settings.SpeedOn then
			pcall(applySpeed)
		end
		if Settings.JumpOn then
			pcall(applyJump)
		end
		if Settings.InfiniteDash then
			pcall(applyDash)
		end
		task.wait(0.25)
	end
end)

task.spawn(function()
	while ctx:Alive() do
		if Settings.AutoDash and isPlayerAlive() then
			pcall(autoDash)
		end
		if Settings.AutoSlide and isPlayerAlive() then
			pcall(autoSlide)
		end
		if Settings.AutoParry and isPlayerAlive() then
			pcall(autoParry)
		end
		task.wait(0.35)
	end
end)

task.spawn(function()
	while ctx:Alive() do
		if Settings.AutoFire and isPlayerAlive() then
			pcall(autoFire)
		end
		task.wait(0.05)
	end
end)

ctx:Connect(LocalPlayer.CharacterAdded, function(character)
	local humanoid = character:WaitForChild("Humanoid", 5)
	if humanoid then
		if Settings.SpeedOn then
			humanoid.WalkSpeed = Settings.Speed
		end
		if Settings.JumpOn then
			humanoid.UseJumpPower = true
			humanoid.JumpPower = Settings.JumpPower
		end
	end
end)

---------------------------------------------------------------------
-- Shutdown
---------------------------------------------------------------------

ctx:OnCleanup(function()
	Settings.SpeedOn, Settings.JumpOn = false, false
	Settings.InfiniteDash, Settings.AutoDash, Settings.AutoSlide = false, false, false
	Settings.AutoParry, Settings.AutoFire, Settings.HitAll = false, false, false
	clearEsp()
	local humanoid = getHumanoid()
	if humanoid then
		humanoid.WalkSpeed = 16
		humanoid.UseJumpPower = true
		humanoid.JumpPower = 70
	end
end)
