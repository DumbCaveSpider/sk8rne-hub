-- Survive Your Ideas
local ctx = ...
local task = ctx.task

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
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
	ctx:Log("[SYI] " .. message, level or "info")
end

ctx:Log("[SYI] module loaded", "info")

local Settings = {
	SpeedOn = false,
	Speed = 30,
	JumpOn = false,
	JumpPower = 100,
	InfiniteJump = false,
	Sprint = false,
	AntiRagdoll = false,
	EspPlayer = false,
	EspCreature = false,
	EspCoin = false,
	EspItem = false,
	EspDisaster = false,
	EspDistance = 500,
	AutoRoll = false,
}

---------------------------------------------------------------------
-- ESP
---------------------------------------------------------------------

local overlay = ctx:Track(Instance.new("ScreenGui"))
overlay.Name = "Sk8rneSYI"
overlay.ResetOnSpawn = false
overlay.IgnoreGuiInset = true
overlay.Parent = LocalPlayer:WaitForChild("PlayerGui")

local espEntries = {}

local function espPart(instance)
	if instance:IsA("BasePart") then
		return instance
	end
	if instance:IsA("Model") then
		return instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
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

local TAG_GROUPS = {
	{ Setting = "EspCreature", Label = "CREATURE", Color = Color3.fromRGB(255, 120, 120), Tags = { "Creature", "NextbotPupil", "SpiderRig", "TrollFace", "NameNpc" } },
	{ Setting = "EspCoin", Label = "COIN", Color = Color3.fromRGB(255, 220, 60), Tags = { "Coin" } },
	{ Setting = "EspItem", Label = "ITEM", Color = Color3.fromRGB(120, 220, 255), Tags = { "ItemBob", "Carryable", "AirDropFlare" } },
	{
		Setting = "EspDisaster",
		Label = "DISASTER",
		Color = Color3.fromRGB(255, 160, 60),
		Tags = { "LavaFlood", "Geyser", "TsunamiWave", "TornadoFx", "StormCloud", "StructureFlame", "GrassFlame", "LeafPile" },
	},
}

local function espStep()
	local myRoot = getRootPart()
	local visible = {}
	if myRoot then
		if Settings.EspPlayer then
			for _, player in ipairs(Players:GetPlayers()) do
				if player ~= LocalPlayer and player.Character then
					local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
					local root = player.Character:FindFirstChild("HumanoidRootPart")
					if humanoid and humanoid.Health > 0 and root then
						local distance = (root.Position - myRoot.Position).Magnitude
						if distance <= Settings.EspDistance then
							local text = string.format("%s\n%d HP  %d studs", player.Name, math.ceil(humanoid.Health), math.floor(distance))
							local color = Color3.fromRGB(255, 120, 120)
							visible[player.Character] = true
							local entry = espEntries[player.Character]
							if not entry then
								entry = createEsp(player.Character, root, color, text)
							end
							entry.Gui.Adornee = root
							entry.Label.Text = text
						end
					end
				end
			end
		end
		for _, group in ipairs(TAG_GROUPS) do
			if Settings[group.Setting] then
				for _, tag in ipairs(group.Tags) do
					for _, instance in ipairs(CollectionService:GetTagged(tag)) do
						local part = espPart(instance)
						if part and instance.Parent then
							local distance = (part.Position - myRoot.Position).Magnitude
							if distance <= Settings.EspDistance then
								local text = string.format("%s\n%d studs", group.Label, math.floor(distance))
								visible[instance] = true
								local entry = espEntries[instance]
								if not entry then
									entry = createEsp(instance, part, group.Color, text)
								end
								entry.Gui.Adornee = part
								entry.Label.Text = text
							end
						end
					end
				end
			end
		end
	end
	for instance, entry in pairs(espEntries) do
		if not visible[instance] then
			entry.Gui:Destroy()
			entry.Highlight:Destroy()
			espEntries[instance] = nil
		end
	end
end

---------------------------------------------------------------------
-- Remotes
---------------------------------------------------------------------

local function remotesFolder()
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local client = remotes and remotes:FindFirstChild("Client")
	local gameRemotes = client and client:FindFirstChild("Game")
	return gameRemotes or remotes
end

local function findRemote(name)
	local folder = remotesFolder()
	if not folder then
		return nil
	end
	return folder:FindFirstChild(name)
end

local function fireRemote(name, ...)
	local remote = findRemote(name)
	if not (remote and (remote:IsA("RemoteEvent") or remote:IsA("UnreliableRemoteEvent"))) then
		logOnce("remote_missing_" .. name, "remote not found: " .. name, "warn")
		return false
	end
	pcall(function()
		remote:FireServer(...)
	end)
	return true
end

local function itemRequest()
	local items = ReplicatedStorage:FindFirstChild("Items")
	local remotes = items and items:FindFirstChild("Remotes")
	return remotes and remotes:FindFirstChild("Request")
end

local function itemRequestInvoke(...)
	local request = itemRequest()
	if not (request and request:IsA("RemoteFunction")) then
		logOnce("item_request_missing", "Items.Remotes.Request not found", "warn")
		return nil
	end
	local ok, result = pcall(function()
		return request:InvokeServer(...)
	end)
	if not ok then
		logOnce("item_request_failed", "item request failed: " .. tostring(result), "warn")
	end
	return ok and result or nil
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

local function applySprint()
	if Settings.Sprint then
		fireRemote("SetSprint", true)
	end
end

local function applyAntiRagdoll()
	local character = getCharacter()
	if not character then
		return
	end
	if character:GetAttribute("IsRagdolled") then
		pcall(function()
			character:SetAttribute("IsRagdolled", false)
		end)
		logOnce("ragdoll_ok", "anti-ragdoll: cleared IsRagdolled", "info")
	end
	local humanoid = getHumanoid()
	if humanoid and humanoid.PlatformStand then
		humanoid.PlatformStand = false
	end
end

local function infiniteJump()
	local humanoid = getHumanoid()
	if humanoid and humanoid:GetState() == Enum.HumanoidStateType.Freefall then
		humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	end
end

---------------------------------------------------------------------
-- Item roll
---------------------------------------------------------------------

local nextRollAt = 0
local function autoRoll()
	local now = os.clock()
	if now < nextRollAt then
		return
	end
	nextRollAt = now + 2
	local ok = fireRemote("Spin")
	if not ok then
		itemRequestInvoke("spin")
	end
	logOnce("roll_ok", "auto roll: firing the item spin", "info")
end

---------------------------------------------------------------------
-- UI
---------------------------------------------------------------------

local Player = ctx:SubTab("Player", "Lucide:user")
local Visuals = ctx:SubTab("Visuals", "Lucide:eye")
local Words = ctx:SubTab("Words", "Lucide:type")
local Items = ctx:SubTab("Items", "Lucide:package")

Player:AddSection("Movement", "Lucide:gauge")
Player:AddToggle({
	Text = "Speed Boost",
	Description = "Overrides your walk speed",
	Icon = "Lucide:rabbit",
	Default = false,
	Flag = "syi_speed_on",
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
	Flag = "syi_speed",
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
	Flag = "syi_jump_on",
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
	Flag = "syi_jump",
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
	Flag = "syi_infinite_jump",
	Callback = function(value)
		Settings.InfiniteJump = value
	end,
})
Player:AddToggle({
	Text = "Force Sprint",
	Description = "Keeps the game's sprint state on",
	Icon = "Lucide:wind",
	Default = false,
	Flag = "syi_sprint",
	Callback = function(value)
		Settings.Sprint = value
	end,
})
Player:AddToggle({
	Text = "Anti-Ragdoll",
	Description = "Clears the ragdoll state when you get hit",
	Icon = "Lucide:person-standing",
	Default = false,
	Flag = "syi_anti_ragdoll",
	Callback = function(value)
		Settings.AntiRagdoll = value
	end,
})

Visuals:AddSection("ESP", "Lucide:eye")
Visuals:AddToggle({
	Text = "Player ESP",
	Description = "Shows players with health and distance",
	Icon = "Lucide:users",
	Default = false,
	Flag = "syi_esp_player",
	Callback = function(value)
		Settings.EspPlayer = value
	end,
})
Visuals:AddToggle({
	Text = "Creature ESP",
	Description = "Highlights creatures, nextbots and bosses",
	Icon = "Lucide:skull",
	Default = false,
	Flag = "syi_esp_creature",
	Callback = function(value)
		Settings.EspCreature = value
	end,
})
Visuals:AddToggle({
	Text = "Coin ESP",
	Description = "Highlights loose coins",
	Icon = "Lucide:coins",
	Default = false,
	Flag = "syi_esp_coin",
	Callback = function(value)
		Settings.EspCoin = value
	end,
})
Visuals:AddToggle({
	Text = "Item ESP",
	Description = "Highlights floating items and air drops",
	Icon = "Lucide:package",
	Default = false,
	Flag = "syi_esp_item",
	Callback = function(value)
		Settings.EspItem = value
	end,
})
Visuals:AddToggle({
	Text = "Disaster ESP",
	Description = "Highlights incoming hazards (lava, tsunami, tornados, fire...)",
	Icon = "Lucide:flame",
	Default = false,
	Flag = "syi_esp_disaster",
	Callback = function(value)
		Settings.EspDisaster = value
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
	Flag = "syi_esp_distance",
	Callback = function(value)
		Settings.EspDistance = value
	end,
})

local wordBox = Words:AddTextbox({
	Text = "Word",
	Description = "Type a meta word (e.g. /god, /lag, /jackpot)",
	Icon = "Lucide:type",
	Placeholder = "/god",
	Default = "/god",
	Flag = "syi_word",
})
Words:AddButton({
	Text = "Trigger Word",
	Description = "Sends the typed word to the game",
	Icon = "Lucide:send",
	Callback = function()
		local word = wordBox:Get()
		if type(word) ~= "string" or word == "" then
			return
		end
		if fireRemote("WordTyped", word) or fireRemote("SubmitWord", word) or fireRemote("MetaWord", word) then
			ctx:Log("[SYI] word sent: " .. word, "info")
		else
			ctx:Log("[SYI] no word remote found (WordTyped / SubmitWord / MetaWord)", "warn")
		end
	end,
})
Words:AddParagraph({
	Title = "Known words",
	Icon = "Lucide:list",
	Text = "/admin, /reset, /chaos, /god, /double, /secret, /lag, /undo, /ghost, /jackpot",
})

Items:AddToggle({
	Text = "Auto Roll",
	Description = "Spins the item gacha every 2s",
	Icon = "Lucide:dices",
	Default = false,
	Flag = "syi_auto_roll",
	Callback = function(value)
		Settings.AutoRoll = value
	end,
})

---------------------------------------------------------------------
-- Loops
---------------------------------------------------------------------

task.spawn(function()
	while ctx:Alive() do
		if Settings.EspPlayer or Settings.EspCreature or Settings.EspCoin or Settings.EspItem or Settings.EspDisaster then
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
		if Settings.Sprint then
			pcall(applySprint)
		end
		if Settings.AntiRagdoll then
			pcall(applyAntiRagdoll)
		end
		task.wait(0.25)
	end
end)

task.spawn(function()
	while ctx:Alive() do
		if Settings.InfiniteJump then
			pcall(infiniteJump)
		end
		task.wait(0.1)
	end
end)

task.spawn(function()
	while ctx:Alive() do
		if Settings.AutoRoll then
			pcall(autoRoll)
		end
		task.wait(0.5)
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
	Settings.InfiniteJump, Settings.Sprint, Settings.AntiRagdoll = false, false, false
	Settings.EspPlayer, Settings.EspCreature, Settings.EspCoin = false, false, false
	Settings.EspItem, Settings.EspDisaster, Settings.AutoRoll = false, false, false
	for instance, entry in pairs(espEntries) do
		entry.Gui:Destroy()
		entry.Highlight:Destroy()
		espEntries[instance] = nil
	end
	local humanoid = getHumanoid()
	if humanoid then
		humanoid.WalkSpeed = 16
	end
end)
