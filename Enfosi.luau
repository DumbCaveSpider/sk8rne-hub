-- Enfosi
local ctx = ...
local task = ctx.task

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local RemoteEvents = ReplicatedStorage.Events.RemoteEvents
local MeleeSwing = RemoteEvents.MeleeSwing
local MeleeHit = RemoteEvents.MeleeHit
local GunFired = RemoteEvents.GunFired
local GunHit = RemoteEvents.GunHit

local ToolsStats do
	local ok, stats = pcall(require, ReplicatedStorage.ReplicatedModules.ToolsStats)
	ToolsStats = ok and stats or {}
end

local Settings = {
	SilentAim = false,
	SprugNeutral = true,
	AntiCatch = false,
	AutoCallOut = false,
	CallOutInterval = 3,
	Aimbot = false,
	Esp = false,
	AutoSwing = false,
	UseSwingCooldown = false,
	SwingCooldown = 0.5,
	Radius = 30,
	GunFov = 150,
	ShowFov = false,
}

local function getRoot(model)
	return model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
end

local function getAimPart(model)
	return model:FindFirstChild("Head") or getRoot(model)
end

local function isAlive(model)
	local hum = model:FindFirstChildOfClass("Humanoid")
	return hum and hum.Health > 0 and getRoot(model) ~= nil
end

-- Faction rosters: NPCHandler.Enphoso = enemies, NPCHandler.Glaggle (Gaggle) = friendlies.
-- Read live from the game, with the dumped names as a fallback.
local EnphosoFallback = {
	"Dumber", "True Sprug", "Somber", "Enumber", "Giggler", "Gazo", "Gizmo", "Lourgig",
	"Arcazo", "Gloober", "Guuber", "Gembo", "Murpleck", "Cheerer", "Spookler", "Gleeber", "Bamella",
	"Glaaber", "Grug", "Enphosian", "Enphogazo", "Enphizmo", "Enphourgig", "Enphocazo", "Enploober",
	"Enpuuber", "Abstract Enpuuber", "Enphembo", "Enpleck", "Enpheerer", "Feign Enpheerer", "Enpookler",
	"Enpleeber", "Enpamella", "Enpamella Shadow", "Enplaaber", "Enphogrug", "Rlooble", "Elooble",
	"Gerg Batter", "Gerg Gunner", "Gerg Annoyer", "Gerg Pumper", "Borg Baller", "Borg Smasher",
	"Borg Rocketeer", "Borg Dareblader", "Mimic", "Gergro", "Maniac Gergro", "Borgack",
	"Maniac Borgack", "Risio", "Maniac Risio", "Risio Shadow",
	"Gerg", "Maniac Gerg", "Borg", "Maniac Borg", -- model overrides of the Gerg/Borg variants
}

local GlaggleFallback = {
	"Statue", "Giggler", "Gazo", "Gizmo", "Lourgig", "Arcazo", "Gloober", "Guuber", "Gembo",
	"Murpleck", "Cheerer", "Spookler", "Gleeber", "Bamella", "Glaaber", "Grug", "Glooble",
	"Great Giggler",
}

local function loadRoster(moduleName, fallback)
	local names = {}
	local ok, data = pcall(function()
		return require(ReplicatedStorage.ReplicatedModules.NPCHandler[moduleName])
	end)
	if ok and type(data) == "table" then
		for npcName, config in data do
			names[npcName] = true
			if type(config) == "table" and config.Model then
				names[config.Model] = true
			end
		end
	else
		for _, npcName in fallback do
			names[npcName] = true
		end
	end
	return names
end

local EnemyNames = loadRoster("Enphoso", EnphosoFallback)
local FriendlyNames = loadRoster("Glaggle", GlaggleFallback)

-- Fakes carry a "Fake<Kind>" tag (e.g. FakeGiggler) next to the real kind's tag (Giggler).
local function isFake(npc)
	for _, tag in CollectionService:GetTags(npc) do
		if tag:sub(1, 4) == "Fake" then
			return true
		end
	end
	return false
end

-- NPCs that can be marked neutral (never attacked). Exact names only, so True Sprug stays an enemy.
local NeutralNames = {
	Sprug = "SprugNeutral",
}

-- Neutral NPCs are matched by exact model name in workspace.NPCs (e.g. workspace.NPCs.Sprug),
-- so "True Sprug" never matches
local function matchesNeutral(npc, name)
	return npc.Name == name
end

-- Returns "Friendly", "Enemy", "Neutral" or nil (unknown NPC):
-- fake-tagged -> Enemy; toggled neutral name -> Neutral; Gaggle roster name -> Friendly
-- (real Gaggle); Enphoso roster -> Enemy; anything else falls back to the team tag.
local function getFaction(npc)
	-- Neutral first so nothing else (tags included) can override it
	for name, setting in NeutralNames do
		if Settings[setting] and matchesNeutral(npc, name) then
			return "Neutral"
		end
	end
	if isFake(npc) then return "Enemy" end
	if FriendlyNames[npc.Name] then return "Friendly" end
	if EnemyNames[npc.Name] then return "Enemy" end
	if CollectionService:HasTag(npc, "Friendly") then return "Friendly" end
	if CollectionService:HasTag(npc, "Enemy") then return "Enemy" end
	return nil
end

local function isHostile(npc)
	return getFaction(npc) == "Enemy"
end

-- Living hostile NPCs within `radius` studs, closest first
local function getHostilesInRadius(fromPos, radius)
	local list = {}
	local folder = workspace:FindFirstChild("NPCs")
	if not folder then return list end
	for _, npc in folder:GetChildren() do
		if npc:IsA("Model") and isHostile(npc) and isAlive(npc) then
			local dist = (getRoot(npc).Position - fromPos).Magnitude
			if dist <= radius then
				table.insert(list, { npc = npc, dist = dist })
			end
		end
	end
	table.sort(list, function(a, b) return a.dist < b.dist end)
	for i, entry in list do
		list[i] = entry.npc
	end
	return list
end

local function getClosestHostile(fromPos)
	return getHostilesInRadius(fromPos, math.huge)[1]
end

local function getPlayerRoot()
	local character = LocalPlayer.Character
	return character and getRoot(character)
end

-- Mirrors ClientMelee.HitDetected: MeleeHit(character, tool, hitPart, direction).
-- Hits hostiles within `radius` (Silent Aim radius by default), at most `maxHits` of them.
local function onMeleeSwing(tool, radius, maxHits)
	local stats = ToolsStats[tool:GetAttribute("ToolIndex")]
	task.wait(stats and stats.HIT_DELAY or 0)

	local root = getPlayerRoot()
	if not root then return end
	for i, npc in getHostilesInRadius(root.Position, radius or Settings.Radius) do
		if maxHits and i > maxHits then break end
		local part = getAimPart(npc)
		MeleeHit:FireServer(npc, tool, part, (root.Position - part.Position).Unit)
	end
end

-- Gun Silent Aim: bend the game's own shots. ClientGun builds every shot from
-- Camera:ViewportPointToRay(mouse) -> raycast -> direction from the muzzle, then fires the real
-- projectile, GunFired and (on impact) GunHit itself. While a gun is equipped we answer that
-- ViewportPointToRay with a ray aimed at the hostile closest to the crosshair, so the game's
-- genuine projectile flies at that enemy. Only enemies within GunFov pixels of the crosshair and
-- within the gun's Range are picked; otherwise the shot goes where you aimed.
local function getGunStats(tool)
	local stats = tool and ToolsStats[tool:GetAttribute("ToolIndex")]
	if type(stats) == "table" and stats.ProjectileSpeed then
		return stats
	end
end

local function getEquippedGun()
	local character = LocalPlayer.Character
	local tool = character and character:FindFirstChildOfClass("Tool")
	local stats = getGunStats(tool)
	if stats then return tool, stats end
end

-- Hostile closest to the crosshair (screen distance), or nil
local function getCrosshairTarget(range)
	local root = getPlayerRoot()
	if not root then return nil end
	local camera = workspace.CurrentCamera
	local mouse = UserInputService:GetMouseLocation()
	local best, bestDist
	for _, npc in getHostilesInRadius(root.Position, range) do
		local part = getAimPart(npc)
		local point = camera:WorldToViewportPoint(part.Position)
		if point.Z > 0 then
			local dist = (Vector2.new(point.X, point.Y) - mouse).Magnitude
			if dist <= Settings.GunFov and (not bestDist or dist < bestDist) then
				best, bestDist = part, dist
			end
		end
	end
	return best
end

local function getSilentAimRay()
	local _, stats = getEquippedGun()
	if not stats then return nil end
	local part = getCrosshairTarget(stats.Range or 1000)
	if not part then return nil end
	local origin = workspace.CurrentCamera.CFrame.Position
	return Ray.new(origin, (part.Position - origin).Unit)
end

-- The game's weapon scripts call these once per swing / shot, so hooking them triggers Silent Aim
-- exactly when you attack.
local HookedMethods = { FireServer = true, ViewportPointToRay = true }

-- Handler results: nil = pass through, "return", value = return value without calling.
local function namecallHandler(self, method, ...)
	-- Anti Catch: ChaseScript reports its own catch with EnphosoGotYou:FireServer() whenever the
	-- chasing Enphoso is within 10 studs of you; swallowing that call means the catch never reaches
	-- the server.
	if Settings.AntiCatch and method == "FireServer" and self.Name == "EnphosoGotYou" then
		return "return", nil
	end

	if not Settings.SilentAim then return nil end
	if method == "ViewportPointToRay" then
		local ray = getSilentAimRay()
		if ray then return "return", ray end
	elseif method == "FireServer" and self == MeleeSwing then
		task.spawn(onMeleeSwing, (...))
	end
	return nil
end

ctx:HookMeta(game, "__namecall", function(oldNamecall, self, ...)
	local method = getnamecallmethod()
	if HookedMethods[method] and not checkcaller() then
		local action, value = namecallHandler(self, method, ...)
		if action == "return" then
			return value
		end
		-- The handler's own method calls overwrite the pending namecall method
		if setnamecallmethod then setnamecallmethod(method) end
	end
	return oldNamecall(self, ...)
end)

-- FOV circle around the crosshair showing the gun Silent Aim pick radius
local FovGui = Instance.new("ScreenGui")
FovGui.Name = "EnfosiFov"
FovGui.IgnoreGuiInset = true
FovGui.ResetOnSpawn = false

local FovCircle = Instance.new("Frame")
FovCircle.AnchorPoint = Vector2.new(0.5, 0.5)
FovCircle.BackgroundTransparency = 1
FovCircle.Visible = false
FovCircle.Parent = FovGui
Instance.new("UICorner", FovCircle).CornerRadius = UDim.new(1, 0)
local FovStroke = Instance.new("UIStroke")
FovStroke.Color = Color3.fromRGB(255, 255, 255)
FovStroke.Transparency = 0.3
FovStroke.Thickness = 1.5
FovStroke.Parent = FovCircle

RunService:BindToRenderStep("EnfosiFov", Enum.RenderPriority.Last.Value, function()
	local show = Settings.ShowFov and Settings.SilentAim and getEquippedGun() ~= nil
	FovCircle.Visible = show
	if show then
		local mouse = UserInputService:GetMouseLocation()
		FovCircle.Position = UDim2.fromOffset(mouse.X, mouse.Y)
		FovCircle.Size = UDim2.fromOffset(Settings.GunFov * 2, Settings.GunFov * 2)
	end
end)

-- Runs right after the default camera script so the lock isn't overwritten each frame
RunService:BindToRenderStep("EnfosiAimbot", Enum.RenderPriority.Camera.Value + 1, function()
	if not Settings.Aimbot then return end
	local root = getPlayerRoot()
	if not root then return end

	local target = getClosestHostile(root.Position)
	if not target then return end

	local aimPart = getAimPart(target)
	local camera = workspace.CurrentCamera
	camera.CFrame = CFrame.lookAt(camera.CFrame.Position, aimPart.Position)

	-- Weapons that aim with Mouse.Hit follow the cursor, so pull it onto the target too
	if mousemoverel then
		local screenPos, onScreen = camera:WorldToViewportPoint(aimPart.Position)
		if onScreen then
			local mousePos = UserInputService:GetMouseLocation()
			mousemoverel(screenPos.X - mousePos.X, screenPos.Y - mousePos.Y)
		end
	end
end)

-- ESP: a name label above each NPC (colored by faction), plus a red Highlight on every enemy
-- (fakes included). Friendlies only get the label.
local EspColors = {
	Friendly = Color3.fromRGB(255, 220, 0),
	Enemy = Color3.fromRGB(255, 0, 0),
	Neutral = Color3.fromRGB(255, 255, 255),
	Unknown = Color3.fromRGB(180, 180, 180), -- NPC on neither roster and untagged
}

local EspFolder = Instance.new("Folder")
EspFolder.Name = "EnfosiESP"
EspFolder.Parent = (gethui and gethui()) or game:GetService("CoreGui")
ctx:Track(EspFolder)
ctx:OnCleanup(function()
	pcall(function() RunService:UnbindFromRenderStep("EnfosiFov") end)
	pcall(function() RunService:UnbindFromRenderStep("EnfosiAimbot") end)
end)
FovGui.Parent = EspFolder

local EspLabels = {}
local EspHighlights = {}

local function getTeamColor(npc)
	return EspColors[getFaction(npc) or "Unknown"]
end

local function clearEsp()
	for npc, billboard in EspLabels do
		billboard:Destroy()
		EspLabels[npc] = nil
	end
	for npc, highlight in EspHighlights do
		highlight:Destroy()
		EspHighlights[npc] = nil
	end
end

-- Enemies are highlighted red and neutrals white; friendlies get no highlight
local function updateHighlight(npc)
	local highlight = EspHighlights[npc]
	local faction = getFaction(npc)
	if faction == "Enemy" or faction == "Neutral" then
		if not highlight then
			highlight = Instance.new("Highlight")
			highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			highlight.FillTransparency = 0.6
			highlight.OutlineTransparency = 0
			highlight.Adornee = npc
			highlight.Parent = EspFolder
			EspHighlights[npc] = highlight
		end
		highlight.FillColor = EspColors[faction]
		highlight.OutlineColor = EspColors[faction]
	elseif highlight then
		-- e.g. a fake tag hadn't arrived yet, or it turned out friendly
		highlight:Destroy()
		EspHighlights[npc] = nil
	end
end

local function createLabel(npc)
	local billboard = Instance.new("BillboardGui")
	billboard.Adornee = getAimPart(npc)
	billboard.AlwaysOnTop = true
	billboard.Size = UDim2.fromOffset(200, 34)
	billboard.StudsOffset = Vector3.new(0, 3, 0)
	billboard.Parent = EspFolder

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 0, 18)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 14
	label.TextStrokeTransparency = 0.3
	label.Text = npc.Name
	label.Parent = billboard

	-- Health line under the name, e.g. "640 / 800"; colored green -> red as health drops
	local health = Instance.new("TextLabel")
	health.Name = "Health"
	health.BackgroundTransparency = 1
	health.Position = UDim2.fromOffset(0, 18)
	health.Size = UDim2.new(1, 0, 0, 14)
	health.Font = Enum.Font.GothamMedium
	health.TextSize = 12
	health.TextStrokeTransparency = 0.3
	health.Parent = billboard

	return billboard
end

task.spawn(function()
	while EspFolder.Parent do
		if Settings.Esp then
			local folder = workspace:FindFirstChild("NPCs")
			local seen = {}
			for _, npc in folder and folder:GetChildren() or {} do
				if npc:IsA("Model") and isAlive(npc) then
					seen[npc] = true
					local billboard = EspLabels[npc]
					if not billboard then
						billboard = createLabel(npc)
						EspLabels[npc] = billboard
					end
					billboard.TextLabel.TextColor3 = getTeamColor(npc)

					local hum = npc:FindFirstChildOfClass("Humanoid")
					local maxHealth = math.max(hum.MaxHealth, 1)
					local ratio = math.clamp(hum.Health / maxHealth, 0, 1)
					billboard.Health.Text = ("%d / %d"):format(math.ceil(hum.Health), math.ceil(hum.MaxHealth))
					billboard.Health.TextColor3 = Color3.fromRGB(255, 60, 60):Lerp(Color3.fromRGB(80, 255, 80), ratio)
					updateHighlight(npc)
				end
			end
			-- Drop labels and highlights for NPCs that died or despawned
			for npc, billboard in EspLabels do
				if not seen[npc] then
					billboard:Destroy()
					EspLabels[npc] = nil
				end
			end
			for npc, highlight in EspHighlights do
				if not seen[npc] then
					highlight:Destroy()
					EspHighlights[npc] = nil
				end
			end
		end
		task.wait(0.25)
	end
end)

-- Auto Call Out, mirroring UpdateUI.Callout: pressing Q raycasts from the mouse (ignoring the map,
-- up to 2000 studs) and sends CallOut:FireServer(hitPart) with the *body part* that was hit. Every
-- callout starts a shared VoiceCommands.CalloutCooldown, so we wait that long between callouts.
-- The server announces accepted callouts to everyone via CallOutReceive(callerCharacter, message,
-- npc, sound, color); an NPC only counts as done once that confirms it (anyone's callout counts),
-- otherwise it's retried on a later pass. Enemies are tried closest first, one per cooldown.
local CallOut = RemoteEvents:WaitForChild("CallOut", 5)
local CallOutReceive = RemoteEvents:WaitForChild("CallOutReceive", 5)
local CalledOut = setmetatable({}, { __mode = "k" }) -- confirmed by the server
local CallOutTries = setmetatable({}, { __mode = "k" }) -- { count, lastTry } for unconfirmed NPCs
local CALL_OUT_BACKOFF = 15 -- after 2 failed tries, skip that NPC this long so it can't block others

local CalloutCooldown = 3
pcall(function()
	local cooldown = require(ReplicatedStorage.ReplicatedModules.VoiceCommands).CalloutCooldown
	if type(cooldown) == "number" then
		CalloutCooldown = cooldown
	end
end)
-- Default interval: the game's cooldown plus a small margin, clamped to the slider's 0.1-5s range.
-- Lower values call out faster but the server may ignore callouts made during its cooldown.
Settings.CallOutInterval = math.clamp(math.floor((CalloutCooldown + 0.25) * 10 + 0.5) / 10, 0.1, 5)

local function npcFromInstance(instance)
	if typeof(instance) ~= "Instance" then return nil end
	if instance:IsA("Model") then return instance end
	return instance:FindFirstAncestorOfClass("Model")
end

if CallOutReceive then
	ctx:Connect(CallOutReceive.OnClientEvent, function(_, _, target)
		local npc = EspFolder.Parent and npcFromInstance(target)
		if npc then
			CalledOut[npc] = true
		end
	end)
end

local function nextCallOutTarget()
	local root = getPlayerRoot()
	if not root then return nil end
	for _, npc in getHostilesInRadius(root.Position, 2000) do
		local tries = CallOutTries[npc]
		local backedOff = tries and tries.count >= 2 and os.clock() - tries.lastTry < CALL_OUT_BACKOFF
		if not CalledOut[npc] and not backedOff then
			return npc
		end
	end
end

task.spawn(function()
	while EspFolder.Parent do
		local npc = Settings.AutoCallOut and CallOut and nextCallOutTarget()
		if npc then
			-- Same thing the Q raycast would hit: a body part of the NPC
			local part = npc:FindFirstChild("Torso") or npc:FindFirstChild("UpperTorso") or getAimPart(npc)
			CallOut:FireServer(part)
			task.wait(Settings.CallOutInterval)
			if not CalledOut[npc] then
				local tries = CallOutTries[npc] or { count = 0 }
				tries.count = tries.count >= 2 and 1 or tries.count + 1 -- back off, then start over
				tries.lastTry = os.clock()
				CallOutTries[npc] = tries
			end
		else
			task.wait(0.5)
		end
	end
end)

-- Melee tools are the ToolsStats entries with a USAGE_DELAY (ClientMelee's swing cooldown).
-- An infinite delay means the tool can't be swung (ClientMelee skips binding Attack for it).
local function getMeleeTool()
	local character = LocalPlayer.Character
	local tool = character and character:FindFirstChildOfClass("Tool")
	if not tool then return nil end
	local stats = ToolsStats[tool:GetAttribute("ToolIndex")]
	if type(stats) == "table" and stats.USAGE_DELAY and stats.USAGE_DELAY ~= math.huge then
		return tool
	end
end

-- Swing Cooldown: ClientMelee re-reads USAGE_DELAY from the shared ToolsStats table before every
-- swing, so overwriting it sets the delay between swings. HIT_DELAY_REDUCTION is zeroed so a
-- landed hit doesn't shorten it further. Each weapon's own values are snapshotted first and
-- restored when the custom cooldown is turned off (and at shutdown).
local OriginalDelays = {}

for _, stats in ToolsStats do
	if type(stats) == "table" and stats.USAGE_DELAY ~= nil and stats.USAGE_DELAY ~= math.huge
		and not OriginalDelays[stats] then
		OriginalDelays[stats] = {
			USAGE_DELAY = stats.USAGE_DELAY,
			HIT_DELAY_REDUCTION = stats.HIT_DELAY_REDUCTION,
		}
	end
end

local function applySwingCooldown()
	for stats, original in OriginalDelays do
		if setreadonly then pcall(setreadonly, stats, false) end
		pcall(function()
			if Settings.UseSwingCooldown then
				stats.USAGE_DELAY = Settings.SwingCooldown
				stats.HIT_DELAY_REDUCTION = 0
			else
				stats.USAGE_DELAY = original.USAGE_DELAY
				stats.HIT_DELAY_REDUCTION = original.HIT_DELAY_REDUCTION
			end
		end)
	end
end

-- Auto Swing: performs the swing itself instead of simulating mouse 1 (ClientMelee drops
-- clicks that land on UI, so a simulated hold right after clicking the toggle never swung).
-- Sends the same remotes as ClientMelee.Swing: MeleeSwing, then MeleeHit after HIT_DELAY.
local MELEE_REACH = 10 -- studs; used when Silent Aim is off
local AttackTracks = setmetatable({}, { __mode = "k" })

local function playSwingAnimation(tool, humanoid)
	local animator = humanoid:FindFirstChildOfClass("Animator")
	local animations = tool:FindFirstChild("Animations")
	local attack = animations and animations:FindFirstChild("Attack")
	if not (animator and attack) then return end

	local track = AttackTracks[tool]
	if not track or track.Parent == nil then
		track = animator:LoadAnimation(attack)
		AttackTracks[tool] = track
	end
	track:Play(0)
end

local function autoSwing(tool, character)
	local stats = ToolsStats[tool:GetAttribute("ToolIndex")]
	MeleeSwing:FireServer(tool) -- our own call, so the Silent Aim hook doesn't double it
	playSwingAnimation(tool, character.Humanoid)

	if Settings.SilentAim then
		task.spawn(onMeleeSwing, tool, Settings.Radius)
	else
		task.spawn(onMeleeSwing, tool, MELEE_REACH, stats.MULTI_HIT)
	end
end

ctx:OnCleanup(function()
	Settings.UseSwingCooldown = false
	applySwingCooldown()
end)

task.spawn(function()
	while EspFolder.Parent do
		local character = LocalPlayer.Character
		local tool = Settings.AutoSwing and character and isAlive(character) and getMeleeTool()
		if tool then
			autoSwing(tool, character)
			-- Same cooldown ClientMelee uses (Gazo class swings 1.5x slower); No Cooldown zeroes it
			local stats = ToolsStats[tool:GetAttribute("ToolIndex")]
			local classMultiplier = character:GetAttribute("Class") == "Gazo" and 1.5 or 1
			task.wait(math.max(stats.USAGE_DELAY * classMultiplier, 1 / 30))
		else
			task.wait(0.1)
		end
	end
end)

local Main = ctx:SubTab("Main", "Lucide:house")
local Visuals = ctx:SubTab("Visuals", "Lucide:eye")
local Info = ctx:SubTab("Info", "Lucide:info")
local Misc = ctx:SubTab("Misc", "Lucide:ellipsis")

Main:AddSection("Aim", "Lucide:crosshair")

Main:AddToggle({
	Text = "Silent Aim",
	Flag = "SilentAim",
	Description = "Melee hits every hostile in the radius and gun shots curve to the enemy nearest your crosshair",
	Default = false,
	Callback = function(state)
		Settings.SilentAim = state
	end,
})

Main:AddSlider({
	Text = "Silent Aim Radius",
	Flag = "SilentAimRadius",
	Min = 5,
	Max = 300,
	Increment = 1,
	Default = Settings.Radius,
	Suffix = " studs",
	Callback = function(value)
		Settings.Radius = value
	end,
})

Main:AddSlider({
	Text = "Gun Aim FOV",
	Flag = "GunFov",
	Min = 25,
	Max = 600,
	Increment = 5,
	Default = Settings.GunFov,
	Suffix = " px",
	Callback = function(value)
		Settings.GunFov = value
	end,
})

Main:AddToggle({
	Text = "Sprug Neutral",
	Flag = "SprugNeutral",
	Description = "Never attacks Sprug and shows it white in ESP, True Sprug is still an enemy",
	Default = Settings.SprugNeutral,
	Callback = function(state)
		Settings.SprugNeutral = state
	end,
})

Main:AddToggle({
	Text = "Hostile Aimbot",
	Flag = "HostileAimbot",
	Description = "Locks your aim onto the closest hostile NPC",
	Default = false,
	Callback = function(state)
		Settings.Aimbot = state
	end,
})

Main:AddSection("Melee", "Lucide:swords")

Main:AddToggle({
	Text = "Auto Swing",
	Flag = "AutoSwing",
	Description = "Keeps swinging your equipped melee weapon",
	Default = false,
	Callback = function(state)
		Settings.AutoSwing = state
	end,
})

Main:AddToggle({
	Text = "Use Swing Cooldown",
	Flag = "UseSwingCooldown",
	Description = "Melee weapons use the cooldown below instead of their normal one",
	Default = false,
	Callback = function(state)
		Settings.UseSwingCooldown = state
		applySwingCooldown()
	end,
})

Main:AddSlider({
	Text = "Swing Cooldown",
	Flag = "SwingCooldown",
	Min = 0.1,
	Max = 0.5,
	Increment = 0.05,
	Default = Settings.SwingCooldown,
	Suffix = "s",
	Callback = function(value)
		Settings.SwingCooldown = value
		applySwingCooldown()
	end,
})

Visuals:AddToggle({
	Text = "NPC ESP",
	Flag = "NpcEsp",
	Description = "Names every NPC through walls (friendly yellow, hostile red) and highlights enemies",
	Default = false,
	Callback = function(state)
		Settings.Esp = state
		if not state then
			clearEsp()
		end
	end,
})

Visuals:AddToggle({
	Text = "Show FOV Circle",
	Flag = "ShowFov",
	Description = "Draws the Gun Aim FOV around your crosshair while a gun is equipped",
	Default = false,
	Callback = function(state)
		Settings.ShowFov = state
	end,
})

-- Wave counts: living NPCs in workspace.NPCs, split by the same faction check the panel uses.
-- The Statue (tagged "Core") is the objective, not a wave NPC, so it isn't counted.
local WaveGrid = Info:AddInfoGrid({
	Title = "Wave",
	Description = "Living NPCs currently in the wave",
	Columns = 3,
	Items = {
		{ Label = "Gaggle", Value = "0" },
		{ Label = "FakeGaggle", Value = "0" },
		{ Label = "Enphoso", Value = "0" },
	},
})

task.spawn(function()
	while EspFolder.Parent do
		local gaggle, fake, enphoso = 0, 0, 0
		local folder = workspace:FindFirstChild("NPCs")
		for _, npc in folder and folder:GetChildren() or {} do
			if npc:IsA("Model") and isAlive(npc) and not CollectionService:HasTag(npc, "Core") then
				if isFake(npc) then
					fake = fake + 1
				else
					local faction = getFaction(npc)
					if faction == "Friendly" then
						gaggle = gaggle + 1
					elseif faction == "Enemy" then
						enphoso = enphoso + 1
					end
				end
			end
		end
		WaveGrid:SetValue("Gaggle", gaggle)
		WaveGrid:SetValue("FakeGaggle", fake)
		WaveGrid:SetValue("Enphoso", enphoso)
		task.wait(0.5)
	end
end)

Misc:AddToggle({
	Text = "Auto Call Out",
	Flag = "AutoCallOut",
	Description = "Calls out every enemy once, fakes included and never real Gaggle",
	Default = false,
	Callback = function(state)
		Settings.AutoCallOut = state
	end,
})

Misc:AddSlider({
	Text = "Call Out Interval",
	Flag = "CallOutInterval",
	Min = 0.1,
	Max = 5,
	Increment = 0.1,
	Default = Settings.CallOutInterval,
	Suffix = "s",
	Callback = function(value)
		Settings.CallOutInterval = value
	end,
})

Misc:AddToggle({
	Text = "Anti Catch",
	Flag = "AntiCatch",
	Description = "Stops the chasing Enphoso from catching you",
	Default = false,
	Callback = function(state)
		Settings.AntiCatch = state
	end,
})
