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

-- Drive the game's own binds instead of guessing remote arguments.
local function pressKey(keyCode)
	local ok = pcall(function()
		keypress(keyCode)
	end)
	if ok then
		task.wait(0.05)
		pcall(function()
			keyrelease(keyCode)
		end)
		return true
	end
	return pcall(function()
		local virtualInput = game:GetService("VirtualInputManager")
		virtualInput:SendKeyEvent(true, keyCode, false, game)
		task.wait(0.05)
		virtualInput:SendKeyEvent(false, keyCode, false, game)
	end)
end

local function clickMouse()
	local ok = pcall(function()
		mouse1click()
	end)
	if ok then
		return true
	end
	return pcall(function()
		local virtualInput = game:GetService("VirtualInputManager")
		virtualInput:SendMouseButtonEvent(0, 0, 0, true, game, 0)
		task.wait(0.05)
		virtualInput:SendMouseButtonEvent(0, 0, 0, false, game, 0)
	end)
end

-- Close the game's choice frame; firing the remote alone leaves the UI on screen.
local function closeChoiceFrame(frameName)
	local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
	local hud = playerGui and playerGui:FindFirstChild("HUD")
	local frame = hud and hud:FindFirstChild(frameName, true)
	if frame then
		pcall(function()
			frame.Visible = false
			frame:Destroy()
		end)
		return true
	end
	return false
end

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
	AutoPickup = false,
	PickupRange = 8,
	AutoPerkOffer = false,
	HitAnyDirection = false,
	AutoChase = false,
	ChaseStop = 8,
	ChaseSpeed = 30,
	AutoSuper = false,
	AutoAbilityPick = false,
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
	nextAttackAt = now + 0.25
	if Settings.HitAnyDirection then
		faceNearestNoob()
	end
	-- M1 is the game's punch bind; it picks the right chain for the equipped weapon.
	clickMouse()
	logOnce("attack_ok", "auto attack: clicking the punch button", "info")
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
	nextKillAllAt = now + 0.15
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
local lastChaseMoveAt = 0
local lastChasePosition = nil

local function clearChasePath()
	lastChasePosition = nil
	lastChaseMoveAt = 0
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
	nextChaseAt = now + 0.05
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
	-- Brake both the speed and the steering as the noob gets close. A very high top speed
	-- covers several studs per tick and runs straight past the target, so it is capped
	-- here even if the slider is pushed higher.
	local flat = Vector3.new(noob.Position.X, myRoot.Position.Y, noob.Position.Z)
	local direction = flat - myRoot.Position
	local topSpeed = math.min(Settings.ChaseSpeed, 40)
	local approach = math.clamp((direction.Magnitude - Settings.ChaseStop) / 15, 0.15, 1)
	local desiredSpeed = math.max(8, topSpeed * approach)
	-- Leave the speed alone while Speed Boost is on so sprinting keeps working;
	-- the chase then only steers toward the target.
	if not Settings.SpeedOn and humanoid.WalkSpeed ~= desiredSpeed then
		humanoid.WalkSpeed = desiredSpeed
		chaseSpeedApplied = true
	end
	-- MoveTo is what the game's input controller respects; Humanoid:Move is reset to zero
	-- every frame when no keys are held. Throttle + predict so it tracks a moving noob
	-- without restarting the walk every tick.
	local predicted = flat + (noob.AssemblyLinearVelocity or Vector3.zero) * 0.2
	local movedFar = lastChasePosition == nil or (predicted - lastChasePosition).Magnitude > 4
	if now - lastChaseMoveAt >= 0.25 or movedFar then
		lastChaseMoveAt = now
		lastChasePosition = predicted
		humanoid:MoveTo(predicted)
	end
	if noob.Position.Y > myRoot.Position.Y + 3 then
		humanoid.Jump = true
	end
	logOnce("chase_ok", "auto chase: steering toward the nearest noob", "info")
end

local promptCache = {}
local lastPromptScanAt = 0

local function scanPrompts()
	local now = os.clock()
	if now - lastPromptScanAt < 2 then
		return
	end
	lastPromptScanAt = now
	local prompts = {}
	for _, descendant in ipairs(workspace:GetDescendants()) do
		if descendant:IsA("ProximityPrompt") and descendant.Enabled then
			local parent = descendant.Parent
			if parent and parent:IsA("BasePart") then
				prompts[#prompts + 1] = descendant
			end
		end
	end
	promptCache = prompts
end

local nextPickupAt = 0
local function autoPickupStep()
	local now = os.clock()
	if now < nextPickupAt then
		return
	end
	nextPickupAt = now + 0.6
	local myRoot = getRootPart()
	if not myRoot then
		return
	end
	scanPrompts()
	local best, bestDistance = nil, math.huge
	for _, prompt in ipairs(promptCache) do
		local parent = prompt.Parent
		if prompt.Enabled and parent and parent.Parent then
			local distance = (parent.Position - myRoot.Position).Magnitude
			local limit = math.min(Settings.PickupRange, prompt.MaxActivationDistance)
			if distance <= limit and distance < bestDistance then
				best, bestDistance = prompt, distance
			end
		end
	end
	if not best then
		return
	end
	pcall(function()
		fireproximityprompt(best)
	end)
	-- The prompt picks the object up; M1 throws it.
	task.delay(0.2, function()
		clickMouse()
	end)
	logOnce("pickup_ok", "auto pickup: picked up and threw an object", "info")
end

local function autoDashStep()
	local now = os.clock()
	if now < nextDashAt then
		return
	end
	nextDashAt = now + 1.2
	local myRoot = getRootPart()
	if not myRoot then
		return
	end
	local before = myRoot.Position
	-- Pressing Q runs the game's own DASH.go: it applies the LinearVelocity, plays the
	-- animation and VFX, and fires the server dash, so this is the exact native dash.
	pressKey(Enum.KeyCode.Q)
	task.delay(0.4, function()
		local after = getRootPart()
		local moved = after and (after.Position - before).Magnitude or -1
		ctx:Log(
			string.format("[NI] auto dash: pressed Q | moved=%.1f studs", moved),
			moved >= 3 and "info" or "warn"
		)
	end)
	logOnce("dash_ok", "auto dash: pressing Q", "info")
end

-- Auto-pick perks only when the SERVER sends an offer. Nothing is fired client-side.
task.spawn(function()
	local perkRemote = remote("Perk")
	if not (perkRemote and perkRemote:IsA("RemoteEvent")) then
		logOnce("perk_missing", "Remotes.Perk not found", "warn")
		return
	end
	ctx:Connect(perkRemote.OnClientEvent, function(offer)
		logOnce("perk_offer_seen", "perk offer received from the server: " .. tostring(offer), "info")
		if not Settings.AutoPerkOffer then
			return
		end
		-- The offer can be a plain string or a table of choices; use the first one.
		local choice = offer
		if type(offer) == "table" then
			choice = offer[1]
		end
		if choice == nil then
			return
		end
		pcall(function()
			perkRemote:FireServer(choice)
		end)
		task.delay(0.1, function()
			closeChoiceFrame("PerkChoice")
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
	-- F is the game's Super bind.
	pressKey(Enum.KeyCode.F)
	logOnce("super_ok", "auto super: pressing F", "info")
end

-- Auto-pick ability offers only when the SERVER sends one (a string id, e.g. "Shadow").
task.spawn(function()
	local offerRemote = remote("AbilityOffer")
	if not (offerRemote and offerRemote:IsA("RemoteEvent")) then
		logOnce("ability_offer_missing", "Remotes.AbilityOffer not found", "warn")
		return
	end
	ctx:Connect(offerRemote.OnClientEvent, function(offer)
		logOnce("ability_offer_seen", "ability offer received from the server: " .. tostring(offer), "info")
		if not Settings.AutoAbilityPick then
			return
		end
		-- The game's choice UI sends a boolean: true accepts the offered ability.
		pcall(function()
			offerRemote:FireServer(true)
		end)
		task.delay(0.1, function()
			closeChoiceFrame("AbilityChoice")
		end)
		ctx:Log("[NI] auto ability pick: accepted " .. tostring(offer), "info")
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
	-- E is the game's ability bind, so it casts the equipped move natively.
	pressKey(Enum.KeyCode.E)
	logOnce("ability_cast_ok", "auto ability: pressing E", "info")
end

-- Tell the user when the equipped move isn't actually owned: the server ignores
-- casts for moves the player has not bought, which looks like "auto ability is broken".
task.spawn(function()
	task.wait(3)
	if not MovesModule then
		ctx:Log("[NI] auto ability: Moves module not found", "warn")
		return
	end
	local owned = MovesModule.owned(LocalPlayer)
	local id = equippedMove()
	local isOwned = owned[id] == true
	ctx:Log(
		string.format("[NI] auto ability: equipped=%s owned=%s", tostring(id), tostring(isOwned)),
		isOwned and "info" or "warn"
	)
end)

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
	Text = "Auto Dash",
	Description = "Dashes in the direction you're walking or facing",
	Icon = "Lucide:wind",
	Default = false,
	Flag = "ni_auto_dash",
	Callback = function(value)
		Settings.AutoDash = value
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

Farm:AddSection("Pickup", "Lucide:hand")
Farm:AddToggle({
	Text = "Auto Pickup",
	Description = "Grabs the nearest shown ProximityPrompt and throws it with M1",
	Icon = "Lucide:hand",
	Default = false,
	Flag = "ni_auto_pickup",
	Callback = function(value)
		Settings.AutoPickup = value
	end,
})
Farm:AddSlider({
	Text = "Pickup Range",
	Description = "How far away prompts are picked up",
	Icon = "Lucide:radar",
	Min = 3,
	Max = 30,
	Default = 8,
	Increment = 1,
	Suffix = " studs",
	Flag = "ni_pickup_range",
	Callback = function(value)
		Settings.PickupRange = value
	end,
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
		if Settings.AutoPickup then
			pcall(autoPickupStep)
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
	Settings.AutoPickup = false
	Settings.AutoPerkOffer = false
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
