-- No Mercy: The Gameshow
local ctx = ...
local task = ctx.task

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
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
	ctx:Log("[NOMERCY] " .. message, level or "info")
end

ctx:Log("[NOMERCY] module loaded", "info")

local Settings = {
	SpeedOn = false,
	Speed = 30,
	JumpOn = false,
	JumpPower = 100,
	InfiniteJump = false,
	AntiRagdoll = false,
	Godmode = false,
	Hover = false,
	LowGravity = false,
	PlayerEsp = false,
	CannonEsp = false,
	EspDistance = 500,
	AutoParry = false,
	AutoSlide = false,
	AutoSmokeDash = false,
	AutoSpawnProtection = false,
	AutoFreezeFrame = false,
	AutoInflatable = false,
	ThreatEsp = false,
	DoubleJump = false,
}

-- The Ragdoll library is what the "Helping hand" passive uses to un-ragdoll.
local Ragdoll = nil
do
	local libs = ReplicatedStorage:WaitForChild("Libs", 10)
	local module = libs and libs:WaitForChild("Ragdoll", 10)
	if module then
		local ok, result = pcall(require, module)
		if ok then
			Ragdoll = result
		end
	end
end

-- Threat catalogue: names come from ReplicatedStorage.ThreatInfo.
local ThreatInfo = nil
do
	local module = ReplicatedStorage:WaitForChild("ThreatInfo", 10)
	if module then
		local ok, result = pcall(require, module)
		if ok then
			ThreatInfo = result
		end
	end
end

-- Every threat model the game can spawn, including the template/model names it clones.
local THREAT_ALIASES = {}
local function alias(key, display)
	THREAT_ALIASES[key:gsub("[%s_%-%?']", ""):lower()] = display
end
alias("CASSIE", "CASSIE")
alias("Cupid", "Cupid")
alias("James the Reaper", "James the Reaper")
alias("Reaper", "James the Reaper")
alias("Wring", "Wring")
alias("The Sacrifice", "The Sacrifice")
alias("Sacrifice", "The Sacrifice")
alias("Spinning Lasers", "Spinning Lasers")
alias("SpinningLasers", "Spinning Lasers")
alias("LasersParts", "Spinning Lasers")
alias("Bounce Lasers", "Bounce Lasers")
alias("Boxing Dummy", "Boxing Dummy")
alias("OXI", "OXI")
alias("Boom-ba", "Boom-ba")
alias("Pumpkin patch", "Pumpkin patch")
alias("Shadow", "Shadow")
alias("Why's this Wheeler?", "Why's this Wheeler?")
alias("Why This Guy", "Why's this Wheeler?")
alias("Duck", "Duck")
alias("DuckModel", "Duck")

if ThreatInfo and ThreatInfo.Images then
	for name in pairs(ThreatInfo.Images) do
		alias(name, name)
	end
end

local function normalizeName(name)
	return name:gsub("[%s_%-%?']", ""):lower()
end

local function threatNameFromInstance(instance)
	return THREAT_ALIASES[normalizeName(instance.Name)]
end

local threatModels = {}

local function registerThreat(instance)
	if not instance:IsA("Model") or threatModels[instance] then
		return
	end
	local name = threatNameFromInstance(instance)
	if not name then
		return
	end
	threatModels[instance] = name
	ctx:Log("[NOMERCY] threat spawned: " .. name, "warn")
end

task.spawn(function()
	for _, descendant in ipairs(workspace:GetDescendants()) do
		registerThreat(descendant)
	end
	ctx:Connect(workspace.DescendantAdded, registerThreat)
	ctx:Connect(workspace.DescendantRemoving, function(instance)
		threatModels[instance] = nil
	end)
end)

-- Anti-ragdoll also blocks the client's RagdollPush request; threats use it to ragdoll you.
task.spawn(function()
	local remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
	local client = remotes and remotes:WaitForChild("Client", 10)
	local gameRemotes = client and client:WaitForChild("Game", 10)
	local threats = gameRemotes and gameRemotes:WaitForChild("Threats", 10)
	local ragdollPush = threats and threats:WaitForChild("RagdollPush", 10)
	if not (ragdollPush and ragdollPush:IsA("RemoteEvent")) then
		logOnce("ragdollpush_missing", "anti-ragdoll: RagdollPush remote not found", "warn")
		return
	end
	ctx:HookMeta(ragdollPush, "__namecall", function(old, self, ...)
		if self == ragdollPush and Settings.AntiRagdoll and getnamecallmethod() == "FireServer" then
			logOnce("ragdollpush_blocked", "anti-ragdoll: blocked a RagdollPush request", "info")
			return
		end
		return old(self, ...)
	end)
	logOnce("ragdollpush_hooked", "anti-ragdoll: RagdollPush is blocked while enabled", "info")
end)

---------------------------------------------------------------------
-- Skills
---------------------------------------------------------------------

local function skillsFolder()
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local client = remotes and remotes:FindFirstChild("Client")
	return client and client:FindFirstChild("Skills")
end

local function findSkillRemote(name)
	local folder = skillsFolder()
	if not folder then
		return nil
	end
	local target = name:gsub("%s", ""):lower()
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("RemoteEvent") or child:IsA("UnreliableRemoteEvent") then
			if child.Name:gsub("%s", ""):lower() == target then
				return child
			end
		end
	end
	return nil
end

local function fireSkill(name)
	local remote = findSkillRemote(name)
	if not remote then
		logOnce("skill_missing_" .. name, "no remote found for skill " .. name, "warn")
		return false
	end
	local character = getCharacter()
	local ok = pcall(function()
		remote:FireServer(character)
	end)
	if not ok then
		pcall(function()
			remote:FireServer()
		end)
	end
	return true
end

-- Reveal the exact remote names once so the skill toggles can be matched.
task.spawn(function()
	local folder = skillsFolder()
	if not folder then
		logOnce("skills_nofolder", "Remotes.Client.Skills not found", "warn")
		return
	end
	local names = {}
	for _, child in ipairs(folder:GetChildren()) do
		table.insert(names, child.Name)
	end
	table.sort(names)
	ctx:Log("[NOMERCY] skill remotes: " .. table.concat(names, ", "), "info")
end)

---------------------------------------------------------------------
-- ESP
---------------------------------------------------------------------

local overlay = ctx:Track(Instance.new("ScreenGui"))
overlay.Name = "Sk8rneNoMercy"
overlay.ResetOnSpawn = false
overlay.IgnoreGuiInset = true
overlay.Parent = LocalPlayer:WaitForChild("PlayerGui")

local espEntries = {}

local function createEsp(model, part, color, text)
	local gui = Instance.new("BillboardGui")
	gui.Name = "Sk8rneEsp"
	gui.Size = UDim2.fromOffset(200, 52)
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
	highlight.Adornee = model
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.FillColor = color
	highlight.FillTransparency = 0.8
	highlight.OutlineColor = color
	highlight.OutlineTransparency = 0
	highlight.Parent = model

	local entry = { Gui = gui, Label = label, Highlight = highlight }
	espEntries[model] = entry
	return entry
end

local function espStep()
	local myRoot = getRootPart()
	local visible = {}
	if myRoot then
		if Settings.PlayerEsp then
			for _, player in ipairs(Players:GetPlayers()) do
				if player ~= LocalPlayer and player.Character then
					local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
					local root = player.Character:FindFirstChild("HumanoidRootPart")
					if humanoid and humanoid.Health > 0 and root then
						local distance = (root.Position - myRoot.Position).Magnitude
						if distance <= Settings.EspDistance then
							local ragdolled = player.Character:GetAttribute("IsRagdolled")
							local text = string.format(
								"%s\n%d HP  %d studs%s",
								player.Name,
								math.ceil(humanoid.Health),
								math.floor(distance),
								ragdolled and "  [RAGDOLLED]" or ""
							)
							local color = ragdolled and Color3.fromRGB(255, 200, 80) or Color3.fromRGB(255, 120, 120)
							visible[player.Character] = true
							local entry = espEntries[player.Character]
							if not entry then
								entry = createEsp(player.Character, root, color, text)
							end
							entry.Gui.Adornee = root
							entry.Label.Text = text
							entry.Label.TextColor3 = color
							entry.Highlight.FillColor = color
							entry.Highlight.OutlineColor = color
						end
					end
				end
			end
		end
		if Settings.CannonEsp then
			local cannons = workspace:FindFirstChild("Cannons")
			if cannons then
				for _, cannon in ipairs(cannons:GetChildren()) do
					local part = cannon:IsA("BasePart") and cannon or cannon:FindFirstChildWhichIsA("BasePart", true)
					if part then
						local distance = (part.Position - myRoot.Position).Magnitude
						if distance <= Settings.EspDistance then
							local text = string.format("CANNON\n%d studs", math.floor(distance))
							local color = Color3.fromRGB(120, 220, 255)
							visible[cannon] = true
							local entry = espEntries[cannon]
							if not entry then
								entry = createEsp(cannon, part, color, text)
							end
							entry.Gui.Adornee = part
							entry.Label.Text = text
						end
					end
				end
			end
		end
		if Settings.ThreatEsp then
			for model, displayName in pairs(threatModels) do
				if model.Parent then
					local part = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
					if part then
						local distance = (part.Position - myRoot.Position).Magnitude
						if distance <= Settings.EspDistance then
							local description = ThreatInfo and ThreatInfo.Descriptions and ThreatInfo.Descriptions[displayName]
							local text = string.format(
								"THREAT: %s\n%d studs%s",
								displayName,
								math.floor(distance),
								description and ("\n" .. description) or ""
							)
							local color = Color3.fromRGB(255, 140, 80)
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
	end
	for model, entry in pairs(espEntries) do
		if not visible[model] then
			entry.Gui:Destroy()
			entry.Highlight:Destroy()
			espEntries[model] = nil
		end
	end
end

local doubleJumpAt = 0
local function tryDoubleJump()
	local humanoid = getHumanoid()
	local character = getCharacter()
	if not humanoid or not character then
		return
	end
	if character:GetAttribute("IsRagdolled") then
		return
	end
	local now = os.clock()
	if now - doubleJumpAt < 0.2 then
		return
	end
	if humanoid:GetState() ~= Enum.HumanoidStateType.Freefall then
		return
	end
	doubleJumpAt = now
	local root = getRootPart()
	if root then
		root.AssemblyLinearVelocity = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z)
	end
	humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	logOnce("doublejump_ok", "double jump: re-jumping mid-air", "info")
end

ctx:Connect(UserInputService.JumpRequest, function()
	if Settings.DoubleJump then
		tryDoubleJump()
	end
end)

-- Threat feedback: the game announces HIT / DEATH for each threat.
task.spawn(function()
	local remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
	local client = remotes and remotes:WaitForChild("Client", 10)
	local gameRemotes = client and client:WaitForChild("Game", 10)
	local threats = gameRemotes and gameRemotes:WaitForChild("Threats", 10)
	local feedback = threats and threats:WaitForChild("ThreatFeedback", 10)
	if not (feedback and feedback:IsA("RemoteEvent")) then
		logOnce("threat_nofeedback", "threat feedback remote not found", "warn")
		return
	end
	ctx:Connect(feedback.OnClientEvent, function(threat, eventName)
		ctx:Log(string.format("[NOMERCY] threat %s: %s", tostring(threat), tostring(eventName)), "warn")
	end)
end)

---------------------------------------------------------------------
-- Player helpers
---------------------------------------------------------------------

local DEFAULT_GRAVITY = workspace.Gravity

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

local function applyGravity()
	workspace.Gravity = Settings.LowGravity and 60 or DEFAULT_GRAVITY
end

local function applyGodmode()
	local character = getCharacter()
	if character and Settings.Godmode then
		if not character:GetAttribute("SAFE") then
			character:SetAttribute("SAFE", true)
		end
	end
end

local function applyHover()
	local character = getCharacter()
	if character and Settings.Hover then
		if not character:GetAttribute("_HOVER_AVAIABLE") then
			character:SetAttribute("_HOVER_AVAIABLE")
		end
	end
end

local function revertRagdoll()
	local character = getCharacter()
	if not character or not character:GetAttribute("IsRagdolled") then
		return
	end
	if Ragdoll and type(Ragdoll.RevertRagdoll) == "function" then
		pcall(Ragdoll.RevertRagdoll, character)
		logOnce("ragdoll_ok", "anti-ragdoll: reverting ragdoll", "info")
	else
		logOnce("ragdoll_nolib", "anti-ragdoll: Ragdoll library not found", "warn")
	end
end

local nextSkillAt = {}

local function canFireSkill(name, interval)
	local now = os.clock()
	if now < (nextSkillAt[name] or 0) then
		return false
	end
	nextSkillAt[name] = now + interval
	return true
end

local function skillStep()
	if Settings.AutoParry and canFireSkill("Parry", 3) then
		fireSkill("Parry")
	end
	if Settings.AutoSlide and canFireSkill("Slide", 6) then
		fireSkill("Slide")
	end
	if Settings.AutoSmokeDash and canFireSkill("SmokeDash", 5) then
		fireSkill("Smoke Dash")
	end
	if Settings.AutoSpawnProtection and canFireSkill("SpawnProtection", 25) then
		fireSkill("Spawn Protection")
	end
	if Settings.AutoInflatable and canFireSkill("Inflatable", 2) then
		fireSkill("Inflatable platform")
	end
	if Settings.AutoFreezeFrame then
		local character = getCharacter()
		if character and character:GetAttribute("IsRagdolled") and canFireSkill("FreezeFrame", 1.5) then
			fireSkill("Freeze Frame")
		end
	end
end

---------------------------------------------------------------------
-- UI
---------------------------------------------------------------------

local Player = ctx:SubTab("Player", "Lucide:user")
local Skills = ctx:SubTab("Skills", "Lucide:sparkles")
local Visuals = ctx:SubTab("Visuals", "Lucide:eye")

Player:AddSection("Movement", "Lucide:gauge")
Player:AddToggle({
	Text = "Speed Boost",
	Description = "Overrides your walk speed",
	Icon = "Lucide:rabbit",
	Default = false,
	Flag = "nm_speed_on",
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
	Flag = "nm_speed",
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
	Flag = "nm_jump_on",
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
	Flag = "nm_jump",
	Callback = function(value)
		Settings.JumpPower = value
		applyJump()
	end,
})
Player:AddToggle({
	Text = "Infinite Jump",
	Description = "Lets you jump again while airborne",
	Icon = "Lucide:arrow-up-circle",
	Default = false,
	Flag = "nm_infinite_jump",
	Callback = function(value)
		Settings.InfiniteJump = value
	end,
})
Player:AddToggle({
	Text = "Double Jump",
	Description = "Re-jump while airborne (like the Double Jump core upgrade)",
	Icon = "Lucide:arrow-up-circle",
	Default = false,
	Flag = "nm_double_jump",
	Callback = function(value)
		Settings.DoubleJump = value
	end,
})
Player:AddToggle({
	Text = "Low Gravity",
	Description = "Cuts gravity so you float further",
	Icon = "Lucide:moon",
	Default = false,
	Flag = "nm_low_gravity",
	Callback = function(value)
		Settings.LowGravity = value
		applyGravity()
	end,
})

Player:AddSection("Survival", "Lucide:shield")
Player:AddToggle({
	Text = "Anti-Ragdoll",
	Description = "Reverts your ragdoll the moment you get hit",
	Icon = "Lucide:person-standing",
	Default = false,
	Flag = "nm_anti_ragdoll",
	Callback = function(value)
		Settings.AntiRagdoll = value
	end,
})
Player:AddToggle({
	Text = "Godmode (SAFE)",
	Description = "Keeps the game's SAFE attribute on you",
	Icon = "Lucide:shield-check",
	Default = false,
	Flag = "nm_godmode",
	Callback = function(value)
		Settings.Godmode = value
	end,
})
Player:AddToggle({
	Text = "Hover Boots",
	Description = "Grants the Hover boots passive",
	Icon = "Lucide:wind",
	Default = false,
	Flag = "nm_hover",
	Callback = function(value)
		Settings.Hover = value
	end,
})

Skills:AddSection("Active Skills", "Lucide:sparkles")
local TOGGLES = {
	{ Text = "Auto Parry", Flag = "nm_auto_parry", Key = "AutoParry", Desc = "Fires the Parry skill every 3s" },
	{ Text = "Auto Slide", Flag = "nm_auto_slide", Key = "AutoSlide", Desc = "Fires the Slide skill every 6s" },
	{ Text = "Auto Smoke Dash", Flag = "nm_auto_smoke", Key = "AutoSmokeDash", Desc = "Fires the Smoke Dash skill every 5s" },
	{
		Text = "Auto Spawn Protection",
		Flag = "nm_auto_spawn",
		Key = "AutoSpawnProtection",
		Desc = "Fires Spawn Protection every 25s",
	},
	{ Text = "Auto Inflatable Platform", Flag = "nm_auto_platform", Key = "AutoInflatable", Desc = "Drops a platform every 2s" },
	{
		Text = "Auto Freeze Frame",
		Flag = "nm_auto_freeze",
		Key = "AutoFreezeFrame",
		Desc = "Fire Freeze Frame while ragdolled",
	},
}
for _, def in ipairs(TOGGLES) do
	Skills:AddToggle({
		Text = def.Text,
		Description = def.Desc,
		Icon = "Lucide:zap",
		Default = false,
		Flag = def.Flag,
		Callback = function(value)
			Settings[def.Key] = value
		end,
	})
end

Visuals:AddSection("ESP", "Lucide:eye")
Visuals:AddToggle({
	Text = "Player ESP",
	Description = "Name, health, distance and ragdoll state",
	Icon = "Lucide:users",
	Default = false,
	Flag = "nm_player_esp",
	Callback = function(value)
		Settings.PlayerEsp = value
	end,
})
Visuals:AddToggle({
	Text = "Cannon ESP",
	Description = "Highlights the cannons with distance",
	Icon = "Lucide:target",
	Default = false,
	Flag = "nm_cannon_esp",
	Callback = function(value)
		Settings.CannonEsp = value
	end,
})
Visuals:AddToggle({
	Text = "Threat ESP",
	Description = "Highlights every threat with its name and counter hint",
	Icon = "Lucide:skull",
	Default = false,
	Flag = "nm_threat_esp",
	Callback = function(value)
		Settings.ThreatEsp = value
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
	Flag = "nm_esp_distance",
	Callback = function(value)
		Settings.EspDistance = value
	end,
})

---------------------------------------------------------------------
-- Background loops
---------------------------------------------------------------------

task.spawn(function()
	while ctx:Alive() do
		if Settings.PlayerEsp or Settings.CannonEsp or Settings.ThreatEsp then
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
		if Settings.Hover then
			pcall(applyHover)
		end
		if Settings.AntiRagdoll then
			pcall(revertRagdoll)
		end
		task.wait(0.2)
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
		pcall(skillStep)
		task.wait(0.2)
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
	Settings.InfiniteJump, Settings.AntiRagdoll, Settings.Godmode = false, false, false
	Settings.Hover, Settings.LowGravity = false, false
	Settings.PlayerEsp, Settings.CannonEsp = false, false
	Settings.ThreatEsp, Settings.DoubleJump = false, false
	Settings.AutoParry, Settings.AutoSlide, Settings.AutoSmokeDash = false, false, false
	Settings.AutoSpawnProtection, Settings.AutoFreezeFrame, Settings.AutoInflatable = false, false, false
	workspace.Gravity = DEFAULT_GRAVITY
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
