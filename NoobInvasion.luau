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
	AutoAbility = false,
	DebugLogs = false,
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
	local direction = target - myRoot.Position
	if direction.Magnitude < 0.1 then
		return false
	end
	local look = myRoot.CFrame.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	if flatLook.Magnitude < 0.01 then
		flatLook = Vector3.new(0, 0, -1)
	end
	-- Snapping the CFrame on every attack makes the character look jittery,
	-- so only correct a real misalignment (more than ~10 degrees).
	if flatLook.Unit:Dot(direction.Unit) > 0.985 then
		return false
	end
	myRoot.CFrame = CFrame.lookAt(myRoot.Position, target)
	return true
end

local chaseSpeedApplied = false

local function clearChasePath()
	if chaseSpeedApplied then
		chaseSpeedApplied = false
		local humanoid = getHumanoid()
		if humanoid then
			humanoid.WalkSpeed = Settings.SpeedOn and Settings.Speed or 16
		end
	end
end

local nextChaseAt = 0
local function autoChaseStep()
	local now = os.clock()
	if now < nextChaseAt then
		return
	end
	nextChaseAt = now + 0.1
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
	-- Brake both the speed and the steering as the noob gets close. At full ChaseSpeed
	-- the character covers several studs per tick and runs straight past a close target,
	-- which is what makes the chase look like it is jittering.
	local flat = Vector3.new(noob.Position.X, myRoot.Position.Y, noob.Position.Z)
	local direction = flat - myRoot.Position
	local approach = math.clamp((direction.Magnitude - Settings.ChaseStop) / 15, 0.15, 1)
	local desiredSpeed = math.max(8, Settings.ChaseSpeed * approach)
	if humanoid.WalkSpeed ~= desiredSpeed then
		humanoid.WalkSpeed = desiredSpeed
		chaseSpeedApplied = true
	end
	if direction.Magnitude > 0.5 then
		humanoid:Move(direction.Unit * approach)
	end
	if noob.Position.Y > myRoot.Position.Y + 3 then
		humanoid.Jump = true
	end
	logOnce("chase_ok", "auto chase: steering toward the nearest noob", "info")
end

local function autoDashStep()
	-- Auto Chase already moves the character toward the noob; dashing away at the same
	-- time makes the two fight each other and stutter, so the chase wins.
	if Settings.AutoChase then
		return
	end
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

-- Auto-pick ability offers only when the SERVER sends one (a string id, e.g. "Shadow").
task.spawn(function()
	local offerRemote = remote("AbilityOffer")
	if not (offerRemote and offerRemote:IsA("RemoteEvent")) then
		logOnce("ability_offer_missing", "Remotes.AbilityOffer not found", "warn")
		return
	end
	ctx:Connect(offerRemote.OnClientEvent, function(offer)
		logOnce("ability_offer_seen", "ability offer received from the server", "info")
		if not Settings.AutoAbilityPick then
			return
		end
		local id = offer
		if type(offer) == "table" then
			id = offer[Settings.AbilityPickIndex] or offer[1]
		end
		if id == nil then
			id = Settings.AbilityPickIndex
		end
		pcall(function()
			offerRemote:FireServer(id)
		end)
		ctx:Log("[NI] auto ability pick: picked " .. tostring(id), "info")
	end)
	logOnce("ability_offer_hooked", "auto ability pick: watching for server offers", "info")
end)

local MovesModule = nil
do
	local module = ReplicatedStorage:WaitForChild("Moves", 10)
	if module then
		local ok, result = pcall(require, module)
		if ok then
			MovesModule = result
		end
	end
end

local function equippedMove()
	return LocalPlayer:GetAttribute("MatchMove") or LocalPlayer:GetAttribute("Move") or "Uppercut"
end

local function moveCooldown(id)
	if MovesModule and type(MovesModule.BY) == "table" and MovesModule.BY[id] and MovesModule.BY[id].cd then
		return MovesModule.BY[id].cd
	end
	return 4
end

local nextAbilityCastAt = 0
local function autoAbilityStep()
	local now = os.clock()
	if now < nextAbilityCastAt then
		return
	end
	local id = equippedMove()
	nextAbilityCastAt = now + moveCooldown(id)
	fireRemote("Attack", id)
	logOnce("ability_cast_ok", "auto ability: casting the equipped move", "info")
end

local nextDebugAt = 0
local function debugStep()
	if not Settings.DebugLogs then
		return
	end
	local now = os.clock()
	if now < nextDebugAt then
		return
	end
	nextDebugAt = now + 2
	local noob, distance = nearestNoob()
	local humanoid = getHumanoid()
	local myRoot = getRootPart()
	ctx:Log(
		string.format(
			"[NI][debug] attack=%s killAll=%s dash=%s chase=%s super=%s ability=%s abilityPick=%s perk=%s revive=%s | noob=%s moving=%s speed=%s",
			tostring(Settings.AutoAttack),
			tostring(Settings.AutoKillAll),
			tostring(Settings.AutoDash),
			tostring(Settings.AutoChase),
			tostring(Settings.AutoSuper),
			tostring(Settings.AutoAbility),
			tostring(Settings.AutoAbilityPick),
			tostring(Settings.AutoPerkOffer),
			tostring(Settings.AutoRevive),
			distance and string.format("%.1f", distance) or "none",
			tostring(myRoot ~= nil),
			humanoid and string.format("%.1f", humanoid.WalkSpeed) or "?"
		),
		"info"
	)
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
local DebugTab = ctx:SubTab("Debug", "Lucide:bug")

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
	Text = "Auto Ability",
	Description = "Casts whichever move you have equipped, on its own cooldown",
	Icon = "Lucide:sparkles",
	Default = false,
	Flag = "ni_auto_ability_cast",
	Callback = function(value)
		Settings.AutoAbility = value
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
	Description = "Accepts ability offers only when the server sends one",
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

Visuals:AddSection("ESP", "Lucide:eye")Visuals:AddToggle({
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

DebugTab:AddSection("Logging", "Lucide:bug")
DebugTab:AddToggle({
	Text = "Debug Logs",
	Description = "Prints the live state of every feature every 2s",
	Icon = "Lucide:bug",
	Default = false,
	Flag = "ni_debug_logs",
	Callback = function(value)
		Settings.DebugLogs = value
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
		if Settings.AutoAbility then
			pcall(autoAbilityStep)
		end
		if Settings.DebugLogs then
			pcall(debugStep)
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
	Settings.AutoAttack, Settings.AutoAbility, Settings.AutoMove = false, false, false
	Settings.DebugLogs = false
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
