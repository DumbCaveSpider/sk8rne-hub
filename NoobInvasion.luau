-- NOOB INVASION
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
	AutoAttack = false,
	AutoKillAll = false,
	KillRange = 60,
	AutoDash = false,
	DashRange = 10,
	AutoPerkOffer = false,
	PerkPickIndex = 1,
	NoCooldown = false,
	HitAnyDirection = false,
	AutoChase = false,
	ChaseStop = 8,
	ChaseSpeed = 30,
	AutoSuper = false,
	AutoAbilityPick = false,
	AbilityPickIndex = 1,
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

-- Every numbered attack chain in the game, picked by the equipped weapon.
local ATTACK_CHAINS = {
	Fists = { "punch1", "punch2", "punch3" },
	Sword = { "slash1", "slash2", "slash3" },
	Chains = { "slash1", "slash2", "slash3" },
	Scythe = { "reap1", "reap2", "reap3" },
	Hammer = { "hammer1", "hammer2" },
}
local attackIndex = 0
local nextAttackAt = 0

local function attackChain()
	return ATTACK_CHAINS[LocalPlayer:GetAttribute("Weapon")] or ATTACK_CHAINS.Fists
end

local function autoAttackStep()
	local now = os.clock()
	if now < nextAttackAt then
		return
	end
	nextAttackAt = now + (Settings.NoCooldown and 0.05 or 0.25)
	if Settings.HitAnyDirection then
		faceNearestNoob()
	end
	local chain = attackChain()
	attackIndex = attackIndex % #chain + 1
	fireRemote("Attack", chain[attackIndex])
	logOnce("attack_ok", "auto attack: cycling the equipped weapon's chain", "info")
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
	local chain = attackChain()
	attackIndex = attackIndex % #chain + 1
	fireRemote("Attack", chain[attackIndex])
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

local chaseTarget = nil
local chasePath = nil
local chaseWaypoint = 1
local lastRepathAt = 0
local chaseSpeedApplied = false

local function clearChasePath()
	chasePath = nil
	chaseWaypoint = 1
	chaseTarget = nil
	if chaseSpeedApplied then
		chaseSpeedApplied = false
		local humanoid = getHumanoid()
		if humanoid then
			humanoid.WalkSpeed = Settings.SpeedOn and Settings.Speed or 16
		end
	end
end

local function buildChasePath(noob)
	local myRoot = getRootPart()
	if not myRoot or not noob then
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
		path:ComputeAsync(myRoot.Position, noob.Position)
	end)
	if not ok or path.Status ~= Enum.PathStatus.Success then
		return false
	end
	chasePath = path
	chaseWaypoint = 2
	return true
end

local nextChaseAt = 0
local function autoChaseStep()
	local now = os.clock()
	if now < nextChaseAt then
		return
	end
	nextChaseAt = now + 0.2
	local humanoid = getHumanoid()
	local myRoot = getRootPart()
	if not humanoid or not myRoot then
		clearChasePath()
		return
	end
	local noob, distance = nearestNoob()
	if not noob or not distance or distance <= Settings.ChaseStop then
		clearChasePath()
		return
	end
	if humanoid.WalkSpeed < Settings.ChaseSpeed then
		humanoid.WalkSpeed = Settings.ChaseSpeed
		chaseSpeedApplied = true
	end
	local targetMoved = chaseTarget and (noob.Position - chaseTarget.Position).Magnitude > 4
	if not chasePath or chaseTarget ~= noob or targetMoved or now - lastRepathAt > 1 then
		chaseTarget = noob
		lastRepathAt = now
		if not buildChasePath(noob) then
			humanoid:MoveTo(noob.Position)
			return
		end
	end
	local waypoints = chasePath and chasePath:GetWaypoints()
	if not waypoints or chaseWaypoint > #waypoints then
		humanoid:MoveTo(noob.Position)
		chaseTarget = nil
		lastRepathAt = 0
		return
	end
	local waypoint = waypoints[chaseWaypoint]
	if waypoint.Action == Enum.PathWaypointAction.Jump then
		humanoid.Jump = true
	end
	humanoid:MoveTo(waypoint.Position)
	if (myRoot.Position - waypoint.Position).Magnitude < 3 then
		chaseWaypoint = chaseWaypoint + 1
	end
	logOnce("chase_ok", "auto chase: pathfinding + sprinting to the nearest noob", "info")
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

-- Auto-pick perks only when the SERVER sends an offer. Nothing is fired client-side.
task.spawn(function()
	local perkRemote = remote("Perk")
	if not (perkRemote and perkRemote:IsA("RemoteEvent")) then
		logOnce("perk_missing", "Remotes.Perk not found", "warn")
		return
	end
	ctx:Connect(perkRemote.OnClientEvent, function(offer)
		logOnce("perk_offer_seen", "perk offer received from the server", "info")
		if not Settings.AutoPerkOffer then
			return
		end
		local pick = Settings.PerkPickIndex or 1
		local choice
		if type(offer) == "table" then
			choice = offer[pick] or offer[1]
		end
		choice = choice or pick
		pcall(function()
			perkRemote:FireServer(choice)
		end)
		ctx:Log("[NI] auto perk: picked " .. tostring(choice), "info")
	end)
	logOnce("perk_hooked", "auto perk: watching for server perk offers", "info")
end)

local SUPER_BY_WEAPON = {
	Scythe = "rsuper",
	Hammer = "hsuper",
}

local function superAttack()
	return SUPER_BY_WEAPON[LocalPlayer:GetAttribute("Weapon")] or "super"
end

local nextSuperAt = 0
local function autoSuperStep()
	local now = os.clock()
	if now < nextSuperAt then
		return
	end
	nextSuperAt = now + 4
	fireRemote("Attack", superAttack())
	logOnce("super_ok", "auto super: firing the super attack", "info")
end

local nextAbilityAt = 0
local function autoAbilityPickStep()
	local now = os.clock()
	if now < nextAbilityAt then
		return
	end
	nextAbilityAt = now + 2
	fireRemote("AbilityOffer", Settings.AbilityPickIndex)
	logOnce("ability_ok", "auto ability: picking option " .. tostring(Settings.AbilityPickIndex), "info")
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
	Text = "Auto Attack",
	Description = "Cycles the equipped weapon's chain (punch / slash / reap / hammer)",
	Icon = "Lucide:swords",
	Default = false,
	Flag = "ni_auto_attack",
	Callback = function(value)
		Settings.AutoAttack = value
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
	Text = "Auto Super",
	Description = "Fires the super attack every 4s",
	Icon = "Lucide:zap",
	Default = false,
	Flag = "ni_auto_super",
	Callback = function(value)
		Settings.AutoSuper = value
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
Combat:AddToggle({
	Text = "Auto Pick Perk",
	Description = "Picks a perk only when the server offers one",
	Icon = "Lucide:gift",
	Default = false,
	Flag = "ni_auto_perk",
	Callback = function(value)
		Settings.AutoPerkOffer = value
	end,
})
Combat:AddSlider({
	Text = "Perk Pick Index",
	Description = "Which offered perk to choose (1-3)",
	Icon = "Lucide:list-ordered",
	Min = 1,
	Max = 3,
	Default = 1,
	Increment = 1,
	Flag = "ni_perk_index",
	Callback = function(value)
		Settings.PerkPickIndex = value
	end,
})

Combat:AddToggle({
	Text = "Auto Pick Ability",
	Description = "Picks the selected ability offer every 2s",
	Icon = "Lucide:sparkles",
	Default = false,
	Flag = "ni_auto_ability",
	Callback = function(value)
		Settings.AutoAbilityPick = value
	end,
})
Combat:AddSlider({
	Text = "Ability Pick Index",
	Description = "Which ability offer to choose (1-3)",
	Icon = "Lucide:list-ordered",
	Min = 1,
	Max = 3,
	Default = 1,
	Increment = 1,
	Flag = "ni_ability_index",
	Callback = function(value)
		Settings.AbilityPickIndex = value
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

Farm:AddSection("Movement", "Lucide:footprints")
Farm:AddToggle({
	Text = "Auto Chase",
	Description = "Walks to the nearest noob when it's out of reach",
	Icon = "Lucide:footprints",
	Default = false,
	Flag = "ni_auto_chase",
	Callback = function(value)
		Settings.AutoChase = value
	end,
})
Farm:AddSlider({
	Text = "Chase Stop Distance",
	Description = "Stops walking once the noob is this close",
	Icon = "Lucide:radar",
	Min = 3,
	Max = 40,
	Default = 8,
	Increment = 1,
	Suffix = " studs",
	Flag = "ni_chase_stop",
	Callback = function(value)
		Settings.ChaseStop = value
	end,
})
Farm:AddSlider({
	Text = "Chase Speed",
	Description = "Sprint speed used while chasing",
	Icon = "Lucide:rabbit",
	Min = 16,
	Max = 120,
	Default = 30,
	Increment = 2,
	Suffix = " studs",
	Flag = "ni_chase_speed",
	Callback = function(value)
		Settings.ChaseSpeed = value
	end,
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
		if Settings.AutoAttack then
			pcall(autoAttackStep)
		end
		if Settings.AutoKillAll then
			pcall(autoKillAllStep)
		end
		if Settings.AutoDash then
			pcall(autoDashStep)
		end
		if Settings.AutoChase then
			pcall(autoChaseStep)
		end
		if Settings.AutoSuper then
			pcall(autoSuperStep)
		end
		if Settings.AutoAbilityPick then
			pcall(autoAbilityPickStep)
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
	Settings.AutoAttack, Settings.AutoUppercut, Settings.AutoMove = false, false, false
	Settings.AutoKillAll = false
	Settings.AutoDash = false
	Settings.AutoPerkOffer = false
	Settings.NoCooldown = false
	Settings.HitAnyDirection = false
	Settings.AutoChase = false
	Settings.AutoSuper = false
	Settings.AutoAbilityPick = false
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
