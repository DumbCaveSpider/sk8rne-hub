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
	EspBoss = false,
	EspDistance = 500,
	AutoRoll = false,
	CoinFarm = false,
	AutoRevive = false,
	AutoSwing = false,
	AutoCarry = false,
	AutoClaimDiary = false,
	AutoUseItem = false,
	UseItemId = nil,
	HazardWarn = false,
	AutoDodge = false,
	UnlimitedStamina = false,
	UnlimitedOxygen = false,
	AutoWrite = false,
	WriteWord = "money",
	AutoWriteWorst = false,
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
	{
		Setting = "EspBoss",
		Label = "BOSS",
		Color = Color3.fromRGB(255, 80, 255),
		Tags = { "BossHealthBar" },
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

local function folderPath(...)
	local current = ReplicatedStorage
	for _, name in ipairs({ ... }) do
		current = current:FindFirstChild(name)
		if not current then
			return nil
		end
	end
	return current
end

-- This game scatters its remotes across several top-level folders.
local REMOTE_FOLDERS = {
	{ "Remotes", "Client", "Game" },
	{ "Remotes" },
	{ "SprintRemotes" },
	{ "Items", "Remotes" },
	{ "MetaWords", "Remotes" },
	{ "WriterRemotes" },
	{ "CarryRemotes" },
	{ "WeaponSystem", "MeleeRemotes" },
}

local function findRemote(name)
	for _, path in ipairs(REMOTE_FOLDERS) do
		local folder = folderPath(table.unpack(path))
		local remote = folder and folder:FindFirstChild(name)
		if remote and (remote:IsA("RemoteEvent") or remote:IsA("UnreliableRemoteEvent") or remote:IsA("RemoteFunction")) then
			return remote
		end
	end
	return nil
end

local function fireRemote(name, ...)
	local remote = findRemote(name)
	if not (remote and (remote:IsA("RemoteEvent") or remote:IsA("UnreliableRemoteEvent"))) then
		logOnce("remote_missing_" .. name, "remote not found: " .. name, "warn")
		return false
	end
	local args = table.pack(...)
	pcall(function()
		remote:FireServer(table.unpack(args, 1, args.n))
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
	local args = table.pack(...)
	local ok, result = pcall(function()
		return request:InvokeServer(table.unpack(args, 1, args.n))
	end)
	if not ok then
		logOnce("item_request_failed", "item request failed: " .. tostring(result), "warn")
	end
	return ok and result or nil
end

-- Item catalogue for the "Auto Use Item" dropdown.
local ItemLibrary = nil
do
	local items = ReplicatedStorage:WaitForChild("Items", 10)
	local module = items and items:WaitForChild("ItemLibrary", 10)
	if module then
		local ok, result = pcall(require, module)
		if ok then
			ItemLibrary = result
		end
	end
end

local itemNames = { "None" }
local itemNameToId = {}
if ItemLibrary and ItemLibrary.Items then
	for _, item in ipairs(ItemLibrary.Items) do
		if item.name and item.id then
			table.insert(itemNames, item.name)
			itemNameToId[item.name] = item.id
		end
	end
end

local function nearestTagPart(tag)
	local myRoot = getRootPart()
	if not myRoot then
		return nil
	end
	local best, bestDistance = nil, math.huge
	for _, instance in ipairs(CollectionService:GetTagged(tag)) do
		local part = espPart(instance)
		if part then
			local distance = (part.Position - myRoot.Position).Magnitude
			if distance < bestDistance then
				best, bestDistance = part, distance
			end
		end
	end
	return best, bestDistance
end

local function coinFarmStep()
	local humanoid = getHumanoid()
	local coin = nearestTagPart("Coin")
	if humanoid and coin then
		humanoid:MoveTo(coin.Position)
		logOnce("coin_ok", "coin farm: walking to the nearest coin", "info")
	end
end

local function autoReviveStep()
	local humanoid = getHumanoid()
	if humanoid and humanoid.Health > 0 and LocalPlayer.Character then
		return
	end
	local shopRemotes = ReplicatedStorage:FindFirstChild("ShopRemotes")
	local grant = shopRemotes and shopRemotes:FindFirstChild("TestGrant")
	if not (grant and grant:IsA("RemoteEvent")) then
		logOnce("revive_missing", "auto revive: ShopRemotes.TestGrant not found", "warn")
		return
	end
	pcall(function()
		grant:FireServer("revive")
	end)
	logOnce("revive_ok", "auto revive: sent the revive grant", "info")
end

local swingSeq = 0
local nextSwingAt = 0
local function autoSwingStep()
	local now = os.clock()
	if now < nextSwingAt then
		return
	end
	nextSwingAt = now + 0.45
	local weaponSystem = ReplicatedStorage:FindFirstChild("WeaponSystem")
	local meleeRemotes = weaponSystem and weaponSystem:FindFirstChild("MeleeRemotes")
	local swing = meleeRemotes and meleeRemotes:FindFirstChild("Swing")
	if not (swing and swing:IsA("RemoteEvent")) then
		logOnce("swing_missing", "auto swing: WeaponSystem.MeleeRemotes.Swing not found", "warn")
		return
	end
	swingSeq = swingSeq + 1
	pcall(function()
		swing:FireServer(swingSeq, 1)
	end)
	logOnce("swing_ok", "auto swing: sending melee swings", "info")
end

local nextCarryAt = 0
local function autoCarryStep()
	local now = os.clock()
	if now < nextCarryAt then
		return
	end
	nextCarryAt = now + 1
	local part = nearestTagPart("Carryable")
	if not part then
		return
	end
	local carryRemotes = ReplicatedStorage:FindFirstChild("CarryRemotes")
	local request = carryRemotes and carryRemotes:FindFirstChild("Request")
	if not (request and request:IsA("RemoteEvent")) then
		logOnce("carry_missing", "auto carry: CarryRemotes.Request not found", "warn")
		return
	end
	pcall(function()
		request:FireServer("pick", part)
	end)
	logOnce("carry_ok", "auto carry: picking up a carryable", "info")
end

local claimedDiary = {}
local nextDiaryAt = 0
local function autoClaimDiaryStep()
	local now = os.clock()
	if now < nextDiaryAt then
		return
	end
	nextDiaryAt = now + 5
	local diary = ReplicatedStorage:FindFirstChild("Diary")
	local remotes = diary and diary:FindFirstChild("Remotes")
	local request = remotes and remotes:FindFirstChild("Request")
	local catalog = diary and diary:FindFirstChild("DiaryCatalog")
	if not (request and request:IsA("RemoteFunction") and catalog) then
		logOnce("diary_missing", "diary auto-claim: Diary remotes/catalog not found", "warn")
		return
	end
	local ok, module = pcall(require, catalog)
	if not (ok and type(module) == "table") then
		return
	end
	local categories = module.Categories or module
	for id in pairs(categories) do
		local categoryId = type(id) == "string" and id or nil
		if categoryId and not claimedDiary[categoryId] then
			local invoked, result = pcall(function()
				return request:InvokeServer("claim", categoryId)
			end)
			if invoked and result then
				claimedDiary[categoryId] = true
			end
		end
	end
	logOnce("diary_ok", "diary auto-claim: tried every category", "info")
end

local nextUseAt = 0
local function autoUseItemStep()
	if not Settings.UseItemId then
		return
	end
	local now = os.clock()
	if now < nextUseAt then
		return
	end
	nextUseAt = now + 2
	itemRequestInvoke("use", Settings.UseItemId, nil)
	logOnce("useitem_ok", "auto use item: using " .. tostring(Settings.UseItemId), "info")
end

local HAZARD_TAGS = { "LavaFlood", "TsunamiWave", "TornadoFx", "Geyser", "StormCloud", "StructureFlame", "GrassFlame", "LeafPile" }
local warnedHazards = {}

local function hazardStep()
	local myRoot = getRootPart()
	local humanoid = getHumanoid()
	if not myRoot then
		return
	end
	for _, tag in ipairs(HAZARD_TAGS) do
		for _, instance in ipairs(CollectionService:GetTagged(tag)) do
			local part = espPart(instance)
			if part then
				local distance = (part.Position - myRoot.Position).Magnitude
				if distance <= 120 and not warnedHazards[tag] then
					warnedHazards[tag] = true
					ctx:Log(string.format("[SYI] HAZARD: %s is %.0f studs away", tag, distance), "warn")
				end
				if Settings.AutoDodge and humanoid and distance <= 60 then
					local away = myRoot.Position - part.Position
					if away.Magnitude > 0.1 then
						humanoid:MoveTo(myRoot.Position + away.Unit * 40)
						logOnce("dodge_ok", "auto dodge: moving away from " .. tag, "info")
					end
				end
			end
		end
	end
end

---------------------------------------------------------------------
-- Stamina + writer
---------------------------------------------------------------------

local lastStaminaLog = 0
local function unlimitedStaminaStep()
	local now = os.clock()
	local sprintRemotes = ReplicatedStorage:FindFirstChild("SprintRemotes")
	local setSprint = sprintRemotes and sprintRemotes:FindFirstChild("SetSprint")
	local before = LocalPlayer:GetAttribute("Stamina")
	pcall(function()
		LocalPlayer:SetAttribute("Stamina", 100)
		LocalPlayer:SetAttribute("StaminaDrainMultiplier", 0)
	end)
	local after = LocalPlayer:GetAttribute("Stamina")
	local character = getCharacter()
	local sprinting = character and character:GetAttribute("Sprinting")
	local fired = false
	if setSprint and setSprint:IsA("RemoteEvent") then
		pcall(function()
			setSprint:FireServer(true)
		end)
		fired = true
	end
	if now - lastStaminaLog >= 1 then
		lastStaminaLog = now
		ctx:Log(
			string.format(
				"[SYI] stamina debug: before=%s after=%s sprinting=%s drainMul=%s fired=%s",
				tostring(before),
				tostring(after),
				tostring(sprinting),
				tostring(LocalPlayer:GetAttribute("StaminaDrainMultiplier")),
				tostring(fired)
			),
			"info"
		)
	end
	logOnce("stamina_ok", "unlimited stamina: keeping stamina full", "info")
end

local lastBreathLog = 0
local function unlimitedOxygenStep()
	local now = os.clock()
	local breath = LocalPlayer:GetAttribute("Breath")
	local isNumber = typeof(breath) == "number"
	pcall(function()
		LocalPlayer:SetAttribute("Breath", 100)
	end)
	if now - lastBreathLog >= 2 then
		lastBreathLog = now
		ctx:Log(string.format("[SYI] oxygen debug: breath=%s", isNumber and tostring(math.floor(breath)) or "nil"), "info")
	end
	logOnce("oxygen_ok", "unlimited oxygen: keeping breath full", "info")
end

local WRITE_CANDIDATES = {
	{ { "WriterRemotes" }, "SubmitWord" },
	{ { "MetaWords", "Remotes" }, "TryMeta" },
	{ { "MetaWords", "Remotes" }, "Submit" },
	{ { "WriterRemotes" }, "Submit" },
	{ { "WriterRemotes" }, "Write" },
}

local function findWriteRemote()
	for _, candidate in ipairs(WRITE_CANDIDATES) do
		local folder = folderPath(table.unpack(candidate[1]))
		local remote = folder and folder:FindFirstChild(candidate[2])
		if remote and (remote:IsA("RemoteEvent") or remote:IsA("UnreliableRemoteEvent")) then
			return remote
		end
	end
	return nil
end

task.spawn(function()
	local metaWords = ReplicatedStorage:WaitForChild("MetaWords", 15)
	local metaRemotes = metaWords and metaWords:WaitForChild("Remotes", 15)
	local writerRemotes = ReplicatedStorage:WaitForChild("WriterRemotes", 15)
	local sprintRemotes = ReplicatedStorage:WaitForChild("SprintRemotes", 15)
	local itemsRemotes = folderPath("Items", "Remotes")
	local function names(folder)
		local list = {}
		if folder then
			for _, child in ipairs(folder:GetChildren()) do
				table.insert(list, child.Name)
			end
		end
		return table.concat(list, ", ")
	end
	ctx:Log("[SYI] MetaWords.Remotes: " .. names(metaRemotes), "info")
	ctx:Log("[SYI] WriterRemotes: " .. names(writerRemotes), "info")
	ctx:Log("[SYI] SprintRemotes: " .. names(sprintRemotes), "info")
	ctx:Log("[SYI] Items.Remotes: " .. names(itemsRemotes), "info")
end)

-- Every word in the game's DiaryCatalog (416 entries).
local ALL_DISASTERS = {
	"delete", "shrink", "tsunami", "fire", "zombie", "lava", "meteor", "tornado", "lightning", "storm",
	"earthquake", "bomb", "ice", "volcano", "shark", "ghost", "bees", "dinosaur", "monster", "kill",
	"clown", "rain", "wind", "giant", "gravity", "speed", "jump", "night", "fog", "acid",
	"laser", "black_hole", "heat", "snow", "alien", "dragon", "spider", "snake", "invisible", "fly",
	"teleport", "swap", "building", "city", "tree", "wall", "oof", "sky_letter", "tacos", "dance",
	"money", "cat", "dog", "chair", "robot", "banana", "jail", "magnet", "food", "hunger",
	"ban", "train", "boulder", "fart", "pirate", "bubble", "darkclone", "wizard", "fireworks", "king",
	"cow", "octopus", "jackbox", "circus", "frog", "worm", "slime", "medkit", "size", "shield",
	"gift", "conveyor", "launchpad", "zone", "pendulum", "dominoes", "sneeze", "sleep", "revive", "safehouse",
	"star", "peace", "helicopter", "house", "bed", "picnic", "ladder", "tower", "flowers", "mansion",
	"computer", "flood", "dry", "enxurrada", "epidemia", "gun", "melee", "ball", "box", "chicken",
	"mountain", "day", "hail", "umbrella", "chest", "car", "igloo", "sandstorm", "fountain", "anvil",
	"duck", "halloween", "pumpkin", "water", "hi", "love", "pig", "monkey", "bear", "lion",
	"wolf", "skeleton", "fish", "spikes", "quicksand", "tank", "airstrike", "nuke", "plane", "landmine",
	"saw", "cactus", "vampire", "devil", "angel", "slow", "dizzy", "mud", "oil", "glue",
	"heaven", "sky", "hell", "apocalypse", "nothing", "parachute", "table", "door", "lamp", "tv",
	"bridge", "island", "beach", "maze", "kite", "penguin", "crab", "rabbit", "rat", "crocodile",
	"ant", "mosquito", "unicorn", "werewolf", "mummy", "ninja", "santa", "whale", "bike", "bus",
	"67", "skibidi", "sigma", "bruh", "castle", "pyramid", "lighthouse", "barn", "treehouse", "playground",
	"church", "camping", "school", "windmill", "stadium", "jenga", "bouncycastle", "supermarket", "backrooms", "ferriswheel",
	"temple", "skatepark", "aquarium", "carousel", "gasstation", "hospital", "snowman", "cave", "museum", "stonehenge",
	"moai", "waterslide", "cinema", "basketball", "sandcastle", "minecraft", "gojo", "energy_blast", "time_stop", "domain",
	"snap", "falling_blocks", "ogre", "capybara", "hamster_ball", "troll", "bonk", "nokia", "error", "lucky_block",
	"animatronic", "verity", "moodeng", "diamond", "guest", "geyser", "upside_down", "nextbot", "walk", "spin",
	"laugh", "scream", "gg", "wow", "sorry", "please", "die", "fall", "push", "cry",
	"ok", "crazy", "what", "ez", "idk", "person", "angry", "win", "sit", "quiet",
	"reset", "afk", "idle", "paint", "mom", "up", "space", "button", "easter", "vomit",
	"ballerina", "chimpanzini", "firetruck", "firefighter", "piano", "cockroach", "elephant", "goose", "waterfall", "tung",
	"tralalero", "mrbeast", "book", "grass", "lego", "balloons", "cones", "tires", "sandbags", "bamboo",
	"clear", "retro", "desert", "christmas", "autumn", "graveyard", "farm", "neon", "swamp", "hat",
	"stairs", "jellyfish", "bowling", "trash", "jungle", "savanna", "western", "paper", "underwater", "prehistoric",
	"tundra", "matrix", "dream", "upside", "kitchen", "bathtub", "sheep", "satellite", "hypergamy", "scarecrow",
	"bush", "gnome", "greenhouse", "pinata", "fireflies", "confetti", "raft", "boat", "beanstalk", "fairy",
	"leprechaun", "zipline", "icecreamtruck", "rollercoaster", "gokart", "treasure", "teacups", "oasis", "festajunina", "churrasco",
	"pillows", "sunset", "naruto", "rasengan", "kaioken", "tanjiro", "bankai", "luffy", "saitama", "nani",
	"patapim", "lirili", "trippi", "sans", "pikachu", "btools", "sussy", "rizz", "chillguy", "siuuu",
	"neymar", "ohio", "herobrine", "spiderman", "sharingan", "nyan", "brookhaven", "roadroller", "arise", "rumbling",
	"supernova", "locust", "poo", "skinwalker", "normal", "me", "baby", "aura", "end", "horror",
	"scp", "hero", "dad", "doctor", "kingkong", "sirenhead", "slenderman", "deathnote", "seek", "reaper",
	"titanic", "zoo", "exit", "jesus", "roblox", "obby", "mahoraga", "doom", "godzilla", "noob",
	"fortnite", "hulk", "titan", "goku", "sonic", "superman", "ironman", "homelander", "god", "sukuna",
	"moon", "destruction", "chaos", "blind", "admin", "boss",
}

local function randomDisaster()
	return ALL_DISASTERS[math.random(1, #ALL_DISASTERS)]
end

local nextWriteAt = 0
local function autoWriteStep()
	local word
	if Settings.AutoWriteWorst then
		word = randomDisaster()
	else
		word = Settings.WriteWord
	end
	if type(word) ~= "string" or word == "" then
		return
	end
	local now = os.clock()
	if now < nextWriteAt then
		return
	end
	nextWriteAt = now + 1.5
	local remote = findWriteRemote()
	if not remote then
		logOnce("write_nomote", "auto write: no writer submit remote found (see WriterRemotes log)", "warn")
		return
	end
	pcall(function()
		remote:FireServer(word)
	end)
	logOnce("write_word_" .. word, "auto write -> " .. word, "info")
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
	Text = "Unlimited Oxygen",
	Description = "Keeps your Breath attribute full so you never drown",
	Icon = "Lucide:wind",
	Default = false,
	Flag = "syi_unlimited_oxygen",
	Callback = function(value)
		Settings.UnlimitedOxygen = value
	end,
})
Player:AddToggle({
	Text = "Unlimited Stamina",
	Description = "Keeps the Stamina attribute full and sprint on",
	Icon = "Lucide:battery-charging",
	Default = false,
	Flag = "syi_unlimited_stamina",
	Callback = function(value)
		Settings.UnlimitedStamina = value
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
Visuals:AddToggle({
	Text = "Boss ESP",
	Description = "Highlights bosses with a health bar tag",
	Icon = "Lucide:crown",
	Default = false,
	Flag = "syi_esp_boss",
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
Words:AddSection("Auto Write", "Lucide:send")
Words:AddToggle({
	Text = "Auto Write",
	Description = "Submits the chosen word automatically",
	Icon = "Lucide:send",
	Default = false,
	Flag = "syi_auto_write",
	Callback = function(value)
		Settings.AutoWrite = value
	end,
})
Words:AddToggle({
	Text = "Random Diary Word",
	Description = "Writes a random word from every DiaryCatalog entry",
	Icon = "Lucide:shuffle",
	Default = false,
	Flag = "syi_write_worst",
	Callback = function(value)
		Settings.AutoWriteWorst = value
	end,
})

local Farm = ctx:SubTab("Farm", "Lucide:coins")
local Survival = ctx:SubTab("Survival", "Lucide:shield")

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

Farm:AddSection("Money", "Lucide:coins")
Farm:AddToggle({
	Text = "Coin Auto-Farm",
	Description = "Walks to the nearest coin automatically",
	Icon = "Lucide:coins",
	Default = false,
	Flag = "syi_coin_farm",
	Callback = function(value)
		Settings.CoinFarm = value
	end,
})
Farm:AddSection("Items", "Lucide:package")
Farm:AddToggle({
	Text = "Auto Use Item",
	Description = "Uses the selected item every 2s",
	Icon = "Lucide:package-open",
	Default = false,
	Flag = "syi_auto_use_item",
	Callback = function(value)
		Settings.AutoUseItem = value
	end,
})
Farm:AddDropdown({
	Text = "Item to Use",
	Description = "Which item the auto-user triggers",
	Icon = "Lucide:package",
	Options = itemNames,
	Default = "None",
	Flag = "syi_use_item",
	Callback = function(value)
		Settings.UseItemId = itemNameToId[value]
	end,
})
Farm:AddToggle({
	Text = "Auto Carry",
	Description = "Picks up the nearest carryable",
	Icon = "Lucide:hand",
	Default = false,
	Flag = "syi_auto_carry",
	Callback = function(value)
		Settings.AutoCarry = value
	end,
})
Farm:AddSection("Combat", "Lucide:swords")
Farm:AddToggle({
	Text = "Auto Swing",
	Description = "Fires the melee swing remote",
	Icon = "Lucide:swords",
	Default = false,
	Flag = "syi_auto_swing",
	Callback = function(value)
		Settings.AutoSwing = value
	end,
})
Farm:AddToggle({
	Text = "Auto Revive",
	Description = "Sends the revive grant when you die",
	Icon = "Lucide:heart-pulse",
	Default = false,
	Flag = "syi_auto_revive",
	Callback = function(value)
		Settings.AutoRevive = value
	end,
})
Farm:AddSection("Progress", "Lucide:scroll")
Farm:AddToggle({
	Text = "Diary Auto-Claim",
	Description = "Claims every diary category every 5s",
	Icon = "Lucide:book",
	Default = false,
	Flag = "syi_auto_diary",
	Callback = function(value)
		Settings.AutoClaimDiary = value
	end,
})

Survival:AddSection("Hazards", "Lucide:flame")
Survival:AddToggle({
	Text = "Hazard Warnings",
	Description = "Logs incoming lava, tsunamis, tornados and fires",
	Icon = "Lucide:alert-triangle",
	Default = false,
	Flag = "syi_hazard_warn",
	Callback = function(value)
		Settings.HazardWarn = value
	end,
})
Survival:AddToggle({
	Text = "Auto Dodge",
	Description = "Moves you away from nearby hazards",
	Icon = "Lucide:move-right",
	Default = false,
	Flag = "syi_auto_dodge",
	Callback = function(value)
		Settings.AutoDodge = value
	end,
})

---------------------------------------------------------------------
-- Loops
---------------------------------------------------------------------

task.spawn(function()
	while ctx:Alive() do
		if Settings.EspPlayer or Settings.EspCreature or Settings.EspCoin or Settings.EspItem or Settings.EspDisaster or Settings.EspBoss then
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

task.spawn(function()
	while ctx:Alive() do
		if Settings.CoinFarm then
			pcall(coinFarmStep)
		end
		if Settings.AutoCarry then
			pcall(autoCarryStep)
		end
		if Settings.AutoRevive then
			pcall(autoReviveStep)
		end
		if Settings.AutoClaimDiary then
			pcall(autoClaimDiaryStep)
		end
		task.wait(0.3)
	end
end)

task.spawn(function()
	while ctx:Alive() do
		if Settings.UnlimitedStamina then
			pcall(unlimitedStaminaStep)
		end
		if Settings.UnlimitedOxygen then
			pcall(unlimitedOxygenStep)
		end
		if Settings.AutoWrite then
			pcall(autoWriteStep)
		end
		task.wait(0.05)
	end
end)

task.spawn(function()
	while ctx:Alive() do
		if Settings.AutoSwing then
			pcall(autoSwingStep)
		end
		if Settings.AutoUseItem then
			pcall(autoUseItemStep)
		end
		if Settings.HazardWarn or Settings.AutoDodge then
			pcall(hazardStep)
		end
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
	Settings.InfiniteJump, Settings.Sprint, Settings.AntiRagdoll = false, false, false
	Settings.EspPlayer, Settings.EspCreature, Settings.EspCoin = false, false, false
	Settings.EspItem, Settings.EspDisaster, Settings.AutoRoll = false, false, false
	Settings.EspBoss, Settings.CoinFarm, Settings.AutoRevive = false, false, false
	Settings.AutoSwing, Settings.AutoCarry, Settings.AutoClaimDiary = false, false, false
	Settings.AutoUseItem, Settings.HazardWarn, Settings.AutoDodge = false, false, false
	Settings.UnlimitedStamina, Settings.AutoWrite = false, false
	Settings.UnlimitedOxygen = false
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
