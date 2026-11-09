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
	AutoKillAll = false,
	KillRange = 60,
	AutoDash = false,
	DashRange = 10,
	AutoSlash = false,
	AutoPerkOffer = false,
	NoCooldown = false,
	HitAnyDirection = false,
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
	-- Match servers expose a Remotes folder; the lobby keeps remotes directly on ReplicatedStorage.
	local folder = folderName and ReplicatedStorage:FindFirstChild(folderName)
	if not folder then
		folder = ReplicatedStorage:FindFirstChild("Remotes")
	end
	local found = folder and folder:FindFirstChild(name)
	return found or ReplicatedStorage:FindFirstChild(name)
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
	for _, model in ipairs(folder:GetChildren()) do
		if model:IsA("Model") and model ~= LocalPlayer.Character then
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			local part = espPart(model)
			if humanoid and humanoid.Health > 0 and part then
				local bossName = model:GetAttribute("BossName")
				local isBoss = bossName ~= nil or model.Name == "BossNoob"
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

local nearestNoob
local faceNearestNoob

local PUNCHES = { "punch1", "punch2", "punch3" }
local punchIndex = 0
local nextPunchAt = 0

local function autoPunchStep()
	local now = os.clock()
	if now < nextPunchAt then
		return
	end
	nextPunchAt = now + (Settings.NoCooldown and 0.05 or 0.25)
	if Settings.HitAnyDirection then
		faceNearestNoob()
	end
	punchIndex = punchIndex % #PUNCHES + 1
	fireRemote("Attack", PUNCHES[punchIndex])
	logOnce("punch_ok", "auto punch: sending punch combos", "info")
end

local function aliveNoobsInRange(range)
	local myRoot = getRootPart()
	local folder = noobsFolder()
	if not myRoot or not folder then
		return 0
	end
	local targets = 0
	for _, model in ipairs(folder:GetChildren()) do
		if model:IsA("Model") then
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health > 0 then
				local part = espPart(model)
				if part and (part.Position - myRoot.Position).Magnitude <= range then
					targets = targets + 1
				end
			end
		end
	end
	return targets
end

local nextKillAllAt = 0
local function autoKillAllStep()
	local now = os.clock()
	if now < nextKillAllAt then
		return
	end
	nextKillAllAt = now + (Settings.NoCooldown and 0.05 or 0.15)
	if Settings.HitAnyDirection then
		faceNearestNoob()
	end
	if aliveNoobsInRange(Settings.KillRange) == 0 then
		return
	end
	punchIndex = punchIndex % #PUNCHES + 1
	fireRemote("Attack", PUNCHES[punchIndex])
	logOnce("killall_ok", "auto kill all: attacking every noob in range", "info")
end

local nextDashAt = 0
nearestNoob = function()
	local myRoot = getRootPart()
	local folder = noobsFolder()
	if not myRoot or not folder then
		return nil
	end
	local nearest, nearestDist = nil, math.huge
	for _, model in ipairs(folder:GetChildren()) do
		if model:IsA("Model") then
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			local part = espPart(model)
			if humanoid and humanoid.Health > 0 and part then
				local distance = (part.Position - myRoot.Position).Magnitude
				if distance < nearestDist then
					nearest, nearestDist = part, distance
				end
			end
		end
	end
	return nearest, nearestDist
end

faceNearestNoob = function()
	local myRoot = getRootPart()
	if not myRoot then
		return false
	end
	local noob = nearestNoob()
	if not noob then
		return false
	end
	local target = Vector3.new(noob.Position.X, myRoot.Position.Y, noob.Position.Z)
	if (target - myRoot.Position).Magnitude > 0.1 then
		myRoot.CFrame = CFrame.lookAt(myRoot.Position, target)
		return true
	end
	return false
end

local function autoDashStep()
	local now = os.clock()
	if now < nextDashAt then
		return
	end
	local myRoot = getRootPart()
	local humanoid = getHumanoid()
	if not myRoot or not humanoid then
		return
	end
	local noob, distance = nearestNoob()
	if not noob or distance > Settings.DashRange then
		return
	end
	nextDashAt = now + 1
	local away = myRoot.Position - noob.Position
	if away.Magnitude > 0.1 then
		humanoid:MoveTo(myRoot.Position + away.Unit * 25)
	end
	fireRemote("Attack", "dash")
	logOnce("dash_ok", "auto dash: dodging an incoming noob", "info")
end

local SLASHES = { "slash1", "slash2", "slash3" }
local slashIndex = 0
local nextSlashAt = 0
local function autoSlashStep()
	local now = os.clock()
	if now < nextSlashAt then
		return
	end
	nextSlashAt = now + (Settings.NoCooldown and 0.05 or 0.3)
	if Settings.HitAnyDirection then
		faceNearestNoob()
	end
	slashIndex = slashIndex % #SLASHES + 1
	fireRemote("Attack", SLASHES[slashIndex])
	logOnce("slash_ok", "auto slash: cycling slash1/2/3", "info")
end

local function firePerkOffer(perks)
	local perkRemote = remote("Perk")
	if not (perkRemote and perkRemote:IsA("RemoteEvent")) then
		logOnce("perk_missing", "Remotes.Perk not found", "warn")
		return false
	end
	local payload = perks or { "Vampire", "Shield", "Healing" }
	local fired = false
	if type(firesignal) == "function" then
		local ok = pcall(firesignal, perkRemote.OnClientEvent, payload)
		fired = fired or ok
	end
	if type(getconnections) == "function" then
		local ok, connections = pcall(getconnections, perkRemote.OnClientEvent)
		if ok and type(connections) == "table" then
			for _, connection in ipairs(connections) do
				pcall(connection.Fire, connection, payload)
				fired = true
			end
		end
	end
	logOnce("perk_offer_ok", "perk offer: fired the Perk signal", "info")
	return fired
end

local nextPerkOfferAt = 0
local function autoPerkOfferStep()
	local now = os.clock()
	if now < nextPerkOfferAt then
		return
	end
	nextPerkOfferAt = now + 2
	firePerkOffer()
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
	Text = "Auto Dash (Dodge)",
	Description = "Dashes away when a noob gets into melee range",
	Icon = "Lucide:wind",
	Default = false,
	Flag = "ni_auto_dash",
	Callback = function(value)
		Settings.AutoDash = value
	end,
})
Player:AddSlider({
	Text = "Dash Trigger Range",
	Description = "How close a noob has to get before dashing",
	Icon = "Lucide:radar",
	Min = 4,
	Max = 40,
	Default = 10,
	Increment = 1,
	Suffix = " studs",
	Flag = "ni_dash_range",
	Callback = function(value)
		Settings.DashRange = value
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

Combat:AddToggle({
	Text = "No Cooldown",
	Description = "Fires attacks every 0.05s instead of the normal rate",
	Icon = "Lucide:timer-off",
	Default = false,
	Flag = "ni_no_cd",
	Callback = function(value)
		Settings.NoCooldown = value
	end,
})
Combat:AddToggle({
	Text = "Hit Any Direction",
	Description = "Snaps to face the nearest noob before every attack",
	Icon = "Lucide:compass",
	Default = false,
	Flag = "ni_any_dir",
	Callback = function(value)
		Settings.HitAnyDirection = value
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
	Text = "Auto Kill All",
	Description = "Attacks continuously whenever any noob is in range",
	Icon = "Lucide:skull",
	Default = false,
	Flag = "ni_auto_killall",
	Callback = function(value)
		Settings.AutoKillAll = value
	end,
})
Combat:AddSlider({
	Text = "Kill Range",
	Description = "How far auto kill all looks for noobs",
	Icon = "Lucide:radar",
	Min = 10,
	Max = 300,
	Default = 60,
	Increment = 10,
	Suffix = " studs",
	Flag = "ni_kill_range",
	Callback = function(value)
		Settings.KillRange = value
	end,
})
Combat:AddToggle({
	Text = "Auto Slash",
	Description = "Cycles slash1 / slash2 / slash3 through the attack remote",
	Icon = "Lucide:swords",
	Default = false,
	Flag = "ni_auto_slash",
	Callback = function(value)
		Settings.AutoSlash = value
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
Combat:AddSection("Perks", "Lucide:sparkles")
Combat:AddButton({
	Text = "Force Perk Offer",
	Description = "Fires Remotes.Perk.OnClientEvent with Vampire / Shield / Healing",
	Icon = "Lucide:gift",
	Callback = function()
		firePerkOffer({ "Vampire", "Shield", "Healing" })
	end,
})
Combat:AddToggle({
	Text = "Auto Perk Offer",
	Description = "Fires the perk offer every 2s",
	Icon = "Lucide:repeat",
	Default = false,
	Flag = "ni_auto_perk",
	Callback = function(value)
		Settings.AutoPerkOffer = value
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
		if Settings.AutoKillAll then
			pcall(autoKillAllStep)
		end
		if Settings.AutoDash then
			pcall(autoDashStep)
		end
		if Settings.AutoSlash then
			pcall(autoSlashStep)
		end
		if Settings.AutoPerkOffer then
			pcall(autoPerkOfferStep)
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
	Settings.AutoKillAll = false
	Settings.AutoDash = false
	Settings.AutoSlash = false
	Settings.AutoPerkOffer = false
	Settings.NoCooldown = false
	Settings.HitAnyDirection = false
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
