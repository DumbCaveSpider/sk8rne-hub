-- GRACE
local ctx = ...
local task = ctx.task

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
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
	NoParryCooldown = false,
	AutoStartRound = false,
	StopWave = 0,
	AutoParry = false,
	CounterAttack = false,
	BestModifier = false,
	TriggerLevers = false,
	LeverEsp = false,
	LeverRange = 120,
	SafeZoneWaypoint = false,
	DestroyMetalDoors = false,
}

-- Debug logging: each key only logs once so the console stays readable.
local loggedOnce = {}
local function logOnce(key, message, level)
	if loggedOnce[key] then
		return
	end
	loggedOnce[key] = true
	ctx:Log("[GRACE] " .. message, level or "info")
end

ctx:Log("[GRACE] module loaded", "info")

-- Feedback: log successful counters, deaths and the end of the run.
task.spawn(function()
	local parryRemote = ReplicatedStorage:WaitForChild("ClientParryAttempt", 10)
	local response = parryRemote and parryRemote:FindFirstChild("Response")
	if response and response:IsA("BindableEvent") then
		ctx:Connect(response.Event, function(name)
			ctx:Log("[GRACE] countered " .. tostring(name), "info")
		end)
	end
end)

ctx:Connect(LocalPlayer:GetAttributeChangedSignal("Dead"), function()
	if LocalPlayer:GetAttribute("Dead") then
		ctx:Log("[GRACE] you died", "warn")
	end
end)
if LocalPlayer:GetAttribute("Dead") then
	ctx:Log("[GRACE] you are already dead", "warn")
end

task.spawn(function()
	local timer = workspace:WaitForChild("DEATHTIMER", 10)
	if not timer then
		return
	end
	local logged = false
	ctx:Connect(timer.Changed, function(value)
		local number = tonumber(value)
		if not logged and number and number <= 0 then
			logged = true
			ctx:Log("[GRACE] game over — the timer ran out", "warn")
		end
	end)
end)

-- Every entity we can recognise, plus how to counter it. Keyed by lowercase name.
local ENTITY_INFO = {
	covet = { Title = "COVET", Counter = "Face it and parry when it reaches you", Color = Color3.fromRGB(255, 80, 80) },
	acovet = { Title = "COVET (bound)", Counter = "Face it and parry when it reaches you", Color = Color3.fromRGB(255, 80, 80) },
	sundial = { Title = "SUNDIAL", Counter = "Look UP at it and parry", Color = Color3.fromRGB(255, 200, 80) },
	sundialt = { Title = "SUNDIAL (bound)", Counter = "Look UP at it and parry", Color = Color3.fromRGB(255, 200, 80) },
	seesay = { Title = "SEESAY", Counter = "Look AT it and parry", Color = Color3.fromRGB(150, 120, 255) },
	innego = { Title = "INNEGO", Counter = "Screen entity — keep moving", Color = Color3.fromRGB(120, 220, 255) },
	innegot = { Title = "INNEGO (bound)", Counter = "Screen entity — keep moving", Color = Color3.fromRGB(120, 220, 255) },
	stemui = { Title = "STEM", Counter = "Screen entity — keep moving", Color = Color3.fromRGB(120, 255, 160) },
	doppel = { Title = "DOPPEL", Counter = "Fake player — don't trust it", Color = Color3.fromRGB(200, 200, 200) },
	bdoppel = { Title = "DOPPEL", Counter = "Fake player — don't trust it", Color = Color3.fromRGB(200, 200, 200) },
	pulseui = { Title = "IRE", Counter = "Stay on the ground (don't jump)", Color = Color3.fromRGB(255, 120, 255) },
	fool = { Title = "FOOL", Counter = "Face it and parry (several times)", Color = Color3.fromRGB(255, 160, 120) },
	craven = { Title = "CRAVEN", Counter = "Face it and parry", Color = Color3.fromRGB(200, 120, 120) },
	rue = { Title = "RUE", Counter = "Face it and parry once", Color = Color3.fromRGB(180, 140, 255) },
	drain = { Title = "DRAIN", Counter = "Face it and parry", Color = Color3.fromRGB(140, 200, 140) },
	dozer = { Title = "DOZER", Counter = "Face it and parry", Color = Color3.fromRGB(160, 160, 220) },
	litany = { Title = "LITANY", Counter = "Face it and parry", Color = Color3.fromRGB(220, 180, 120) },
	carnation = { Title = "CARNATION", Counter = "Face it and parry", Color = Color3.fromRGB(255, 120, 160) },
	goatman = { Title = "GOATMAN", Counter = "Face it and parry", Color = Color3.fromRGB(200, 200, 160) },
	slugfish = { Title = "SLUGFISH", Counter = "Face it and parry", Color = Color3.fromRGB(120, 180, 160) },
	kookoo = { Title = "KOOKOO", Counter = "Face it and parry", Color = Color3.fromRGB(255, 200, 120) },
	joey = { Title = "JOEY", Counter = "Face it and parry", Color = Color3.fromRGB(240, 200, 140) },
	elkman = { Title = "ELKMAN", Counter = "Face it and parry", Color = Color3.fromRGB(180, 160, 140) },
	sorrow = { Title = "SORROW", Counter = "Face it and parry", Color = Color3.fromRGB(140, 140, 200) },
	woed = { Title = "WOED", Counter = "Face it and parry", Color = Color3.fromRGB(160, 120, 200) },
	zomber = { Title = "ZOMBER", Counter = "Face it and parry", Color = Color3.fromRGB(140, 180, 120) },
	mime = { Title = "MIME", Counter = "Face it and parry", Color = Color3.fromRGB(200, 200, 200) },
	snap = { Title = "SNAP", Counter = "Face it and parry", Color = Color3.fromRGB(220, 220, 160) },
	duk = { Title = "DUK", Counter = "Face it and parry", Color = Color3.fromRGB(160, 160, 160) },
	tragedy = { Title = "TRAGEDY", Counter = "Face it and parry", Color = Color3.fromRGB(180, 100, 100) },
	eyes = { Title = "EYES", Counter = "Face it and parry", Color = Color3.fromRGB(255, 140, 140) },
}

local function entityInfo(name)
	return ENTITY_INFO[name] or ENTITY_INFO[string.lower(name)]
end

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
	gui.Size = UDim2.fromOffset(200, 58)
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

-- Levers/sockets are ClickPrompt-tagged prompts and plugs are PickupPlug-tagged models.
local function nearbyLevers(maxDistance)
	local myRoot = getRootPart()
	if not myRoot then
		return {}
	end
	local limit = maxDistance or Settings.LeverRange
	local found = {}
	local seen = {}
	local function consider(instance, kind)
		local prompt
		if instance:IsA("ProximityPrompt") then
			prompt = instance
		else
			prompt = instance:FindFirstChildWhichIsA("ProximityPrompt", true)
		end
		if not prompt or seen[prompt] then
			return
		end
		local part = prompt.Parent
		if not part or not part:IsA("BasePart") then
			return
		end
		seen[prompt] = true
		local distance = (part.Position - myRoot.Position).Magnitude
		if distance <= limit then
			table.insert(found, { Prompt = prompt, Kind = kind, Part = part, Distance = distance })
		end
	end
	for _, prompt in ipairs(CollectionService:GetTagged("ClickPrompt")) do
		consider(prompt, "LEVER")
	end
	for _, plug in ipairs(CollectionService:GetTagged("PickupPlug")) do
		consider(plug, "PLUG")
	end
	return found
end

local function espStep()
	local myRoot = getRootPart()
	local visible = {}
	if myRoot then
		for _, model in ipairs(workspace:GetChildren()) do
			local info = entityInfo(model.Name)
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
						entry.Label.Text = string.format("%s\n%d studs\n%s", info.Title, math.floor(distance), info.Counter)
					end
				end
			end
		end
	end
	if myRoot and Settings.LeverEsp then
		for _, lever in ipairs(nearbyLevers(Settings.EspDistance)) do
			local color = lever.Kind == "PLUG" and Color3.fromRGB(255, 220, 60) or Color3.fromRGB(120, 220, 255)
			local key = lever.Part
			visible[key] = true
			local entry = espEntries[key]
			if not entry then
				entry = createEsp(key, lever.Part, { Title = lever.Kind, Color = color })
			end
			entry.Gui.Adornee = lever.Part
			entry.Label.Text = string.format("%s\n%d studs", lever.Kind, math.floor(lever.Distance))
			entry.Label.TextColor3 = color
			entry.Highlight.FillColor = color
			entry.Highlight.OutlineColor = color
		end
	end
	for model, entry in pairs(espEntries) do
		if not visible[model] then
			entry.Gui:Destroy()
			entry.Highlight:Destroy()
			espEntries[model] = nil
		end
	end
	local count = 0
	for _ in pairs(visible) do
		count += 1
	end
	if count > 0 then
		logOnce("esp_found", string.format("entity ESP: drawing %d target(s)", count), "info")
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
		logOnce("waypoint_none", "door waypoint: no unopened door found (cleared)", "info")
		return
	end
	logOnce("waypoint_found", "door waypoint: targeting " .. doorPart:GetFullName(), "info")
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
-- Safe zone waypoint + metal doors
---------------------------------------------------------------------

local safeZoneGui = nil
local safeZoneLabel = nil
local safeEntranceGui = nil
local safeEntranceLabel = nil

local function findSaferoom()
	for _, folderName in ipairs({ "Rooms", "SideRooms" }) do
		local folder = workspace:FindFirstChild(folderName)
		if folder then
			for _, room in ipairs(folder:GetChildren()) do
				local kind = room:GetAttribute("Room")
				if kind == "Saferoom" or kind == "MayhemSaferoom" or room.Name == "Saferoom" then
					return room
				end
			end
		end
	end
	return nil
end

local function safeEntrancePart(room)
	local holyDoor = room:FindFirstChild("HolyDoor", true)
	if holyDoor then
		local part = holyDoor:FindFirstChildWhichIsA("BasePart", true)
		if part then
			return part
		end
	end
	return room:FindFirstChildWhichIsA("BasePart", true)
end

local function ensureSafeZoneGui()
	if safeZoneGui then
		return
	end
	safeZoneGui = Instance.new("BillboardGui")
	safeZoneGui.Name = "Sk8rneSafeZone"
	safeZoneGui.Size = UDim2.fromOffset(170, 44)
	safeZoneGui.StudsOffset = Vector3.new(0, 6, 0)
	safeZoneGui.AlwaysOnTop = true
	safeZoneGui.Parent = overlay
	safeZoneLabel = Instance.new("TextLabel")
	safeZoneLabel.Size = UDim2.fromScale(1, 1)
	safeZoneLabel.BackgroundTransparency = 1
	safeZoneLabel.Font = Enum.Font.GothamBold
	safeZoneLabel.TextSize = 14
	safeZoneLabel.TextColor3 = Color3.fromRGB(120, 255, 180)
	safeZoneLabel.TextStrokeTransparency = 0.35
	safeZoneLabel.Text = "SAFE ZONE"
	safeZoneLabel.Parent = safeZoneGui

	safeEntranceGui = Instance.new("BillboardGui")
	safeEntranceGui.Name = "Sk8rneSafeEntrance"
	safeEntranceGui.Size = UDim2.fromOffset(170, 44)
	safeEntranceGui.StudsOffset = Vector3.new(0, 5, 0)
	safeEntranceGui.AlwaysOnTop = true
	safeEntranceGui.Parent = overlay
	safeEntranceLabel = Instance.new("TextLabel")
	safeEntranceLabel.Size = UDim2.fromScale(1, 1)
	safeEntranceLabel.BackgroundTransparency = 1
	safeEntranceLabel.Font = Enum.Font.GothamBold
	safeEntranceLabel.TextSize = 14
	safeEntranceLabel.TextColor3 = Color3.fromRGB(120, 220, 255)
	safeEntranceLabel.TextStrokeTransparency = 0.35
	safeEntranceLabel.Text = "SAFE ZONE ENTRANCE"
	safeEntranceLabel.Parent = safeEntranceGui
end

local function removeSafeZone()
	if safeZoneGui then
		safeZoneGui:Destroy()
		safeZoneGui = nil
		safeZoneLabel = nil
	end
	if safeEntranceGui then
		safeEntranceGui:Destroy()
		safeEntranceGui = nil
		safeEntranceLabel = nil
	end
end

local function safeZoneStep()
	local room = findSaferoom()
	if not room then
		removeSafeZone()
		return
	end
	local myRoot = getRootPart()
	local pivot = room:GetPivot().Position
	local distance = myRoot and (pivot - myRoot.Position).Magnitude or 0
	if distance <= 12 then
		removeSafeZone()
		logOnce("safezone_inside", "safe zone: you are inside", "info")
		return
	end
	ensureSafeZoneGui()
	safeZoneGui.Adornee = room
	safeZoneLabel.Text = string.format("SAFE ZONE\n%d studs", math.floor(distance))
	local entrance = safeEntrancePart(room)
	if entrance then
		safeEntranceGui.Adornee = entrance
		safeEntranceGui.Enabled = true
		local entranceDistance = myRoot and (entrance.Position - myRoot.Position).Magnitude or 0
		safeEntranceLabel.Text = string.format("SAFE ZONE ENTRANCE\n%d studs", math.floor(entranceDistance))
	else
		safeEntranceGui.Enabled = false
	end
	logOnce("safezone_found", "safe zone: targeting " .. room:GetFullName(), "info")
end

local function findBlastDoors()
	local found = {}
	for _, folderName in ipairs({ "Rooms", "SideRooms" }) do
		local folder = workspace:FindFirstChild(folderName)
		if folder then
			for _, descendant in ipairs(folder:GetDescendants()) do
				if descendant.Name == "Door" and (descendant:GetAttribute("BlastDoor") or (descendant.Parent and descendant.Parent:GetAttribute("BlastDoor"))) then
					table.insert(found, descendant)
				end
			end
		end
	end
	return found
end

-- ForceOpen is the same remote the game's slide-into-blast-door move uses.
local function destroyMetalDoors()
	local events = ReplicatedStorage:FindFirstChild("Events")
	local forceOpen = events and events:FindFirstChild("ForceOpen")
	local doors = findBlastDoors()
	for _, door in ipairs(doors) do
		if forceOpen then
			pcall(function()
				forceOpen:FireServer(door, true)
			end)
		end
		if door:GetAttribute("Open") ~= true then
			pcall(function()
				door:SetAttribute("Open", true)
			end)
		end
	end
	if #doors > 0 then
		logOnce("metaldoor_ok", string.format("metal doors: destroying %d blast door(s)", #doors), "info")
	end
end

---------------------------------------------------------------------
-- Event notifier
---------------------------------------------------------------------

local eventFrame = Instance.new("Frame")
eventFrame.Name = "EventPanel"
eventFrame.AnchorPoint = Vector2.new(1, 0.5)
eventFrame.Position = UDim2.new(1, -16, 0.5, 0)
eventFrame.Size = UDim2.fromOffset(320, 80)
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
eventTitle.Size = UDim2.new(1, -16, 0, 22)
eventTitle.Position = UDim2.fromOffset(8, 6)
eventTitle.BackgroundTransparency = 1
eventTitle.Font = Enum.Font.GothamBold
eventTitle.TextSize = 15
eventTitle.TextXAlignment = Enum.TextXAlignment.Left
eventTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
eventTitle.Text = "ACTIVE ENTITIES"
eventTitle.Parent = eventFrame

local eventBody = Instance.new("TextLabel")
eventBody.Name = "Body"
eventBody.Size = UDim2.new(1, -16, 1, -40)
eventBody.Position = UDim2.fromOffset(8, 32)
eventBody.BackgroundTransparency = 1
eventBody.Font = Enum.Font.Gotham
eventBody.TextSize = 13
eventBody.TextXAlignment = Enum.TextXAlignment.Left
eventBody.TextYAlignment = Enum.TextYAlignment.Top
eventBody.TextWrapped = true
eventBody.TextColor3 = Color3.fromRGB(200, 200, 210)
eventBody.Text = ""
eventBody.Parent = eventFrame

local function activeEntities()
	local active = {}
	for _, model in ipairs(workspace:GetChildren()) do
		if model:IsA("Model") and entityInfo(model.Name) then
			table.insert(active, model.Name)
		end
	end
	local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
	if playerGui then
		for _, child in ipairs(playerGui:GetChildren()) do
			if entityInfo(child.Name) then
				table.insert(active, child.Name)
			end
		end
	end
	return active
end

local function modifierFolder()
	local modifiers = ReplicatedStorage:FindFirstChild("Modifiers")
	return modifiers and modifiers:FindFirstChild("Modifiers")
end

local function modifierLine(name)
	local folder = modifierFolder()
	local instance = folder and folder:FindFirstChild(name, true)
	if not instance then
		return name
	end
	local display = instance:GetAttribute("Name") or name
	local desc = instance:GetAttribute("Desc")
	if type(desc) == "string" and desc ~= "" then
		return display .. " — " .. desc
	end
	return display
end

-- Votes are applied as attributes on workspace.Game.Modifier.
local function activeModifiers()
	local applied = {}
	local gameFolder = workspace:FindFirstChild("Game")
	local modifier = gameFolder and gameFolder:FindFirstChild("Modifier")
	if not modifier then
		return applied
	end
	for name, value in pairs(modifier:GetAttributes()) do
		if value ~= nil and value ~= false and value ~= 0 then
			table.insert(applied, name)
		end
	end
	table.sort(applied)
	return applied
end

local lastEventKey = nil

local function eventStep()
	if not Settings.EventNotifier then
		eventFrame.Visible = false
		return
	end
	local lines = {}
	for _, name in ipairs(activeModifiers()) do
		table.insert(lines, "• " .. modifierLine(name))
	end
	for _, name in ipairs(activeEntities()) do
		local info = entityInfo(name)
		if info then
			table.insert(lines, "• " .. info.Title .. " — " .. info.Counter)
		end
	end
	if #lines == 0 then
		lines = { "No active modifiers or entities" }
	end
	eventFrame.Visible = true
	eventBody.Text = table.concat(lines, "\n")
	eventFrame.Size = UDim2.fromOffset(320, 40 + #lines * 18)
	local key = table.concat(lines, "\n")
	if key ~= lastEventKey then
		lastEventKey = key
		ctx:Log("[GRACE] entities: " .. #lines .. " active", "info")
	end
end

---------------------------------------------------------------------
-- REPRIEVE (CONFESSION mode)
---------------------------------------------------------------------

-- GraceCharacter.ClientShared carries the parry timestamp the cooldown is measured from.
local ClientShared = nil
task.spawn(function()
	local graceCharacter = ReplicatedStorage:WaitForChild("GraceCharacter", 10)
	local module = graceCharacter and graceCharacter:WaitForChild("ClientShared", 10)
	if module then
		local ok, result = pcall(require, module)
		if ok then
			ClientShared = result
		end
	end
end)

local function removeParryCooldown()
	if ClientShared then
		-- The parry gate is (now - LastParry) < recharge, so pinning it to zero removes it.
		ClientShared.LastParry = 0
	else
		logOnce("parry_noclient", "no parry cooldown: ClientShared module not found", "warn")
	end
end

local function matchesStart(text)
	return text:find("start") or text:find("next") or text:find("round") or text:find("wave") or text:find("begin")
		or text:find("pray") or text:find("confess")
end

local function findStartPrompt()
	for _, descendant in ipairs(workspace:GetDescendants()) do
		if descendant:IsA("ProximityPrompt") then
			local text = (descendant.Name .. " " .. (descendant.ActionText or "") .. " " .. (descendant.ObjectText or "")):lower()
			if matchesStart(text) then
				return descendant
			end
		end
	end
	return nil
end

local function findStartRemote()
	for _, descendant in ipairs(ReplicatedStorage:GetDescendants()) do
		if descendant:IsA("RemoteEvent") or descendant:IsA("RemoteFunction") then
			local name = descendant.Name:lower()
			if name:find("round") or name:find("wave") or name:find("confess") or name:find("reprieve") then
				return descendant
			end
		end
	end
	return nil
end

local startTrigger = nil
local startedRounds = 0
local nextStartAt = 0

local function resolveStartTrigger()
	if startTrigger and startTrigger.Parent then
		return startTrigger
	end
	startTrigger = findStartPrompt() or findStartRemote()
	return startTrigger
end

local function startNextRound()
	local now = os.clock()
	if now < nextStartAt then
		return
	end
	nextStartAt = now + 1.5
	if Settings.StopWave > 0 and startedRounds >= Settings.StopWave then
		return
	end
	local trigger = resolveStartTrigger()
	if not trigger then
		logOnce("start_notrigger", "auto start: no start prompt/remote found", "warn")
		return
	end
	logOnce("start_" .. trigger.ClassName, "auto start: using " .. trigger.ClassName .. " " .. trigger:GetFullName(), "info")
	if trigger:IsA("ProximityPrompt") then
		if type(fireproximityprompt) == "function" then
			pcall(fireproximityprompt, trigger)
			startedRounds += 1
		end
	elseif trigger:IsA("RemoteEvent") then
		pcall(function()
			trigger:FireServer()
		end)
		startedRounds += 1
	elseif trigger:IsA("RemoteFunction") then
		pcall(function()
			trigger:InvokeServer()
		end)
		startedRounds += 1
	end
end

-- Entities validate parries from ClientParryAttempt, checking the attachment's facing, so we
-- keep one attachment pinned to the camera and fire attempts from it.
local ClientParryAttempt = ReplicatedStorage:FindFirstChild("ClientParryAttempt")
local parryAttachment = nil
local nextParryAt = 0

local function ensureParryAttachment()
	if parryAttachment and parryAttachment.Parent then
		return parryAttachment
	end
	parryAttachment = Instance.new("Attachment")
	parryAttachment.Name = "Sk8rneParry"
	parryAttachment.Visible = false
	parryAttachment.Parent = workspace:FindFirstChild("Terrain") or workspace
	return parryAttachment
end

-- Parry is bound to the "useitem" key (left click by default), so drive it with real clicks.
local function leftClick()
	if type(mouse1press) == "function" and type(mouse1release) == "function" then
		local ok = pcall(function()
			mouse1press()
			mouse1release()
		end)
		if ok then
			return true
		end
	end
	if type(mouse1click) == "function" then
		local ok = pcall(mouse1click)
		if ok then
			return true
		end
	end
	-- gameProcessedEvent must be false: passing 0 (truthy) makes the game's InputBegan
	-- handler treat the click as already handled and skip the parry.
	-- VirtualInputManager may not be a valid service in every executor, so keep GetService
	-- inside the pcall: otherwise the whole loop errors and is silently swallowed.
	local ok = pcall(function()
		local userInputService = game:GetService("UserInputService")
		local virtualInput = game:GetService("VirtualInputManager")
		local location = userInputService:GetMouseLocation()
		virtualInput:SendMouseButtonEvent(location.X, location.Y, 0, true, false)
		virtualInput:SendMouseButtonEvent(location.X, location.Y, 0, false, false)
	end)
	return ok
end

local function autoParry()
	local now = os.clock()
	if now < nextParryAt then
		return
	end
	nextParryAt = now + 0.15
	local fired = false

	-- 1. A real left click reaches the game's useitem/parry binding.
	if leftClick() then
		fired = true
	end

	-- 2. The signal the game's own parry() function fires.
	if ClientShared and ClientShared.CrouchParryAttempt then
		local signal = ClientShared.CrouchParryAttempt
		if type(signal.Fire) == "function" then
			pcall(signal.Fire, signal)
			fired = true
		end
	end

	-- 3. The entity-facing attempt that Sundial/Seesay/Covet listen to.
	if not ClientParryAttempt then
		ClientParryAttempt = ReplicatedStorage:FindFirstChild("ClientParryAttempt")
	end
	local camera = workspace.CurrentCamera
	if ClientParryAttempt and camera then
		local attachment = ensureParryAttachment()
		attachment.CFrame = camera.CFrame
		pcall(function()
			ClientParryAttempt:Fire(attachment, tostring(math.random(1, 1000000)))
		end)
		fired = true
	end

	if fired then
		logOnce(
			"parry_ok",
			string.format(
				"auto parry: firing every 150ms (click=%s crouchSignal=%s remote=%s)",
				tostring(type(mouse1press) == "function" or type(mouse1click) == "function"),
				tostring(ClientShared ~= nil and ClientShared.CrouchParryAttempt ~= nil),
				tostring(ClientParryAttempt ~= nil)
			),
			"info"
		)
	else
		logOnce("parry_none", "auto parry: no usable method (no click, ClientShared, or ClientParryAttempt)", "warn")
	end
end

local function nearestEntityPart()
	local myRoot = getRootPart()
	if not myRoot then
		return nil
	end
	local best, bestDistance = nil, math.huge
	for _, model in ipairs(workspace:GetChildren()) do
		if model:IsA("Model") and entityInfo(model.Name) then
			local part = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
			if part then
				local distance = (part.Position - myRoot.Position).Magnitude
				if distance < bestDistance then
					best, bestDistance = part, distance
				end
			end
		end
	end
	return best, bestDistance
end

local nextCounterAt = 0

local function counterAttack()
	local target, distance = nearestEntityPart()
	if not target then
		logOnce("counter_none", "counter attack: no entity in the workspace", "warn")
		return
	end
	local now = os.clock()
	if now < nextCounterAt then
		return
	end
	nextCounterAt = now + 0.15
	leftClick()
	if ClientShared and ClientShared.CrouchParryAttempt then
		local signal = ClientShared.CrouchParryAttempt
		if type(signal.Fire) == "function" then
			pcall(signal.Fire, signal)
		end
	end
	if not ClientParryAttempt then
		ClientParryAttempt = ReplicatedStorage:FindFirstChild("ClientParryAttempt")
	end
	if ClientParryAttempt then
		local camera = workspace.CurrentCamera
		local myRoot = getRootPart()
		local origin = (camera and camera.CFrame.Position) or (myRoot and myRoot.Position)
		if origin then
			local attachment = ensureParryAttachment()
			attachment.CFrame = CFrame.lookAt(origin, target.Position)
			pcall(function()
				ClientParryAttempt:Fire(attachment, tostring(math.random(1, 1000000)))
			end)
		end
	end
	logOnce("counter_ok", string.format("counter attack: parrying the nearest entity (%d studs)", math.floor(distance)), "info")
end

-- Saferoom modifier vote: each option is a modifier whose Reward attribute is its XP multiplier.
-- The vote UI shows four of them and votes via Modifiers.VoteFor, so we pick the highest Reward.
task.spawn(function()
	local modifiers = ReplicatedStorage:WaitForChild("Modifiers", 10)
	if not modifiers then
		return
	end
	local startVote = modifiers:WaitForChild("StartVote", 10)
	local voteFor = modifiers:WaitForChild("VoteFor", 10)
	local defs = modifiers:WaitForChild("Modifiers", 10)
	if not (startVote and voteFor and defs) then
		return
	end
	ctx:Connect(startVote.OnClientEvent, function(...)
		if not Settings.BestModifier then
			return
		end
		local options = {}
		local bestIndex, bestReward = nil, -math.huge
		for index = 1, select("#", ...) do
			local id = select(index, ...)
			local instance = defs:FindFirstChild(id, true)
			local reward = instance and (instance:GetAttribute("Reward") or 0)
			table.insert(options, string.format("%d=%s(%.2f)", index, tostring(id), reward or 0))
			if reward and reward > bestReward then
				bestIndex, bestReward = index, reward
			end
		end
		if bestIndex then
			ctx:Log(
				string.format(
					"[GRACE] modifier vote: options %s -> picking %d (%.2f)",
					table.concat(options, ", "),
					bestIndex,
					bestReward
				),
				"info"
			)
			pcall(function()
				voteFor:FireServer(bestIndex)
			end)
		else
			logOnce("vote_none", "modifier vote: no option had a reward", "warn")
		end
	end)
end)

-- TriggerPrompt is the remote ClickPrompt fires for levers and sockets.
local TriggerPrompt = ReplicatedStorage:FindFirstChild("TriggerPrompt")
local nextLeverAt = 0

local function triggerLevers()
	if not TriggerPrompt then
		TriggerPrompt = ReplicatedStorage:FindFirstChild("TriggerPrompt")
	end
	if not TriggerPrompt then
		logOnce("levers_noremote", "levers: TriggerPrompt remote not found", "warn")
		return
	end
	local now = os.clock()
	if now < nextLeverAt then
		return
	end
	nextLeverAt = now + 0.2
	local count = 0
	for _, lever in ipairs(nearbyLevers(Settings.LeverRange)) do
		pcall(function()
			TriggerPrompt:FireServer(lever.Prompt)
		end)
		count += 1
	end
	if count > 0 then
		logOnce("levers_ok", string.format("levers: triggering %d nearby prompt(s)", count), "info")
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
	Text = "All Entities ESP",
	Description = "Highlights every entity with its name, distance and counter hint",
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

Visuals:AddSection("Levers & Plugs", "Lucide:plug")
Visuals:AddToggle({
	Text = "Trigger Levers/Plugs",
	Description = "Fires every nearby lever and plug prompt",
	Icon = "Lucide:zap",
	Default = false,
	Flag = "gr_trigger_levers",
	Callback = function(value)
		Settings.TriggerLevers = value
	end,
})
Visuals:AddToggle({
	Text = "Lever/Plug ESP",
	Description = "Highlights levers, sockets and plugs through walls",
	Icon = "Lucide:plug-2",
	Default = false,
	Flag = "gr_lever_esp",
	Callback = function(value)
		Settings.LeverEsp = value
	end,
})
Visuals:AddSlider({
	Text = "Lever Range",
	Description = "How far away levers and plugs are triggered",
	Icon = "Lucide:radar",
	Min = 10,
	Max = 500,
	Default = 120,
	Increment = 10,
	Suffix = " studs",
	Flag = "gr_lever_range",
	Callback = function(value)
		Settings.LeverRange = value
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
Visuals:AddToggle({
	Text = "Safe Zone Waypoint",
	Description = "Shows the saferoom and its entrance",
	Icon = "Lucide:home",
	Default = false,
	Flag = "gr_safe_zone_waypoint",
	Callback = function(value)
		Settings.SafeZoneWaypoint = value
		if not value then
			removeSafeZone()
		end
	end,
})
Visuals:AddToggle({
	Text = "Destroy Metal Doors",
	Description = "Force-opens every metal/blast door",
	Icon = "Lucide:door-open",
	Default = false,
	Flag = "gr_destroy_metal_doors",
	Callback = function(value)
		Settings.DestroyMetalDoors = value
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

Player:AddSection("Parry", "Lucide:shield")
Player:AddToggle({
	Text = "No Parry Cooldown",
	Description = "Removes the parry recharge so you can parry instantly",
	Icon = "Lucide:shield",
	Default = false,
	Flag = "gr_no_parry_cooldown",
	Callback = function(value)
		Settings.NoParryCooldown = value
	end,
})
Player:AddToggle({
	Text = "Auto Parry",
	Description = "Fires parry attempts from your camera automatically",
	Icon = "Lucide:shield-check",
	Default = false,
	Flag = "gr_auto_parry",
	Callback = function(value)
		Settings.AutoParry = value
		nextParryAt = 0
		ctx:Log("[GRACE] auto parry " .. (value and "enabled" or "disabled"), "info")
	end,
})
Player:AddToggle({
	Text = "Counter Attack",
	Description = "Aims at and parries the nearest entity automatically",
	Icon = "Lucide:swords",
	Default = false,
	Flag = "gr_counter_attack",
	Callback = function(value)
		Settings.CounterAttack = value
		nextCounterAt = 0
		ctx:Log("[GRACE] counter attack " .. (value and "enabled" or "disabled"), "info")
	end,
})

Events:AddSection("Rounds", "Lucide:repeat")
Events:AddToggle({
	Text = "Auto Start Next Round",
	Description = "Fires the round start trigger automatically",
	Icon = "Lucide:repeat",
	Default = false,
	Flag = "gr_auto_start_round",
	Callback = function(value)
		Settings.AutoStartRound = value
		startedRounds = 0
		if value then
			startTrigger = nil
		end
	end,
})
Events:AddTextbox({
	Text = "Stop At Wave",
	Description = "Auto-start stops after this many rounds (0 = never)",
	Icon = "Lucide:flag",
	Placeholder = "e.g. 10",
	Default = "0",
	Flag = "gr_stop_wave",
	Callback = function(value)
		Settings.StopWave = math.max(tonumber(value) or 0, 0)
	end,
})
Events:AddToggle({
	Text = "Pick Best Modifier",
	Description = "Votes for the vote option with the highest XP multiplier",
	Icon = "Lucide:trending-up",
	Default = false,
	Flag = "gr_best_modifier",
	Callback = function(value)
		Settings.BestModifier = value
	end,
})

---------------------------------------------------------------------
-- Background loops
---------------------------------------------------------------------

task.spawn(function()
	while ctx:Alive() do
		if Settings.TriggerLevers then
			pcall(triggerLevers)
		end
		task.wait(0.15)
	end
end)

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

task.spawn(function()
	while ctx:Alive() do
		if Settings.NoParryCooldown then
			pcall(removeParryCooldown)
		end
		task.wait(0.03)
	end
end)

task.spawn(function()
	while ctx:Alive() do
		if Settings.AutoStartRound then
			pcall(startNextRound)
		end
		task.wait(0.25)
	end
end)

task.spawn(function()
	while ctx:Alive() do
		if Settings.AutoParry then
			local ok, err = pcall(autoParry)
			if not ok then
				logOnce("parry_loop_error", "auto parry error: " .. tostring(err), "warn")
			end
		end
		task.wait(0.05)
	end
end)

task.spawn(function()
	while ctx:Alive() do
		if Settings.CounterAttack then
			local ok, err = pcall(counterAttack)
			if not ok then
				logOnce("counter_loop_error", "counter attack error: " .. tostring(err), "warn")
			end
		end
		task.wait(0.05)
	end
end)

task.spawn(function()
	while ctx:Alive() do
		if Settings.SafeZoneWaypoint then
			pcall(safeZoneStep)
		end
		task.wait(0.3)
	end
end)

task.spawn(function()
	while ctx:Alive() do
		if Settings.DestroyMetalDoors then
			pcall(destroyMetalDoors)
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
	Settings.EntityEsp, Settings.DoorWaypoint, Settings.EventNotifier = false, false, false
	Settings.NoParryCooldown, Settings.AutoStartRound = false, false
	Settings.AutoParry = false
	Settings.CounterAttack = false
	Settings.BestModifier = false
	Settings.TriggerLevers, Settings.LeverEsp = false, false
	Settings.SafeZoneWaypoint, Settings.DestroyMetalDoors = false, false
	removeSafeZone()
	if parryAttachment then
		parryAttachment:Destroy()
		parryAttachment = nil
	end
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
