-- GRACE
local ctx = ...
local task = ctx.task

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local function getRootPart()
	local character = LocalPlayer.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end

local function getHumanoid()
	local character = LocalPlayer.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

local Settings = {
	SpeedOn = false,
	Speed = 32,
	JumpOn = false,
	JumpPower = 120,
	EntityEsp = false,
	DoorWaypoint = false,
	EventNotifier = false,
	EspDistance = 500,
}

-- What each entity actually does, shown in the event panel.
local EVENT_INFO = {
	Covet = { Title = "COVET", Hint = "Chasing you — sprint to the saferoom", Color = Color3.fromRGB(255, 80, 80) },
	aCovet = { Title = "COVET (bound)", Hint = "Chasing you — sprint to the saferoom", Color = Color3.fromRGB(255, 80, 80) },
	Sundial = { Title = "SUNDIAL", Hint = "Parry the moment it looks at you", Color = Color3.fromRGB(255, 200, 80) },
	SundialT = { Title = "SUNDIAL (bound)", Hint = "Parry the moment it looks at you", Color = Color3.fromRGB(255, 200, 80) },
	Seesay = { Title = "SEESAY", Hint = "Look at it and parry", Color = Color3.fromRGB(150, 120, 255) },
	Innego = { Title = "INNEGO", Hint = "Screen entity — keep moving", Color = Color3.fromRGB(120, 220, 255) },
	InnegoT = { Title = "INNEGO (bound)", Hint = "Screen entity — keep moving", Color = Color3.fromRGB(120, 220, 255) },
	StemUI = { Title = "STEM", Hint = "Screen entity — keep moving", Color = Color3.fromRGB(120, 255, 160) },
	Doppel = { Title = "DOPPEL", Hint = "Fake player — don't trust it", Color = Color3.fromRGB(200, 200, 200) },
	bDoppel = { Title = "DOPPEL", Hint = "Fake player — don't trust it", Color = Color3.fromRGB(200, 200, 200) },
	PulseUI = { Title = "IRE", Hint = "Stay on the ground", Color = Color3.fromRGB(255, 120, 255) },
}

local WORLD_EVENTS = {
	Covet = true,
	aCovet = true,
	Sundial = true,
	SundialT = true,
	Seesay = true,
}

local GUI_EVENTS = {
	Innego = true,
	InnegoT = true,
	StemUI = true,
	Doppel = true,
	bDoppel = true,
	PulseUI = true,
}

---------------------------------------------------------------------
-- Overlay
---------------------------------------------------------------------

local overlay = ctx:Track(Instance.new("ScreenGui"))
overlay.Name = "Sk8rneGrace"
overlay.ResetOnSpawn = false
overlay.IgnoreGuiInset = true
overlay.Parent = LocalPlayer:WaitForChild("PlayerGui")

local espEntries = {}

local function createEsp(model, part, info)
	local gui = Instance.new("BillboardGui")
	gui.Name = "Sk8rneEsp"
	gui.Size = UDim2.fromOffset(180, 42)
	gui.StudsOffset = Vector3.new(0, 4, 0)
	gui.AlwaysOnTop = true
	gui.Adornee = part
	gui.Parent = overlay

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 13
	label.TextColor3 = info.Color
	label.TextStrokeTransparency = 0.4
	label.Text = info.Title
	label.Parent = gui

	local highlight = Instance.new("Highlight")
	highlight.Name = "Sk8rneEspHighlight"
	highlight.Adornee = model
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.FillColor = info.Color
	highlight.FillTransparency = 0.75
	highlight.OutlineColor = info.Color
	highlight.OutlineTransparency = 0
	highlight.Parent = model

	local entry = { Gui = gui, Label = label, Highlight = highlight, Info = info }
	espEntries[model] = entry
	return entry
end

local function espStep()
	local myRoot = getRootPart()
	local visible = {}
	if myRoot then
		for _, model in ipairs(workspace:GetChildren()) do
			local info = WORLD_EVENTS[model.Name] and EVENT_INFO[model.Name]
			if info then
				local part = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
				if part then
					local distance = (part.Position - myRoot.Position).Magnitude
					if distance <= Settings.EspDistance then
						visible[model] = true
						local entry = espEntries[model]
						if not entry then
							entry = createEsp(model, part, info)
						end
						entry.Gui.Adornee = part
						entry.Label.Text = string.format("%s\n%d studs", info.Title, math.floor(distance))
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
-- Door waypoint
---------------------------------------------------------------------

local waypointGui = nil
local waypointLabel = nil
local waypointHighlight = nil
local waypointAdornee = nil

local function doorPartOf(instance)
	if instance:IsA("BasePart") then
		return instance
	end
	if instance:IsA("Model") then
		local child = instance:FindFirstChild("Door")
		if child and child:IsA("BasePart") then
			return child
		end
		return instance.PrimaryPart
	end
	return nil
end

local function nearestDoor()
	local myRoot = getRootPart()
	if not myRoot then
		return nil
	end
	local best, bestDistance = nil, math.huge
	local seen = {}
	for _, folderName in ipairs({ "Rooms", "SideRooms" }) do
		local folder = workspace:FindFirstChild(folderName)
		if folder then
			for _, descendant in ipairs(folder:GetDescendants()) do
				if descendant.Name == "Door" then
					local part = doorPartOf(descendant)
					if part and not seen[part] then
						seen[part] = true
						-- A door that is already open has been passed, so skip it.
						if part:GetAttribute("Open") ~= true then
							local distance = (part.Position - myRoot.Position).Magnitude
							if distance < bestDistance then
								best, bestDistance = part, distance
							end
						end
					end
				end
			end
		end
	end
	return best, bestDistance
end

local function removeWaypoint()
	if waypointGui then
		waypointGui:Destroy()
		waypointGui = nil
		waypointLabel = nil
	end
	if waypointHighlight then
		waypointHighlight:Destroy()
		waypointHighlight = nil
	end
	waypointAdornee = nil
end

local function ensureWaypoint()
	if waypointGui then
		return
	end
	waypointGui = Instance.new("BillboardGui")
	waypointGui.Name = "Sk8rneWaypoint"
	waypointGui.Size = UDim2.fromOffset(170, 44)
	waypointGui.StudsOffset = Vector3.new(0, 5, 0)
	waypointGui.AlwaysOnTop = true
	waypointGui.Parent = overlay

	waypointLabel = Instance.new("TextLabel")
	waypointLabel.Size = UDim2.fromScale(1, 1)
	waypointLabel.BackgroundTransparency = 1
	waypointLabel.Font = Enum.Font.GothamBold
	waypointLabel.TextSize = 14
	waypointLabel.TextColor3 = Color3.fromRGB(120, 255, 180)
	waypointLabel.TextStrokeTransparency = 0.35
	waypointLabel.Text = "DOOR"
	waypointLabel.Parent = waypointGui
end

local function waypointStep()
	local doorPart, distance = nearestDoor()
	if not doorPart then
		removeWaypoint()
		return
	end
	ensureWaypoint()
	waypointGui.Adornee = doorPart
	waypointLabel.Text = string.format("DOOR\n%d studs", math.floor(distance))
	if waypointAdornee ~= doorPart then
		if waypointHighlight then
			waypointHighlight:Destroy()
		end
		waypointAdornee = doorPart
		local adorn = doorPart.Parent
		if not adorn then
			adorn = doorPart
		end
		waypointHighlight = Instance.new("Highlight")
		waypointHighlight.Name = "Sk8rneWaypointHighlight"
		waypointHighlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		waypointHighlight.FillColor = Color3.fromRGB(120, 255, 180)
		waypointHighlight.FillTransparency = 0.75
		waypointHighlight.OutlineColor = Color3.fromRGB(120, 255, 180)
		waypointHighlight.OutlineTransparency = 0
		waypointHighlight.Adornee = adorn
		waypointHighlight.Parent = adorn
	end
end

---------------------------------------------------------------------
-- Event notifier
---------------------------------------------------------------------

local eventFrame = Instance.new("Frame")
eventFrame.Name = "EventPanel"
eventFrame.Size = UDim2.fromOffset(340, 68)
eventFrame.Position = UDim2.new(0.5, -170, 0, 14)
eventFrame.BackgroundColor3 = Color3.fromRGB(16, 16, 20)
eventFrame.BackgroundTransparency = 0.25
eventFrame.BorderSizePixel = 0
eventFrame.Visible = false
eventFrame.Parent = overlay

local eventCorner = Instance.new("UICorner")
eventCorner.CornerRadius = UDim.new(0, 8)
eventCorner.Parent = eventFrame

local eventTitle = Instance.new("TextLabel")
eventTitle.Name = "Title"
eventTitle.Size = UDim2.new(1, -16, 0, 28)
eventTitle.Position = UDim2.fromOffset(8, 6)
eventTitle.BackgroundTransparency = 1
eventTitle.Font = Enum.Font.GothamBold
eventTitle.TextSize = 17
eventTitle.TextXAlignment = Enum.TextXAlignment.Left
eventTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
eventTitle.Text = ""
eventTitle.Parent = eventFrame

local eventHint = Instance.new("TextLabel")
eventHint.Name = "Hint"
eventHint.Size = UDim2.new(1, -16, 0, 24)
eventHint.Position = UDim2.fromOffset(8, 34)
eventHint.BackgroundTransparency = 1
eventHint.Font = Enum.Font.Gotham
eventHint.TextSize = 14
eventHint.TextXAlignment = Enum.TextXAlignment.Left
eventHint.TextColor3 = Color3.fromRGB(200, 200, 210)
eventHint.Text = ""
eventHint.Parent = eventFrame

local function activeEvents()
	local active = {}
	for name in pairs(WORLD_EVENTS) do
		local instance = workspace:FindFirstChild(name)
		if instance and instance:IsA("Model") then
			table.insert(active, name)
		end
	end
	local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
	if playerGui then
		for name in pairs(GUI_EVENTS) do
			if playerGui:FindFirstChild(name) then
				table.insert(active, name)
			end
		end
	end
	return active
end

local function eventStep()
	if not Settings.EventNotifier then
		eventFrame.Visible = false
		return
	end
	local active = activeEvents()
	if #active == 0 then
		eventFrame.Visible = true
		eventTitle.Text = "NO ACTIVE EVENT"
		eventTitle.TextColor3 = Color3.fromRGB(140, 200, 140)
		eventHint.Text = "Keep moving to the next saferoom"
		return
	end
	local name = active[1]
	local info = EVENT_INFO[name]
	eventFrame.Visible = true
	eventTitle.Text = info and info.Title or name
	eventTitle.TextColor3 = info and info.Color or Color3.fromRGB(255, 255, 255)
	eventHint.Text = info and info.Hint or "Unknown event"
	if #active > 1 then
		eventHint.Text = eventHint.Text .. string.format("  (+%d more)", #active - 1)
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

---------------------------------------------------------------------
-- UI
---------------------------------------------------------------------

local Player = ctx:SubTab("Player", "Lucide:user")
local Visuals = ctx:SubTab("Visuals", "Lucide:eye")
local Events = ctx:SubTab("Events", "Lucide:alert-triangle")

Player:AddSection("Movement", "Lucide:gauge")
Player:AddToggle({
	Text = "Speed Boost",
	Description = "Overrides your walk speed",
	Icon = "Lucide:rabbit",
	Default = false,
	Flag = "gr_speed_on",
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
	Default = 32,
	Increment = 1,
	Suffix = " studs",
	Flag = "gr_speed",
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
	Flag = "gr_jump_on",
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
	Default = 120,
	Increment = 5,
	Flag = "gr_jump",
	Callback = function(value)
		Settings.JumpPower = value
		applyJump()
	end,
})

Visuals:AddSection("ESP", "Lucide:eye")
Visuals:AddToggle({
	Text = "Entity ESP",
	Description = "Highlights and labels GRACE entities through walls",
	Icon = "Lucide:skull",
	Default = false,
	Flag = "gr_entity_esp",
	Callback = function(value)
		Settings.EntityEsp = value
	end,
})
Visuals:AddSlider({
	Text = "ESP Distance",
	Description = "How far away entities are drawn",
	Icon = "Lucide:radar",
	Min = 50,
	Max = 2000,
	Default = 500,
	Increment = 50,
	Suffix = " studs",
	Flag = "gr_esp_distance",
	Callback = function(value)
		Settings.EspDistance = value
	end,
})

Visuals:AddSection("Navigation", "Lucide:map")
Visuals:AddToggle({
	Text = "Door Waypoint",
	Description = "Points to the next unopened door and clears once you pass it",
	Icon = "Lucide:map-pin",
	Default = false,
	Flag = "gr_door_waypoint",
	Callback = function(value)
		Settings.DoorWaypoint = value
		if not value then
			removeWaypoint()
		end
	end,
})

Events:AddSection("Event Notifier", "Lucide:alert-triangle")
Events:AddToggle({
	Text = "Event Notifier",
	Description = "Shows the active entity event and what it will do",
	Icon = "Lucide:alert-triangle",
	Default = false,
	Flag = "gr_event_notifier",
	Callback = function(value)
		Settings.EventNotifier = value
		if not value then
			eventFrame.Visible = false
		end
	end,
})

---------------------------------------------------------------------
-- Background loops
---------------------------------------------------------------------

task.spawn(function()
	while ctx:Alive() do
		if Settings.EntityEsp then
			pcall(espStep)
		end
		task.wait(0.15)
	end
end)

task.spawn(function()
	while ctx:Alive() do
		if Settings.DoorWaypoint then
			pcall(waypointStep)
		end
		task.wait(0.2)
	end
end)

task.spawn(function()
	while ctx:Alive() do
		pcall(eventStep)
		task.wait(0.3)
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
		task.wait(0.25)
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
	Settings.EntityEsp, Settings.DoorWaypoint, Settings.EventNotifier = false, false, false
	for _, entry in pairs(espEntries) do
		entry.Gui:Destroy()
		entry.Highlight:Destroy()
	end
	table.clear(espEntries)
	removeWaypoint()
	if eventFrame then
		eventFrame.Visible = false
	end
	local humanoid = getHumanoid()
	if humanoid then
		humanoid.WalkSpeed = 16
	end
end)
