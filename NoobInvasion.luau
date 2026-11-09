-- NOOB INVASION
local ctx = ...
local task = ctx.task

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
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
	ctx:Log("[NI] " .. message, level or "info")
end

ctx:Log("[NI] module loaded", "info")

local Settings = {
	SpeedOn = false,
	Speed = 30,
	JumpOn = false,
	JumpPower = 100,
	InfiniteJump = false,
	Godmode = false,
	AutoPunch = false,
	AutoUppercut = false,
	AutoMove = false,
	MoveId = "Beam",
	AutoRevive = false,
	EspNoob = false,
	EspBoss = false,
	EspDistance = 500,
}

---------------------------------------------------------------------
-- Remotes
---------------------------------------------------------------------

local function remote(name, folderName)
	local folder = ReplicatedStorage:FindFirstChild(folderName or "Remotes")
	return folder and folder:FindFirstChild(name)
end

local function fireRemote(name, ...)
	local event = remote(name)
	if not (event and event:IsA("RemoteEvent")) then
		logOnce("remote_missing_" .. name, "remote not found: " .. name, "warn")
		return false
	end
	local args = table.pack(...)
	pcall(function()
		event:FireServer(table.unpack(args, 1, args.n))
	end)
	return true
end

---------------------------------------------------------------------
-- ESP
---------------------------------------------------------------------

local overlay = ctx:Track(Instance.new("ScreenGui"))
overlay.Name = "Sk8rneNoobInvasion"
overlay.ResetOnSpawn = false
overlay.IgnoreGuiInset = true
overlay.Parent = LocalPlayer:WaitForChild("PlayerGui")

local espEntries = {}

local function espPart(instance)
	if instance:IsA("BasePart") then
		return instance
	end
	if instance:IsA("Model") then
		return instance.PrimaryPart or instance:FindFirstChild("HumanoidRootPart") or instance:FindFirstChildWhichIsA("BasePart", true)
	end
	return instance:FindFirstChildWhichIsA("BasePart", true)
end

local function createEsp(instance, part, color, text)
	local gui = Instance.new("BillboardGui")
	gui.Name = "Sk8rneEsp"
	gui.Size = UDim2.fromOffset(190, 44)
	gui.StudsOffset = Vector3.new(0, 4, 0)
	gui.AlwaysOnTop = true
	gui.Adornee = part
	gui.Parent = overlay

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 13
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.4
	label.Text = text
	label.Parent = gui

	local highlight = Instance.new("Highlight")
	highlight.Name = "Sk8rneEspHighlight"
	highlight.Adornee = instance
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.FillColor = color
	highlight.FillTransparency = 0.8
	highlight.OutlineColor = color
	highlight.OutlineTransparency = 0
	highlight.Parent = instance

	local entry = { Gui = gui, Label = label, Highlight = highlight }
	espEntries[instance] = entry
	return entry
end

local function noobsFolder()
	return workspace:FindFirstChild("Noobs")
end

local function espStep()
	local myRoot = getRootPart()
	local folder = noobsFolder()
	if not myRoot or not folder then
		return
	end
	local visible = {}
	for _, model in ipairs(folder:GetDescendants()) do
		if model:IsA("Model") and model ~= LocalPlayer.Character then
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			local part = espPart(model)
			if humanoid and humanoid.Health > 0 and part then
				local bossName = model:GetAttribute("BossName")
				local isBoss = bossName ~= nil
				if (isBoss and Settings.EspBoss) or (not isBoss and Settings.EspNoob) then
					local distance = (part.Position - myRoot.Position).Magnitude
					if distance <= Settings.EspDistance then
						local text = string.format(
							"%s\n%d HP  %d studs",
							isBoss and ("BOSS: " .. tostring(bossName)) or model.Name,
							math.ceil(humanoid.Health),
							math.floor(distance)
						)
						local color = isBoss and Color3.fromRGB(255, 80, 255) or Color3.fromRGB(255, 120, 120)
						visible[model] = true
						local entry = espEntries[model]
						if not entry then
							entry = createEsp(model, part, color, text)
						end
						entry.Gui.Adornee = part
						entry.Label.Text = text
					end
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
-- Player helpers
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
		humanoid.JumpPower = Settings.JumpOn and Settings.JumpPower or 50
	end
end

local function applyGodmode()
	local humanoid = getHumanoid()
	if humanoid and humanoid.Health > 0 then
		if humanoid.Health < humanoid.MaxHealth then
			pcall(function()
				humanoid.Health = humanoid.MaxHealth
			end)
		end
	end
	pcall(function()
		LocalPlayer:SetAttribute("Shield", 9999)
		LocalPlayer:SetAttribute("ShieldMax", 9999)
	end)
	logOnce("godmode_ok", "godmode: keeping health and shield topped", "info")
end

---------------------------------------------------------------------
-- Combat
---------------------------------------------------------------------

local PUNCHES = { "punch1", "punch2", "punch3" }
local punchIndex = 0
local nextPunchAt = 0

local function autoPunchStep()
	local now = os.clock()
	if now < nextPunchAt then
		return
	end
	nextPunchAt = now + 0.25
	punchIndex = punchIndex % #PUNCHES + 1
	fireRemote("Attack", PUNCHES[punchIndex])
	logOnce("punch_ok", "auto punch: sending punch combos", "info")
end

local nextUppercutAt = 0
local function autoUppercutStep()
	local now = os.clock()
	if now < nextUppercutAt then
		return
	end
	nextUppercutAt = now + 3.2
	fireRemote("Attack", "uppercut")
	logOnce("uppercut_ok", "auto uppercut: launching noobs", "info")
end

local MOVE_LIST = {
	{ id = "Uppercut", name = "Uppercut" },
	{ id = "Beam", name = "Hand Beam" },
	{ id = "Shadow", name = "Shadow Dash" },
	{ id = "Dodgeball", name = "Dodgeball" },
	{ id = "Lightning", name = "Lightning Punch" },
	{ id = "Quake", name = "Ground Slam" },
	{ id = "Purple", name = "Hollow Purple" },
	{ id = "Picture", name = "Picture Perfect" },
}
local moveNameToId = {}
local moveNames = {}
for _, move in ipairs(MOVE_LIST) do
	table.insert(moveNames, move.name)
	moveNameToId[move.name] = move.id
end

local nextMoveAt = 0
local function autoMoveStep()
	local now = os.clock()
	if now < nextMoveAt then
		return
	end
	nextMoveAt = now + 2
	fireRemote("Attack", Settings.MoveId)
	logOnce("move_ok", "auto move: using " .. Settings.MoveId, "info")
end

---------------------------------------------------------------------
-- Farm
---------------------------------------------------------------------

local nextReviveAt = 0
local function autoReviveStep()
	local now = os.clock()
	if now < nextReviveAt then
		return
	end
	nextReviveAt = now + 3
	local humanoid = getHumanoid()
	if humanoid and humanoid.Health > 0 and LocalPlayer.Character then
		return
	end
	fireRemote("Life", "again")
	logOnce("revive_ok", "auto revive: asking to play again", "info")
end

---------------------------------------------------------------------
-- Shop
---------------------------------------------------------------------

local function buyMove(moveId)
	fireRemote("MoveShop", "buy", moveId)
	logOnce("buy_" .. moveId, "shop: buying " .. moveId, "info")
end

local function equipMove(moveId)
	fireRemote("MoveShop", "equip", moveId)
	logOnce("equip_" .. moveId, "shop: equipping " .. moveId, "info")
end

---------------------------------------------------------------------
-- UI
---------------------------------------------------------------------

local Player = ctx:SubTab("Player", "Lucide:user")
local Combat = ctx:SubTab("Combat", "Lucide:swords")
local Farm = ctx:SubTab("Farm", "Lucide:coins")
local Visuals = ctx:SubTab("Visuals", "Lucide:eye")

Player:AddSection("Movement", "Lucide:gauge")
Player:AddToggle({
	Text = "Speed Boost",
	Description = "Overrides your walk speed",
	Icon = "Lucide:rabbit",
	Default = false,
	Flag = "ni_speed_on",
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
	Max = 150,
	Default = 30,
	Increment = 1,
	Suffix = " studs",
	Flag = "ni_speed",
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
	Flag = "ni_jump_on",
	Callback = function(value)
		Settings.JumpOn = value
		applyJump()
	end,
})
Player:AddSlider({
	Text = "Jump Power",
	Description = "Jump power used while Jump Boost is on",
	Icon = "Lucide:arrow-up",
	Min = 50,
	Max = 300,
	Default = 100,
	Increment = 5,
	Flag = "ni_jump",
	Callback = function(value)
		Settings.JumpPower = value
		applyJump()
	end,
})
Player:AddToggle({
	Text = "Infinite Jump",
	Description = "Jump again while airborne",
	Icon = "Lucide:arrow-up-circle",
	Default = false,
	Flag = "ni_infinite_jump",
	Callback = function(value)
		Settings.InfiniteJump = value
	end,
})
Player:AddToggle({
	Text = "Godmode",
	Description = "Keeps health and shield topped up",
	Icon = "Lucide:shield",
	Default = false,
	Flag = "ni_godmode",
	Callback = function(value)
		Settings.Godmode = value
	end,
})

Combat:AddSection("Attack", "Lucide:swords")
Combat:AddToggle({
	Text = "Auto Punch",
	Description = "Cycles punch1 / punch2 / punch3 through the attack remote",
	Icon = "Lucide:swords",
	Default = false,
	Flag = "ni_auto_punch",
	Callback = function(value)
		Settings.AutoPunch = value
	end,
})
Combat:AddToggle({
	Text = "Auto Uppercut",
	Description = "Fires the uppercut every 3.2s",
	Icon = "Lucide:arrow-up",
	Default = false,
	Flag = "ni_auto_uppercut",
	Callback = function(value)
		Settings.AutoUppercut = value
	end,
})
Combat:AddSection("Moves", "Lucide:sparkles")
Combat:AddToggle({
	Text = "Auto Move",
	Description = "Fires the selected move every 2s",
	Icon = "Lucide:zap",
	Default = false,
	Flag = "ni_auto_move",
	Callback = function(value)
		Settings.AutoMove = value
	end,
})
Combat:AddDropdown({
	Text = "Move",
	Description = "Which move to fire",
	Icon = "Lucide:list",
	Options = moveNames,
	Default = "Hand Beam",
	Flag = "ni_move",
	Callback = function(value)
		Settings.MoveId = moveNameToId[value] or "Beam"
	end,
})
Combat:AddParagraph({
	Title = "Move list",
	Icon = "Lucide:list",
	Text = "Uppercut (free), Hand Beam, Shadow Dash, Dodgeball, Lightning Punch, Ground Slam, Hollow Purple, Picture Perfect",
})

Farm:AddSection("Survival", "Lucide:heart")
Farm:AddToggle({
	Text = "Auto Revive",
	Description = "Sends the play-again request when you die",
	Icon = "Lucide:rotate-ccw",
	Default = false,
	Flag = "ni_auto_revive",
	Callback = function(value)
		Settings.AutoRevive = value
	end,
})
Farm:AddSection("Shop", "Lucide:shopping-cart")
local buyDropdown = Farm:AddDropdown({
	Text = "Move",
	Description = "Which move to buy or equip",
	Icon = "Lucide:list",
	Options = moveNames,
	Default = "Uppercut",
	Flag = "ni_shop_move",
	Callback = function() end,
})
Farm:AddButton({
	Text = "Buy Move",
	Description = "Fire MoveShop buy for the selected move",
	Icon = "Lucide:shopping-cart",
	Callback = function()
		buyMove(moveNameToId[buyDropdown:Get()] or "Uppercut")
	end,
})
Farm:AddButton({
	Text = "Equip Move",
	Description = "Fire MoveShop equip for the selected move",
	Icon = "Lucide:check",
	Callback = function()
		equipMove(moveNameToId[buyDropdown:Get()] or "Uppercut")
	end,
})

Visuals:AddSection("ESP", "Lucide:eye")
Visuals:AddToggle({
	Text = "Noob ESP",
	Description = "Highlights every noob with health and distance",
	Icon = "Lucide:users",
	Default = false,
	Flag = "ni_esp_noob",
	Callback = function(value)
		Settings.EspNoob = value
	end,
})
Visuals:AddToggle({
	Text = "Boss ESP",
	Description = "Highlights bosses with their name",
	Icon = "Lucide:crown",
	Default = false,
	Flag = "ni_esp_boss",
	Callback = function(value)
		Settings.EspBoss = value
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
	Flag = "ni_esp_distance",
	Callback = function(value)
		Settings.EspDistance = value
	end,
})

---------------------------------------------------------------------
-- Loops
---------------------------------------------------------------------

task.spawn(function()
	while ctx:Alive() do
		if Settings.EspNoob or Settings.EspBoss then
			pcall(espStep)
		end
		task.wait(0.2)
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
		if Settings.Godmode then
			pcall(applyGodmode)
		end
		task.wait(0.25)
	end
end)

task.spawn(function()
	while ctx:Alive() do
		if Settings.InfiniteJump then
			local humanoid = getHumanoid()
			if humanoid and humanoid:GetState() == Enum.HumanoidStateType.Freefall then
				humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
			end
		end
		task.wait(0.1)
	end
end)

task.spawn(function()
	while ctx:Alive() do
		if Settings.AutoPunch then
			pcall(autoPunchStep)
		end
		if Settings.AutoUppercut then
			pcall(autoUppercutStep)
		end
		if Settings.AutoMove then
			pcall(autoMoveStep)
		end
		if Settings.AutoRevive then
			pcall(autoReviveStep)
		end
		task.wait(0.1)
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
	Settings.InfiniteJump, Settings.Godmode = false, false
	Settings.AutoPunch, Settings.AutoUppercut, Settings.AutoMove = false, false, false
	Settings.AutoRevive, Settings.EspNoob, Settings.EspBoss = false, false, false
	for model, entry in pairs(espEntries) do
		entry.Gui:Destroy()
		entry.Highlight:Destroy()
		espEntries[model] = nil
	end
	local humanoid = getHumanoid()
	if humanoid then
		humanoid.WalkSpeed = 16
	end
end)
