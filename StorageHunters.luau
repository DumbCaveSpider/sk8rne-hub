-- Storage Hunters
local ctx = ...
local task = ctx.task

-- Loop: scrap garage -> auction (always-hit bid) -> move vehicle to shop -> unload -> stock shelves -> NPC offers -> repeat

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

-- an executor can run the script before the client has a LocalPlayer; capturing nil here broke every LP:... call later
if not game:IsLoaded() then game.Loaded:Wait() end
while not Players.LocalPlayer do task.wait(0.1) end
local LP = Players.LocalPlayer
local Events = RS:WaitForChild("Events")
-- Remote / module handles live in this table: a Luau function can hold at most 200 local variables, and the top level hit that limit.
local R = {}

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------
local CFG = {
	MaxBidCashFraction = 0.5, -- never bid above this fraction of the cash you had when the auction started
	-- settings edited from the panel's tabs
	SkipBroken = false,         -- never shelve broken items (they stay in the inventory)
	DisableAutoPlace = false,   -- Auto Farm leaves shelving to you (Shelf toggle / manual)
	SkipHighValue = false, MaxValueToPlace = 100000, -- don't shelve items worth more than this
	SkipLowValue = false, MinValueToPlace = 1,       -- don't shelve items worth less than this
	PlaceEveryN = 0,            -- batch mode: also sell after this many auctions (0 = only when the inventory is nearly full)
	PrioritizeNearest = false,  -- among equal garages, the one closest to you first
	PrioritizeAlien = false,    -- Alien garages first (when open)
	OnlyUseAllDrinks = false,   -- Auto Consume: wait until every selected drink is in the inventory
	AntiAFK = true,
	AutoJoin = true,            -- Auto Farm: press PLAY, claim a plot and spawn the best vehicle when the game has not been entered yet
	FishPlace = true, FishPlaceEvery = 5, -- Auto Fish: shelve the catches after every N fish
	MaxBidValueFraction = 0.10, -- never bid more than this fraction of the garage's worth (Events.Auction.UseCalculator)
	MaxBid = math.huge,      -- optional hard cap on a single bid price
	BidDelay = 0.35,          -- seconds between being outbid and re-bidding
	GarageWaitTime = 15,      -- seconds to wait for the bidding UI after the EnterAuction prompt (it starts ~6s later)
	MinOfferPct = 0,          -- reject offers worse than this % vs base price
	OfferSettle = 1.5,        -- seconds to collect offers before choosing the best
	OfferWindow = 25,         -- max seconds to wait for offers per cycle
	LoopDelay = 1,
	NoShopperNPCTimeout = 30,   -- no shopper NPC anywhere in the shop for this many seconds -> start the next auction
	ShopMargin = 25,            -- studs around the shop's footprint (your plot's bounding box) in which a shopper NPC still counts
	ShopRadius = 150,           -- fallback only (no plot geometry): NPCs within this distance of the plot origin count
	SellOutMaxTime = math.huge,-- never start an auction before everything is sold (set a number of seconds to allow giving up)
	SellOutRelaxAfter = 90,     -- no sale for this long while selling out -> start accepting the best offer down to SellOutFloorPct
	SellOutFloorPct = -15,      -- lowest % vs base price accepted once the relax timer has run out
	GarageFailCooldown = 300,   -- a garage type that refuses to start an auction is skipped for this many seconds
	MaxPlaceAttempts = 3,       -- slots tried per item before giving up on it for a while
	BadCooldown = 600,          -- seconds an item/slot that the server refused is skipped
	TierUp = true,              -- move up to the next auction site (garage tier) as soon as net worth and cash allow it
	MaxTierNetWorth = math.huge, -- optional cap: never use garages that need more net worth than this
	FarmUpgrades = true,        -- the farm buys shop upgrades and better wrenches on its own
	UpgradeCheckEvery = 60,     -- seconds between upgrade checks while farming
	ShopUpgradesPerPass = 1,    -- shop upgrades bought per check (always the cheapest unlocked one); raise it to buy several at once
	UpgradeDiamondReserve = 0, -- diamonds the farm keeps untouched (shop upgrades are paid in diamonds)
	FarmWrenchCashReserve = 300, -- cash the farm keeps for bidding when it buys a wrench
	ShopUpgradeSkip = {},       -- upgrade ids never to buy, e.g. { PlotItemLimit = true }
	CountCollectorsAsShoppers = false, -- Collectors only wait for one specific item, they don't buy: leave them out of the shopper count
	CollectorResponse = "collector_stay", -- answer given to a Collector NPC's dialog (the spy showed the game sending this one)
	WrenchCashReserve = 0,    -- cash to keep untouched when buying a wrench (raise it to keep money for bidding)
	ServiceWhileWaiting = true, -- while waiting for shoppers, also repair broken items / wash dirty items / collect finished ones
	WashWaitMax = 45,           -- max seconds the farm waits for a freshly started wash before moving on
	FarmClaimRewards = true,    -- the farm claims finished achievements (incl. Collection Book index rewards) on its own
	RewardCheckEvery = 120,     -- seconds between reward checks while farming
	FarmWash = true,            -- the farm takes dirty items to the wash shop before shelving them
	WashBeforeShelving = true,  -- dirty items are held back from the shelves until the wash shop has cleaned them
	FarmLocksmith = true,       -- the farm takes safes to the locksmith, opens finished ones and claims the rewards
	RepairBeforeShelving = true, -- broken items are held back from the shelves until the wrench has fixed them
	FarmRepair = true,       -- the farm repairs broken items itself (turn off to leave it to the Auto Repair toggle)
	FarmLostFound = true,       -- the farm collects Lost & Found itself
	TierWait = 30,              -- seconds to wait for a busy top-tier garage before settling for a lower tier
	FishBiteTimeout = 45,       -- Auto Fish: recast if nothing bites within this many seconds
	FishWalkToWater = true,     -- Auto Fish: teleport to the shore when the nearest water is out of casting range
	FishReelDelay = 3,          -- Auto Fish: seconds to "play" the reel minigame before reporting the catch
	AutoStart = false,         -- off in the hub: Auto Farm's saved toggle decides whether it starts
	BatchMode = true,          -- run auctions back to back (winnings go to the inventory) until it is nearly full, then sell everything
	BatchReserve = 6,           -- batch mode: start selling once fewer than this many inventory slots are free (one auction = up to 6 items)
	LostStreakLimit = 3,       -- after this many lost auctions in a row, sell stock to earn cash before bidding again
	AutoConfirmOverride = false, -- true = always say "yes" to the "this will override your Lost & Found items" prompt (DESTROYS those items)
	OverrideAcceptAfter = 3,    -- if Lost & Found still can't be emptied after this many declines in a row, accept it so the farm doesn't stall
}

--------------------------------------------------------------------------------
-- State / logging
--------------------------------------------------------------------------------
local State = { AvoidArrest = true, AutoMuseum = false, AutoKick = false, AutoConsume = false, AutoFish = false, KeepFavorites = true, AutoWash = false, AutoQuest = false, AutoLocksmith = false, TierSkip = 0, AutoRepair = false, AutoBid = false, AutoUnload = false, AutoCollect = false, AutoShelf = false, AutoLost = false, AutoOffers = false, Running = false, Status = "Idle", Spy = false, Sold = 0, Rejected = 0, Stocked = 0, Wins = 0 }

local LogBuffer, logSink = {}, nil -- logSink stays nil: log lines go to ctx.Log
local T0 = os.clock()

local function fmt(v)
	local t = typeof(v)
	if t == "Instance" then return v:GetFullName() end
	if t == "CFrame" or t == "Vector3" then return ("%s(%s)"):format(t, tostring(v)) end
	if t == "table" then
		local parts, n = {}, 0
		for k, val in pairs(v) do
			n = n + 1
			if n <= 12 then
				local vt = typeof(val)
				parts[#parts + 1] = tostring(k) .. "=" .. ((vt == "table") and "{...}" or (vt == "Instance" and val:GetFullName() or tostring(val)))
			end
		end
		return ("table[%d]{%s}"):format(n, table.concat(parts, ", "))
	end
	return tostring(v)
end

local function log(...)
	local n = select("#", ...)
	local parts = {}
	for i = 1, n do parts[i] = fmt((select(i, ...))) end
	local line = ("[%7.2f] %s"):format(os.clock() - T0, table.concat(parts, " "))
	ctx.Log(line)
	LogBuffer[#LogBuffer + 1] = line
	if #LogBuffer > 3000 then table.remove(LogBuffer, 1) end -- Copy Logs reads this; 400 cut off the start of every long run
	if logSink then pcall(logSink, line) end
end

local function setStatus(s)
	if State.Status ~= s then log("STATUS:", s) end
	State.Status = s
	if State.onStatus then pcall(State.onStatus, s) end
end

-- compact one-line dump of any value (tables up to `depth` levels, at most ~14 entries each) for exploring unknown remote results
local function dumpValue(v, depth)
	local t = typeof(v)
	if t == "Instance" then return v:GetFullName() end
	if t == "string" then return ("%q"):format(v) end
	if t ~= "table" then return tostring(v) end
	if depth <= 0 then return "{...}" end
	local parts, n = {}, 0
	for k, val in pairs(v) do
		n = n + 1
		if n > 14 then parts[#parts + 1] = "..." break end
		parts[#parts + 1] = tostring(k) .. "=" .. dumpValue(val, depth - 1)
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

--------------------------------------------------------------------------------
-- Remote scanner + spy (debug helpers)
--------------------------------------------------------------------------------
local function scanRemotes()
	local out = {}
	for _, d in ipairs(Events:GetDescendants()) do
		if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then
			out[#out + 1] = d.ClassName .. "  " .. d:GetFullName()
		end
	end
	table.sort(out)
	local text = table.concat(out, "\n")
	log("Remotes:\n" .. text)
	if setclipboard then pcall(setclipboard, text) end
end

local spyHooked = false
local function installSpy()
	if spyHooked then return end
	spyHooked = true
	ctx:HookMeta(game, "__namecall", function(old, self, ...)
		local m = getnamecallmethod()
		if State.Spy and (m == "FireServer" or m == "InvokeServer") and typeof(self) == "Instance"
			and self:IsDescendantOf(Events) then
			local args = table.pack(...)
			local parts = {}
			for i = 1, args.n do parts[i] = typeof(args[i]) .. ":" .. tostring(args[i]) end
			log("SPY", self:GetFullName(), m, table.concat(parts, ", "))
		end
		return old(self, ...)
	end)
end

--------------------------------------------------------------------------------
-- Remotes (all names taken from the dumps)
--------------------------------------------------------------------------------
R.AuctionR = Events:WaitForChild("Auction")
R.BidR = R.AuctionR:WaitForChild("Bid")
R.ToggleBiddingUI = R.AuctionR:WaitForChild("ToggleBiddingUI")
R.UpdateWinningBid = R.AuctionR:WaitForChild("UpdateCurrentWinningBid")
R.AuctionPaused = R.AuctionR:WaitForChild("AuctionPaused")

R.VehiclesR = Events:WaitForChild("Vehicles")
R.GetOwnedVehicles = R.VehiclesR:WaitForChild("GetOwnedVehicles")
R.RequestSpawn = R.VehiclesR:WaitForChild("RequestSpawn")
R.GetVehicleItems = R.VehiclesR:WaitForChild("GetVehicleItems")
R.TransferItems = R.VehiclesR:WaitForChild("TransferVehicleItemsToInventory")

R.PlotR = Events:WaitForChild("Plot")
R.PlaceStockItem = R.PlotR:WaitForChild("PlaceStockItem")
R.GetInventory = Events:WaitForChild("Inventory"):WaitForChild("GetPlayerInventory")

R.NPC = Events:WaitForChild("NPCShopper")
R.ShowOffer = R.NPC:WaitForChild("ShowOffer")
R.RespondOffer = R.NPC:WaitForChild("RespondOffer")
R.OfferPresented = R.NPC:WaitForChild("OfferPresented")

R.Mods = RS:WaitForChild("Modules")
R.Items = require(R.Mods:WaitForChild("Items"))
R.StockSaleRules = require(R.Mods:WaitForChild("StockSaleRules"))
R.MutatorModule = require(R.Mods:WaitForChild("MutatorModule"))
R.Grading = require(R.Mods:WaitForChild("GameConfig")).Grading

--------------------------------------------------------------------------------
-- Auction state tracking
--------------------------------------------------------------------------------
local A = { active = false, ended = false, paused = false, winner = nil, amount = 0, nextPrice = nil, updated = 0, pickupStarted = false, pickupEnded = false, pickupItems = 0 }
-- Panel-edited lists (the tabs write here): shelving filters, drinks to use, garage-area priorities
local X = { ExcludeItems = {}, ExcludeMutations = {}, DrinksToUse = {}, GaragePrio = {} }

-- after a win the server loads the items into the vehicle: AuctionPickupStart(amount, count) ... AuctionPickupEnd()
R.PickupStart = R.AuctionR:FindFirstChild("AuctionPickupStart")
R.PickupEnd = R.AuctionR:FindFirstChild("AuctionPickupEnd")
if R.PickupStart then
	ctx:Connect(R.PickupStart.OnClientEvent, function(_, count)
		A.pickupStarted = true
		A.pickupItems = 0
		A.pickupCount = tonumber(count) or 0
	end)
end
if R.PickupEnd then ctx:Connect(R.PickupEnd.OnClientEvent, function() A.pickupEnded = true end) end
-- the server fires AuctionPickupItem(value, remaining) once for every item it loads
R.PickupItem = R.AuctionR:FindFirstChild("AuctionPickupItem")
if R.PickupItem then
	ctx:Connect(R.PickupItem.OnClientEvent, function(value, remaining)
		A.pickupItems = (A.pickupItems or 0) + 1
		log("PICKUP ITEM loaded: value", value, "remaining", remaining, "(", A.pickupItems, "of", A.pickupCount, ")")
	end)
end

-- log every Auction remote that reaches the client (shows exactly when/how the server starts an auction)
for _, r in ipairs(R.AuctionR:GetChildren()) do
	if r:IsA("RemoteEvent") then
		ctx:Connect(r.OnClientEvent, function(...)
			if State.Running then
				local parts = {}
				for i = 1, select("#", ...) do parts[i] = fmt((select(i, ...))) end
				log("EVENT Auction." .. r.Name, table.concat(parts, ", "))
			end
		end)
	end
end

R.ToggleAuctionAreaR = R.AuctionR:FindFirstChild("ToggleAuctionArea")
if R.ToggleAuctionAreaR then ctx:Connect(R.ToggleAuctionAreaR.OnClientEvent, function() A.enteredAt = os.clock() end) end

-- Server asks for confirmation before starting the auction (the game's own UI answers with FireServer(true/false))
R.LostFoundOverride = R.AuctionR:FindFirstChild("LostFoundOverride")
if R.LostFoundOverride then
	ctx:Connect(R.LostFoundOverride.OnClientEvent, function(info)
		if not State.Running then return end
		-- Saying "yes" here DESTROYS the items still waiting in Lost & Found (a 1,339 haul was lost this way), so decline,
		-- let the farm claim them first, and only accept after OverrideAcceptAfter declines in a row (so the farm can't deadlock)
		A.overrideArea = type(info) == "table" and info.area or A.overrideArea
		A.overrideDeclines = (A.overrideDeclines or 0) + 1
		local accept = CFG.AutoConfirmOverride == true or A.overrideDeclines > (CFG.OverrideAcceptAfter or 3)
		log("LostFoundOverride prompt:", info, accept and "-> ACCEPTING (those Lost & Found items will be lost!)" or "-> DECLINING, claiming them first", "(decline #" .. A.overrideDeclines .. ")")
		if not accept then A.overrideBlocked = true end
		R.LostFoundOverride:FireServer(accept)
	end)
end

-- set further down; used by the standalone Auto Bidding / Auto Collect toggles when the farm is not driving the auction
local onAuctionStarted, onAuctionEnded

ctx:Connect(R.ToggleBiddingUI.OnClientEvent, function(on, garageModel)
	log("ToggleBiddingUI", on)
	if on then
		A.active, A.ended, A.winner, A.amount, A.nextPrice = true, false, nil, 0, nil
		A.pickupStarted, A.pickupEnded, A.pickupCount, A.pickupItems = false, false, 0, 0
		A.overrideDeclines, A.overrideBlocked = 0, false
		A.npcNames = {}
		if onAuctionStarted and not State.Running then task.spawn(onAuctionStarted) end
	else
		A.active, A.ended = false, true
		A.endedGarage = garageModel or A.currentGarage
		if onAuctionEnded and not State.Running then task.spawn(onAuctionEnded, A.endedGarage) end
	end
end)

ctx:Connect(R.UpdateWinningBid.OnClientEvent, function(amount, winner, winnerInst, nextPrice, garageModel)
	if garageModel then A.currentGarage = garageModel end
	-- an NPC bidder is a model that lives inside the garage (players are parented to workspace)
	if winner and winner ~= LP.Name and typeof(winnerInst) == "Instance" and garageModel and winnerInst.Parent == garageModel then
		A.npcNames = A.npcNames or {}
		A.npcNames[winner] = true
	end
	if amount and winner then
		log("BID UPDATE amount", amount, "winner", winner, "next", nextPrice)
		A.amount, A.winner, A.updated = amount, winner, os.clock()
		if nextPrice then A.nextPrice = nextPrice end
	end
end)

ctx:Connect(R.AuctionPaused.OnClientEvent, function(paused)
	log("AuctionPaused", paused)
	A.paused = paused == true
end)

--------------------------------------------------------------------------------
-- Vehicle / movement helpers
--------------------------------------------------------------------------------
local function getHumanoid()
	local c = LP.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end

local function findVehicle()
	local guid = LP:GetAttribute("EquippedVehicle")
	if not guid or guid == "" then
		log("findVehicle: EquippedVehicle attribute is empty")
		return nil
	end
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("Model") and d:GetAttribute("OwnerUserId") == LP.UserId and d:GetAttribute("VehicleGUID") == guid then
			return d
		end
	end
	local hum = getHumanoid()
	local seat = hum and hum.SeatPart
	local m = seat and seat:FindFirstAncestorOfClass("Model")
	log("findVehicle: no model with VehicleGUID", guid, "- falling back to seat model:", m)
	return m
end

-- GetOwnedVehicles() -> { vehicles = { [guid] = {Name, Favorited, ...} }, equippedGuid }. The best vehicle is the one with the largest
-- load capacity in Modules.Vehicles (the first numeric capacity-like field found); ties go to a favourite, then the most expensive.
local CAPACITY_KEYS = { "WeightCapacity", "ItemCapacity", "Capacity", "MaxItems", "StorageSlots", "Slots", "CargoSlots" }
local PRICE_KEYS = { "CashPrice", "Price", "DiamondPrice" }
function A.bestVehicle(owned)
	local okV, V = pcall(function() return require(R.Mods:WaitForChild("Vehicles", 5)) end)
	local function numeric(keys, ...)
		for _, src in ipairs({ ... }) do
			if type(src) == "table" then
				for _, k in ipairs(keys) do
					local n = tonumber(src[k])
					if n then return n, k end
				end
			end
		end
		return 0
	end
	local best, bestKey, bestScore, logged = nil, nil, nil, false
	for guid, v in pairs(type(owned) == "table" and owned.vehicles or {}) do
		local id = v.VehicleId or v.Id or v.ModelName or v.Name
		local cfg = okV and type(V) == "table" and (V[id] or V[v.Name]) or nil
		local name = tostring(v.Name or id or guid)
		if not logged and cfg then
			logged = true
			local keys = {}
			for k in pairs(cfg) do keys[#keys + 1] = tostring(k) end
			table.sort(keys)
			log("vehicle config fields (for ranking):", table.concat(keys, ", "))
		end
		if not name:lower():find("heli", 1, true) then -- helicopters can't carry the loot from the auctions
			local cap, capKey = numeric(CAPACITY_KEYS, cfg, v)
			local price = numeric(PRICE_KEYS, cfg, v)
			local score = cap * 1e9 + (v.Favorited and 1e8 or 0) + price
			log("vehicle candidate:", name, "| capacity", cap, capKey or "-", "| price", price, v.Favorited and "| favourite" or "")
			if not bestScore or score > bestScore then best, bestKey, bestScore = guid, name, score end
		end
	end
	return best, bestKey
end

local function ensureVehicle()
	local v = findVehicle()
	if v then log("vehicle:", v) return v end
	log("no vehicle out, requesting spawn")
	local ok, owned = pcall(function() return R.GetOwnedVehicles:InvokeServer() end)
	log("GetOwnedVehicles ->", ok, owned)
	if ok and type(owned) == "table" then
		local guid, name = A.bestVehicle(owned)
		guid = guid or owned.equippedGuid
		if guid then
			log("RequestSpawn", guid, name or "")
			R.RequestSpawn:FireServer(guid)
			for _ = 1, 40 do
				task.wait(0.25)
				v = findVehicle()
				if v then log("vehicle spawned:", v) return v end
			end
			log("vehicle never appeared after RequestSpawn")
		end
	end
	return nil
end

-- Join the game when it hasn't been entered yet: wait for the data to load, press PLAY, claim a plot (shop slot) and spawn the
-- best owned vehicle. Every step is skipped when it is already done, so calling this on an active session changes nothing.
function A.joinGame()
	local joined = false
	local function ownsPlot()
		local plots = workspace:FindFirstChild("_Plots")
		for _, c in ipairs(plots and plots:GetChildren() or {}) do
			if c:GetAttribute("OwnerUserId") == LP.UserId then return true end
		end
		return false
	end

	local function playButton()
		local pg = LP:FindFirstChildOfClass("PlayerGui")
		local b = pg and pg:FindFirstChild("PlayButton", true)
		if b and b:IsA("GuiButton") and b.Visible and b:IsDescendantOf(pg) then return b end
	end

	-- already in the game (plot owned, vehicle out, no PLAY screen): nothing to do
	if ownsPlot() and findVehicle() and not playButton() then return false end

	-- 1) the save has to be loaded before PLAY does anything
	local t = os.clock()
	while LP:GetAttribute("DataLoaded") ~= true and os.clock() - t < 90 do
		setStatus("Waiting for your data to load")
		task.wait(0.5)
	end


	-- 2) the PLAY screen
	local play = playButton()
	if play then
		joined = true
		log("join: PLAY screen is up - pressing PLAY")
		setStatus("Pressing PLAY")
		for attempt = 1, 6 do
			play = playButton()
			if not play then break end
			if firesignal then pcall(firesignal, play.MouseButton1Click) end
			if getconnections then
				for _, c in ipairs(getconnections(play.MouseButton1Click)) do pcall(function() c:Fire() end) end
			end
			task.wait(1.5)
		end
		log("join: PLAY screen", playButton() and "still showing" or "closed")
	end

	-- 3) a shop plot of my own (the game assigns one when none is owned)
	if not ownsPlot() then
		joined = true
		setStatus("Claiming a plot")
		local getPlots, claim = R.PlotR:FindFirstChild("GetAvailablePlots"), R.PlotR:FindFirstChild("ClaimPlot")
		if getPlots and claim then
			local ok, list = pcall(function() return getPlots:InvokeServer() end)
			log("join: available plots ->", ok, type(list) == "table" and #list or list)
			if ok and type(list) == "table" then
				local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
				if hrp then
					table.sort(list, function(a, b)
						return (Vector3.new(a.OriginX or 0, a.OriginY or 0, a.OriginZ or 0) - hrp.Position).Magnitude
							< (Vector3.new(b.OriginX or 0, b.OriginY or 0, b.OriginZ or 0) - hrp.Position).Magnitude
					end)
				end
				for _, p in ipairs(list) do
					local okC, res = pcall(function() return claim:InvokeServer(p.Name) end)
					log("join: ClaimPlot", p.Name, "->", okC, res)
					if ownsPlot() then break end
				end
			end
		else
			log("join: plot remotes not found")
		end
	end

	-- 4) the best vehicle, when none is out (or right after joining, so the best one replaces the starter vehicle)
	local out = findVehicle()
	if joined or not out then
		setStatus("Spawning the best vehicle")
		local ok, owned = pcall(function() return R.GetOwnedVehicles:InvokeServer() end)
		if ok and type(owned) == "table" then
			local guid, name = A.bestVehicle(owned)
			if guid and guid ~= LP:GetAttribute("EquippedVehicle") or (guid and not out) then
				log("join: spawning the best vehicle:", name)
				R.RequestSpawn:FireServer(guid)
				for _ = 1, 40 do
					task.wait(0.25)
					if findVehicle() and LP:GetAttribute("EquippedVehicle") == guid then break end
				end
			else
				log("join: the best vehicle is already out:", name)
			end
		end
	end
	if joined then log("join: done") end
	return joined
end

local function findSeat(vehicle)
	return vehicle:FindFirstChild("DriveSeat", true) or vehicle:FindFirstChildWhichIsA("VehicleSeat", true)
end

local function ensureSeated(vehicle)
	local hum = getHumanoid()
	if not hum or hum.SeatPart then return end
	local seat = findSeat(vehicle)
	if not seat then log("ensureSeated: no seat found in", vehicle) return end
	log("ensureSeated: sitting in", seat)
	LP.Character:PivotTo(seat.CFrame + Vector3.new(0, 3, 0))
	task.wait(0.2)
	pcall(function() seat:Sit(hum) end)
	task.wait(0.5)
	log("ensureSeated: SeatPart now", hum.SeatPart)
end

local function leaveVehicle()
	local hum = getHumanoid()
	if hum and hum.SeatPart then
		log("leaveVehicle: getting out of", hum.SeatPart)
		hum.Sit = false
		hum.Jump = true
		task.wait(0.5)
		log("leaveVehicle: SeatPart now", hum.SeatPart)
	end
end

-- teleport the character and VERIFY it actually landed (the game / physics can pull it back, e.g. to the vehicle)
local function moveCharacter(cf)
	log("moveCharacter ->", cf.Position)
	local char = LP.Character
	if not char then return false end
	local hrp
	for attempt = 1, 4 do
		hrp = char:FindFirstChild("HumanoidRootPart")
		if not hrp then return false end
		local hum = char:FindFirstChildOfClass("Humanoid")
		if hum and hum.SeatPart then hum.Sit = false end
		char:PivotTo(cf)
		hrp.AssemblyLinearVelocity = Vector3.zero
		task.wait(0.2)
		if (hrp.Position - cf.Position).Magnitude < 10 then return true end
		log("moveCharacter: attempt", attempt, "landed at", hrp.Position, "- retrying")
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	log("moveCharacter FAILED: at", hrp and hrp.Position, "wanted", cf.Position, "| seated", hum and hum.SeatPart, "| anchored", hrp and hrp.Anchored, "| health", hum and hum.Health)
	return false
end

local function moveVehicle(vehicle, cf)
	log("moveVehicle ->", cf.Position)
	vehicle:PivotTo(cf)
	for _, p in ipairs(vehicle:GetDescendants()) do
		if p:IsA("BasePart") then
			p.AssemblyLinearVelocity = Vector3.zero
			p.AssemblyAngularVelocity = Vector3.zero
		end
	end
end

local function myPlot()
	local plots = workspace:FindFirstChild("_Plots")
	if not plots then return end
	for _, p in ipairs(plots:GetChildren()) do
		if p:IsA("Folder") and p:GetAttribute("OwnerUserId") == LP.UserId then return p end
	end
end

-- plot origin/rotation as the game's own Unload screen reads it (OriginX/Y/Z, RotationY)
local plotData
do
	local assigned = R.PlotR:FindFirstChild("PlotAssigned")
	if assigned then ctx:Connect(assigned.OnClientEvent, function(_, data) if type(data) == "table" then plotData = data end end) end
end

local function getPlotData()
	if plotData then return plotData end
	local req = R.PlotR:FindFirstChild("RequestPlotData")
	if req then
		local ok, data = pcall(function() return req:InvokeServer() end)
		if ok and type(data) == "table" then plotData = data end
	end
	return plotData
end

-- Where the vehicle must be to unload: the game's UnpackZone, i.e. 100 studs "forward" of the plot origin, radius 14 (horizontal)
local function plotSpot(plot)
	-- 1) a real part called UnpackZone inside the plot, if the map has one
	local zonePart = plot:FindFirstChild("UnpackZone", true)
	if zonePart and zonePart:IsA("BasePart") then
		log("unpack zone: part", zonePart:GetFullName(), zonePart.Position)
		return CFrame.new(zonePart.Position + Vector3.new(0, 5, 0))
	end

	-- 2) computed exactly like UnloadVehicle.isInUnpackZone
	local d = getPlotData()
	if d and d.OriginX then
		local origin = CFrame.new(d.OriginX, d.OriginY or 0, d.OriginZ) * CFrame.Angles(0, math.rad(d.RotationY or 0), 0)
		local p = origin:PointToWorldSpace(Vector3.new(0, 0, -100))
		-- drop onto the ground at that spot
		local params = RaycastParams.new()
		local ignore = { LP.Character }
		local v = findVehicle()
		if v then ignore[#ignore + 1] = v end
		params.FilterDescendantsInstances = ignore
		local hit = workspace:Raycast(Vector3.new(p.X, (d.OriginY or p.Y) + 80, p.Z), Vector3.new(0, -300, 0), params)
		local y = hit and (hit.Position.Y + 4) or ((d.OriginY or p.Y) + 6)
		log("unpack zone: computed", Vector3.new(p.X, y, p.Z), "origin", Vector3.new(d.OriginX, d.OriginY or 0, d.OriginZ), "rotY", d.RotationY)
		return CFrame.new(p.X, y, p.Z) * CFrame.Angles(0, math.rad(d.RotationY or 0), 0)
	end

	-- 3) last resort: middle of the furniture
	log("unpack zone: no plot data, falling back to furniture center")
	local sum, n = Vector3.zero, 0
	local furniture = plot:FindFirstChild("Furniture")
	for _, part in ipairs((furniture or plot):GetDescendants()) do
		if part:IsA("BasePart") then sum = sum + part.Position; n = n + 1 end
	end
	if n == 0 then return nil end
	return CFrame.new(sum / n + Vector3.new(0, 8, 0))
end

local function getNetWorth()
	local ls = LP:FindFirstChild("leaderstats")
	local nw = ls and ls:FindFirstChild("Net Worth")
	local n = nw and tonumber(nw:GetAttribute("RawValue"))
	if not n then n = tonumber(LP:GetAttribute("NetWorth")) end
	if not n and nw then
		-- displayed text such as "$23.2K" / "1.5M": strip the symbols and apply the suffix
		local text = tostring(nw.Value):upper()
		local num = tonumber((text:gsub("[^%d%.%-]", "")))
		local mult = ({ K = 1e3, M = 1e6, B = 1e9, T = 1e12 })[text:match("%d([KMBT])%s*$") or ""] or 1
		n = num and num * mult
	end
	return n or 0
end

-- Garage tiers come from Modules.Garages (MinNetWorth / EntryCost / EventOnly / EntryCurrency); higher MinNetWorth = higher tier
local okGarages, GaragesCfg = pcall(require, R.Mods:WaitForChild("Garages", 5))
if not okGarages or type(GaragesCfg) ~= "table" then GaragesCfg = nil end

-- Modules.Areas maps every garage id to its area (Junk Yard, Farmyard, ...) - which is also where its Lost & Found box is
local okAreas, AreasCfg = pcall(require, R.Mods:WaitForChild("Areas", 5))
if not okAreas or type(AreasCfg) ~= "table" then AreasCfg = nil end

local function garageAreaName(g)
	if not (AreasCfg and g) then return nil end
	local ok, area = pcall(AreasCfg.GetGarageAreaName, g:GetAttribute("GarageId") or g.Name)
	return ok and area or nil
end

local unknownGarages = {}
local garageFailures = {} -- garage name -> os.clock() of the last time it refused to start an auction
local function garageConfig(g)
	if not GaragesCfg then return nil end
	local cfg = GaragesCfg[g:GetAttribute("GarageId") or g.Name]
	if type(cfg) == "table" then return cfg end
	if not unknownGarages[g.Name] then
		unknownGarages[g.Name] = true
		log("garage '" .. g.Name .. "' has no entry in Modules.Garages")
	end
	return nil
end

-- Usable garages, best tier first. With CFG.TierUp the farm picks the highest tier you qualify for
-- (net worth + cash entry fee, no event / special-currency garages); State.TierSkip steps down tiers after repeated losses.
local function scrapGarages()
	local out = {}
	local debris = workspace:FindFirstChild("_Debris")
	local garages = debris and debris:FindFirstChild("Garages")
	if not garages then log("scrapGarages: workspace._Debris.Garages missing") return out end

	local netWorth, cash = getNetWorth(), LP:GetAttribute("Cash") or 0
	local entries, locked = {}, {}
	for _, g in ipairs(garages:GetChildren()) do
		if g:IsA("Model") and g:FindFirstChild("AuctionZone") then
			local cfg = garageConfig(g)
			local ok, tier = false, 0
			local failedAt = garageFailures[g.Name]
			local coolingDown = failedAt and os.clock() - failedAt < (CFG.GarageFailCooldown or 300)
			if coolingDown then
				ok = false
			elseif CFG.TierUp and cfg then
				tier = tonumber(cfg.MinNetWorth) or 0
				local fee = cfg.EntryCost and tonumber(cfg.EntryCost.Max) or 0
				local alienOk = CFG.PrioritizeAlien and g.Name:find("^Alien Garage") -- event garages paid in cash
				ok = (not cfg.EventOnly or alienOk) and not cfg.EntryCurrency and not cfg.RequiredGarageWins
					and tier <= netWorth and fee <= cash and tier <= (CFG.MaxTierNetWorth or math.huge)
			elseif g.Name:find("Scrap Garage") then
				ok = true
			end
			if ok then entries[#entries + 1] = { g = g, tier = tier }
			elseif cfg and not cfg.EventOnly and not cfg.EntryCurrency and (tonumber(cfg.MinNetWorth) or 0) > netWorth then
				locked[g.Name] = tonumber(cfg.MinNetWorth)
			end
		end
	end
	-- order: Priority 1..3 areas first (Garage Types), then aliens if asked, then the highest tier; optionally nearest first
	local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
	local veh = CFG.PrioritizeNearest and hrp and hrp.Position
	local function rank(e)
		local area = garageAreaName(e.g)
		for i, a in ipairs(X.GaragePrio) do if a == area then return i end end
		return #X.GaragePrio + 1
	end
	for _, e in ipairs(entries) do
		e.rank = rank(e)
		e.alien = CFG.PrioritizeAlien and e.g.Name:find("^Alien Garage") and 0 or 1
		e.dist = veh and (e.g:GetPivot().Position - veh).Magnitude or 0
	end
	table.sort(entries, function(x, y)
		if x.alien ~= y.alien then return x.alien < y.alien end
		if x.rank ~= y.rank then return x.rank < y.rank end
		if x.tier ~= y.tier then return x.tier > y.tier end
		return x.dist < y.dist
	end)

	-- Auto Quest: area-scoped quest tasks ("Win a junk yard auction", "Sell 5 junk yard items") only count for garages of
	-- that area, so prefer them over higher tiers elsewhere while such a task is unfinished
	if State.AutoQuest and State.QuestArea then
		local inArea = {}
		for _, e in ipairs(entries) do
			if garageAreaName(e.g) == State.QuestArea then inArea[#inArea + 1] = e end
		end
		if #inArea > 0 then
			entries = inArea
		else
			log("quest area '" .. State.QuestArea .. "' has no usable garage right now - using all areas")
		end
	end

	-- step down whole tiers after repeated lost auctions
	local tiers = {}
	for _, e in ipairs(entries) do
		if tiers[#tiers] ~= e.tier then tiers[#tiers + 1] = e.tier end
	end
	local skip = math.min(State.TierSkip or 0, math.max(#tiers - 1, 0))
	local startTier = tiers[skip + 1]
	for _, e in ipairs(entries) do
		if not startTier or #X.GaragePrio > 0 or e.tier <= startTier then out[#out + 1] = e.g end
	end

	-- what is still out of reach: the garages in the world that need more net worth
	do
		local names = {}
		for name, need in pairs(locked) do names[#names + 1] = name .. " (needs " .. need .. ")" end
		table.sort(names)
		if #names > 0 then log("scrapGarages: locked by net worth:", table.concat(names, ", ")) end
	end
	log("scrapGarages: usable", #out, "of", #garages:GetChildren(), "| net worth", netWorth, "| cash", cash,
		"| top tier", out[1] and out[1].Name, "(min net worth", startTier, ") skip", skip)
	return out
end
--------------------------------------------------------------------------------
-- Auction phase: go to scrap garage and bid (never misses the zone, since only Bid:FireServer() is checked server-side)
--------------------------------------------------------------------------------
local function bidLoop(cashLimit)
	local me = LP.Name
	while (State.Running or State.AutoBid) and A.active do
		if not A.paused and A.winner ~= me then
			local price = A.nextPrice
			local cash = LP:GetAttribute("Cash") or 0
			if price and (price > cashLimit or price > CFG.MaxBid) then
				if A.skipLogged ~= price then
					A.skipLogged = price
					log("skip bid: price", price, "> limit", math.min(cashLimit, CFG.MaxBid))
				end
				setStatus("Bid too high, waiting for auction to end")
				task.wait(0.5)
			elseif price and cash < price then
				setStatus("Not enough cash, waiting")
				task.wait(0.5)
			else
				task.wait(CFG.BidDelay)
				if A.active and not A.paused and A.winner ~= me then
					local before = A.updated
					log("BID fired. price", price, "cash", cash, "limit", cashLimit)
					R.BidR:FireServer()
					setStatus("Bidding" .. (price and (" $" .. tostring(price)) or ""))
					local t = os.clock()
					while A.active and A.updated == before and os.clock() - t < 1.5 do task.wait(0.05) end
					if A.updated == before then log("no BID UPDATE within 1.5s after bid (rejected or rate-limited?)") end
				end
			end
		else
			task.wait(0.1)
		end
	end
end

-- number of items currently in the equipped vehicle (nil if it can't be read)
local function vehicleItemCount()
	local guid = LP:GetAttribute("EquippedVehicle")
	if not guid or guid == "" then return nil end
	local ok, items = pcall(function() return R.GetVehicleItems:InvokeServer(guid) end)
	if not ok or type(items) ~= "table" then return nil end
	local n = 0
	for _ in pairs(items) do n = n + 1 end
	return n
end

-- Finds a ProximityPrompt belonging to a part/prompt named "EnterAuction" inside the garage, and triggers it.
local function findEnterPrompt(garage)
	for _, d in ipairs(garage:GetDescendants()) do
		if d.Name == "EnterAuction" then
			if d:IsA("ProximityPrompt") then return d, d.Parent end
			local p = d:FindFirstChildWhichIsA("ProximityPrompt", true)
			if p then return p, d end
		end
	end
	for _, d in ipairs(garage:GetDescendants()) do
		if d:IsA("ProximityPrompt") and (d.ActionText:lower():find("auction") or d.ObjectText:lower():find("auction")) then
			return d, d.Parent
		end
	end
end

local function triggerEnterPrompt(garage)
	local prompt, holder = findEnterPrompt(garage)
	if not prompt then
		log("no EnterAuction prompt in", garage.Name)
		return false
	end
	local pos = holder and holder:IsA("BasePart") and holder.Position
		or (holder and holder:IsA("Attachment") and holder.WorldPosition)
		or (holder and holder:IsA("Model") and holder:GetPivot().Position)
	log("EnterAuction prompt:", prompt, "enabled", prompt.Enabled, "hold", prompt.HoldDuration, "dist", prompt.MaxActivationDistance, "at", pos)
	-- stand right on top of the prompt part and make sure we really are within activation range before firing
	if pos then
		local target = CFrame.new(pos + Vector3.new(0, 3, 0))
		local maxDist = prompt.MaxActivationDistance
		for attempt = 1, 3 do
			moveCharacter(target)
			task.wait(0.3)
			local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
			local dist = hrp and (hrp.Position - pos).Magnitude
			log("standing", dist and ("%.1f"):format(dist) or "?", "studs from the prompt (max", maxDist, ") attempt", attempt)
			if dist and dist <= maxDist then break end
		end
	end
	prompt.RequiresLineOfSight = false
	if fireproximityprompt then
		pcall(fireproximityprompt, prompt)
		log("fireproximityprompt called")
	else
		pcall(function()
			prompt:InputHoldBegin()
			task.wait(prompt.HoldDuration + 0.1)
			prompt:InputHoldEnd()
		end)
		log("InputHoldBegin/End used (no fireproximityprompt)")
	end
	return true
end

local deliverWinnings -- defined after collectLostFound
local collectLostFoundRef -- forward reference to collectLostFound (defined further down)

-- standalone toggles (used when you start/finish an auction yourself while Auto Farm is off)
onAuctionStarted = function()
	if not State.AutoBid then return end
	local limit = (LP:GetAttribute("Cash") or 0) * CFG.MaxBidCashFraction
	log("Auto Bidding: auction started, bid limit", limit)
	setStatus("Auto bidding")
	bidLoop(limit)
	log("Auto Bidding: auction over. winner", A.winner, "amount", A.amount)
end

onAuctionEnded = function(garage)
	if not State.AutoCollect then return end
	task.wait(0.3)
	if A.winner ~= LP.Name then
		log("Auto Collect: auction lost (winner " .. tostring(A.winner) .. "), nothing to collect")
		return
	end
	State.Wins = State.Wins + 1
	A.lastGarageArea = garageAreaName(garage)
	log("Auto Collect: won at", garage, "- area", A.lastGarageArea, "- collecting")
	deliverWinnings(A.pickupCount)
end

-- everything interactable inside a garage (attributes, prompts, click detectors) - to find out what really starts the auction
local function dumpGarageInteractables(garage)
	local attrs = {}
	for k, v in pairs(garage:GetAttributes()) do attrs[#attrs + 1] = k .. "=" .. tostring(v) end
	log("garage attributes:", #attrs > 0 and table.concat(attrs, ", ") or "none")
	local found = {}
	for _, d in ipairs(garage:GetDescendants()) do
		if d:IsA("ProximityPrompt") then
			found[#found + 1] = ("Prompt %s [%s/%s] enabled=%s hold=%s dist=%s"):format(
				d:GetFullName():gsub("^.*Garages%.", ""), d.ActionText, d.ObjectText, tostring(d.Enabled), tostring(d.HoldDuration), tostring(d.MaxActivationDistance))
		elseif d:IsA("ClickDetector") then
			found[#found + 1] = "Click " .. d:GetFullName():gsub("^.*Garages%.", "")
		end
		if #found >= 14 then break end
	end
	log("garage interactables:", #found > 0 and table.concat(found, " | ") or "none")
end

-- fire the garage's other prompts / click detectors once (e.g. a door "Button")
local function tryOtherTriggers(garage)
	local n = 0
	for _, d in ipairs(garage:GetDescendants()) do
		if n >= 4 then break end
		if d:IsA("ProximityPrompt") and d.Name ~= "EnterAuction" and d.Enabled then
			local holder = d.Parent
			local pos = holder and holder:IsA("BasePart") and holder.Position or (holder and holder:IsA("Attachment") and holder.WorldPosition)
			if pos then moveCharacter(CFrame.new(pos + Vector3.new(0, 3, 4))) task.wait(0.4) end
			d.RequiresLineOfSight = false
			if fireproximityprompt then pcall(fireproximityprompt, d) end
			log("fired extra prompt", d:GetFullName():gsub("^.*Garages%.", ""))
			n = n + 1
			task.wait(0.6)
		elseif d:IsA("ClickDetector") and fireclickdetector then
			pcall(fireclickdetector, d)
			log("fired click detector", d:GetFullName():gsub("^.*Garages%.", ""))
			n = n + 1
			task.wait(0.6)
		end
	end
end

-- Auto Kick NPC: Events.Auction.UseKickNPC:InvokeServer(npcName) removes one NPC bidder from the auction. Every NPC in the
-- garage is kicked once per auction: the models standing in it, plus any NPC that shows up as a bidder (seen in the bid updates).
function A.kickNpcs(garage)
	local kick = R.AuctionR:FindFirstChild("UseKickNPC")
	if not kick then log("Events.Auction.UseKickNPC not found - Auto Kick unavailable") return end
	local kicked = {}
	task.spawn(function()
		while A.active and State.AutoKick and garage.Parent do
			local names = {}
			for name in pairs(A.npcNames or {}) do names[name] = true end
			for _, m in ipairs(garage:GetChildren()) do
				if m:IsA("Model") and m:FindFirstChildOfClass("Humanoid") and not Players:GetPlayerFromCharacter(m) then names[m.Name] = true end
			end
			names.Auctioneer = nil -- the host isn't a bidder
			for name in pairs(names) do
				if not kicked[name] and A.active then
					kicked[name] = true
					local ok, res = pcall(function() return kick:InvokeServer(name) end)
					log("kick NPC", name, "->", ok, dumpValue(res, 2))
					-- the server answers "limit" once the kicks for this auction are used up: stop asking
					if res == "limit" then return end
					task.wait(0.4)
				end
			end
			task.wait(1.5)
		end
	end)
end

local function auctionPhase()
	local vehicle = ensureVehicle()
	if not vehicle then setStatus("No vehicle found") return false end

	-- always aim for the highest unlocked tier: when every garage of that tier is busy (someone else's auction / resetting),
	-- wait for one to free up instead of dropping straight to a lower, less profitable tier
	local function tierOf(g) local c = garageConfig(g) return c and tonumber(c.MinNetWorth) or 0 end
	local garages
	local waitUntil = os.clock() + (CFG.TierWait or 30)
	while true do
		local ranked, ready = scrapGarages(), {}
		for _, g in ipairs(ranked) do
			if findEnterPrompt(g) then ready[#ready + 1] = g
			else log("skipping", g:GetFullName(), "(no EnterAuction prompt - garage in use or resetting)") end
		end
		garages = ready
		local topTier = ranked[1] and tierOf(ranked[1])
		local haveTop = false
		for _, g in ipairs(ready) do if tierOf(g) == topTier then haveTop = true break end end
		if haveTop or not topTier or #ranked == 0 or os.clock() >= waitUntil or not State.Running then break end
		setStatus("Waiting for a top-tier garage (" .. ranked[1].Name .. ")")
		task.wait(3)
	end
	if #garages == 0 then
		setStatus("No available scrap garage, retrying")
		task.wait(3)
		return false
	end

	for _, garage in ipairs(garages) do
		if not State.Running then return false end
		if not garage.Parent or not garage:FindFirstChild("AuctionZone") then
			log("garage vanished, skipping", garage.Name)
			continue
		end
		if garageFailures[garage.Name] and os.clock() - garageFailures[garage.Name] < (CFG.GarageFailCooldown or 300) then
			continue -- another garage of this type just refused to start an auction
		end
		ensureSeated(vehicle)
		A.active, A.ended, A.pickupStarted, A.pickupEnded, A.pickupCount, A.pickupItems = false, false, false, false, 0, 0
		setStatus("Going to " .. garage.Name)
		A.garageName = garage.Name
		-- ensureSeated yields; the garage can reset in the meantime (it was just seen in use)
		local zone = garage.Parent and garage:FindFirstChild("AuctionZone")
		if not zone then
			log("garage reset while getting ready, skipping", garage.Name)
			garageFailures[garage.Name] = os.clock()
			continue
		end
		local pivot = garage:GetPivot()
		local ext = garage:GetExtentsSize()
		log("garage pivot", pivot.Position, "extents", ext, "| zone", zone.Position, "size", zone.Size)

		-- park the vehicle just outside the garage (the player must be on foot to enter the auction)
		moveVehicle(vehicle, pivot * CFrame.new(ext.X / 2 + 20, 4, 0))
		task.wait(0.8)
		leaveVehicle()

		-- if the garage has an EnterAuction prompt, use it first
		local promptAt = os.clock()
		local triggered = triggerEnterPrompt(garage)
		if triggered then
			-- a working prompt makes the server fire ToggleAuctionArea within a fraction of a second; if nothing happens, fail fast
			local t = os.clock()
			while State.Running and not A.active and not A.overrideBlocked and (A.enteredAt or 0) < promptAt and os.clock() - t < 4 do task.wait(0.2) end
			if A.overrideBlocked then
				-- the server wants to override unclaimed Lost & Found items: we declined, so claim them now and restart the cycle
				A.overrideBlocked = false
				log("Lost & Found still holds unclaimed items - claiming them before the auction")
				local n = collectLostFoundRef(true)
				log("claimed", n, "item(s) from Lost & Found")
				return false, "retry"
			end
			if not A.active and (A.enteredAt or 0) < promptAt then
				log("EnterAuction prompt did nothing in", garage.Name, "(no ToggleAuctionArea within 4s)")
				dumpGarageInteractables(garage)
				tryOtherTriggers(garage)
				t = os.clock()
				while State.Running and not A.active and (A.enteredAt or 0) < promptAt and os.clock() - t < 4 do task.wait(0.2) end
			end
			if A.active or (A.enteredAt or 0) >= promptAt then
				t = os.clock()
				while State.Running and not A.active and os.clock() - t < CFG.GarageWaitTime do task.wait(0.2) end
			end
			log("after EnterAuction prompt: active =", A.active, "entered =", (A.enteredAt or 0) >= promptAt)
		else
			-- no prompt: try standing in the garage interior, then in the bidding zone itself
			local spots = { pivot + Vector3.new(0, 4, 0), zone.CFrame + Vector3.new(0, 3, 0) }
			for idx, spot in ipairs(spots) do
				if A.active or not State.Running then break end
				moveCharacter(spot)
				local t = os.clock()
				while State.Running and not A.active and os.clock() - t < CFG.GarageWaitTime / 2 do task.wait(0.2) end
				log("spot", idx, "result: active =", A.active)
			end
		end

		if not A.active then
			garageFailures[garage.Name] = os.clock()
			log("garage", garage.Name, "never started an auction - skipping this garage type for", CFG.GarageFailCooldown, "s")
		end
		if A.active then
			log("auction started, cash", LP:GetAttribute("Cash"))
			moveCharacter(zone.CFrame + Vector3.new(0, 3, 0)) -- stand in the bidding zone
			local cashLimit = (LP:GetAttribute("Cash") or 0) * CFG.MaxBidCashFraction

			-- Events.Auction.UseCalculator:InvokeServer() answers with the garage's top value; never bid more than a fraction of it
			A.worth, A.bidCap = nil, nil
			local calc = R.AuctionR:FindFirstChild("UseCalculator")
			if calc then
				-- the server sometimes answers nil (a limit / cooldown on the calculator): note how long ago it was last used
				-- and whether that call passed, and retry a couple of times before giving up on this auction
				local last = A.calc
				log("calculator: last used", last and ("%.0fs ago"):format(os.clock() - last.at) or "never", last and (last.pass and "(passed)" or "(returned nothing)") or "")
				local worth, resC
				for try = 1, 3 do
					local okC
					okC, resC = pcall(function() return calc:InvokeServer() end)
					worth = okC and (tonumber(resC) or (type(resC) == "table" and tonumber(resC.value or resC.Value or resC.total or resC.worth))) or nil
					log("calculator try", try, "->", okC, dumpValue(resC, 2))
					if worth then break end
					task.wait(2)
				end
				A.calc = { at = os.clock(), pass = worth ~= nil, value = worth }
				if not worth then log("calculator gave no value - bidding without the worth cap this auction") end
				if worth and worth > 0 then
					A.worth = worth
					A.bidCap = worth * (CFG.MaxBidValueFraction or 0.1)
					cashLimit = math.min(cashLimit, A.bidCap)
					log(("garage worth $%.0f - bid cap $%.0f (%d%% of it)"):format(worth, A.bidCap, (CFG.MaxBidValueFraction or 0.1) * 100))
				end
			end
			if State.AutoKick then A.kickNpcs(garage) end
			bidLoop(cashLimit)
			A.worth, A.bidCap = nil, nil
			log("auction over. winner", A.winner, "amount", A.amount, "me", LP.Name)
			if A.winner == LP.Name then
				State.Wins = State.Wins + 1
				setStatus("Won auction")
				A.lastGarage = garage
				A.lastGarageArea = garageAreaName(garage)
				log("won at", garage.Name, "- area (Lost & Found location):", A.lastGarageArea)
				setStatus("Won - heading to the shop")
				return true
			end
			setStatus("Lost auction")
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- Stock shelves
--------------------------------------------------------------------------------
local function freeSlots(plot)
	local furniture = plot:FindFirstChild("Furniture")
	local stock = plot:FindFirstChild("Stock")
	if not furniture then return {} end
	local used = {}
	if stock then
		for _, s in ipairs(stock:GetChildren()) do
			local g, n = s:GetAttribute("ShelfGUID"), s:GetAttribute("SnapPointName")
			if g and n then used[g .. "|" .. n] = true end
		end
	end
	local slots = {}
	for _, shelf in ipairs(furniture:GetChildren()) do
		local guid = shelf:GetAttribute("GUID")
		if typeof(guid) == "string" and guid ~= "" then
			local seen = {}
			for _, d in ipairs(shelf:GetDescendants()) do
				if d:IsA("Attachment") and d.Name:match("^SnapPoint") and not seen[d.Name] then
					seen[d.Name] = true
					if not used[guid .. "|" .. d.Name] then
						slots[#slots + 1] = { shelfGuid = guid, snap = d.Name, att = d, rot = shelf:GetAttribute("ShelfRotationY") }
					end
				end
			end
		end
	end
	return slots
end

-- Broken items must be repaired before they go on a shelf. Events.Repair.GetRepairableItems lists exactly the broken items;
-- anything in that list is held back until the wrench has been used on it.
local repairableGuids = {}
-- Dirty items must be washed before they go on a shelf. Events.Wash.GetWashableItems lists what the Wash Shop can clean.
-- Items the wash shop refused are remembered in unwashable so they still get shelved as they are.
local washableGuids, unwashable = {}, {}
local function refreshWashable()
	washableGuids = {}
	if not CFG.WashBeforeShelving then return end
	local w = Events:FindFirstChild("Wash")
	local get = w and w:FindFirstChild("GetWashableItems")
	if not (get and get:IsA("RemoteFunction")) then return end
	local ok, res = pcall(function() return get:InvokeServer() end)
	if not ok or type(res) ~= "table" then return end
	local function add(g) if type(g) == "string" and not (unwashable[g] and unwashable[g] > os.clock()) then washableGuids[g] = true end end
	if type(res.items) == "table" then
		for k, v in pairs(res.items) do
			if type(v) == "table" then add(v.guid) elseif type(k) == "string" then add(k) end
		end
	else
		for k, v in pairs(res) do
			if type(v) == "table" and v.guid then add(v.guid) end
		end
	end
end
local unrepairable = {} -- guid -> os.clock() until which the wrench is known NOT to fix this item (it is shelved as it is)
local function refreshRepairable()
	repairableGuids = {}
	if not CFG.RepairBeforeShelving then return end
	local r = Events:FindFirstChild("Repair")
	local getItems = r and r:FindFirstChild("GetRepairableItems")
	if not getItems then return end
	local ok, res = pcall(function() return getItems:InvokeServer() end)
	if ok and type(res) == "table" and type(res.items) == "table" then
		for _, it in ipairs(res.items) do
			-- items the server already refused to repair are not held back (they would never get shelved otherwise)
			if it.guid and not (unrepairable[it.guid] and unrepairable[it.guid] > os.clock()) then repairableGuids[it.guid] = true end
		end
	end
end

-- The server answers every PlaceStockItem with PlaceStockItemResult(requestGuid, success). Items/slots that the server
-- refuses ("won't fit", "slot already occupied") are remembered so the farm doesn't retry the same failure forever.
local placeResults = {}
R.PlaceResultR = R.PlotR:FindFirstChild("PlaceStockItemResult")
if R.PlaceResultR then
	ctx:Connect(R.PlaceResultR.OnClientEvent, function(id, ok) placeResults[id] = ok end)
end

local badSlots, badItems, slotFails = {}, {}, {}   -- key/guid -> os.clock() until which it is skipped
local function isBadItem(guid) return badItems[guid] ~= nil and badItems[guid] > os.clock() end
-- favourited items (entry.Favorited, set in the inventory UI) stay in the inventory when the Keep Favs toggle is on
-- Modules.EnergyDrinks lists every consumable by ItemId (luck drinks, potions, the Phoenix Feather); the targeted ones
-- (cleaning sprays, extractor / grade-removal potions) need an item chosen first, so they are not drunk automatically.
local okDrinks, DrinkCfg = pcall(function() return require(R.Mods:WaitForChild("EnergyDrinks", 5)) end)
local drinkIds = {}
if okDrinks and type(DrinkCfg) == "table" then
	for _, d in pairs(DrinkCfg) do
		if type(d) == "table" and d.ItemId and not d.Targeted and not d.GradeRerollCharge then drinkIds[tostring(d.ItemId)] = true end
	end
end
local function isDrink(entry)
	if type(entry) ~= "table" then return false end
	if drinkIds[tostring(entry.ItemId)] then return true end
	local def = R.Items and R.Items[tostring(entry.ItemId)]
	return def and tostring(def.Name or ""):lower():find("drink", 1, true) ~= nil or false
end
-- "Only Use When All Selected Available": true unless that option is on and a selected drink is missing from the inventory
function A.drinksReady(inv)
	if not CFG.OnlyUseAllDrinks or next(X.DrinksToUse) == nil then return true end
	local have = {}
	for _, e in pairs(inv) do
		local d = type(e) == "table" and R.Items[tostring(e.ItemId)]
		if d then have[d.Name] = true end
	end
	for name in pairs(X.DrinksToUse) do if not have[name] then return false end end
	return true
end
local function isKept(entry)
	if type(entry) ~= "table" then return false end
	if State.AutoConsume and isDrink(entry) then return true end -- drinks get drunk, not sold
	return State.KeepFavorites and entry.Favorited == true
end
local function slotKey(s) return s.shelfGuid .. "|" .. s.snap end

-- returns accepted, gotAnswer
local function tryPlace(itemGuid, entry, def, slot)
	local price = R.MutatorModule:CalculatePriceForEntry(def.BasePrice or 0, entry)
	local gm = R.Grading.GradeCashMultForEntry(entry)
	if gm ~= 1 then price = math.floor(price * gm * 100 + 0.5) / 100 end
	local cf = slot.att.WorldCFrame * CFrame.Angles(0, math.rad(tonumber(slot.rot) or 0), 0)
	local req = HttpService:GenerateGUID(false)
	placeResults[req] = nil
	log("PlaceStockItem", def.Name, "price", price, "shelf", slot.shelfGuid, slot.snap)
	R.PlaceStockItem:FireServer(itemGuid, tostring(entry.ItemId), cf, price, slot.shelfGuid, slot.snap, nil, nil, true, req)
	local t = os.clock()
	while placeResults[req] == nil and os.clock() - t < 2 do task.wait(0.05) end
	local got = placeResults[req]
	placeResults[req] = nil
	if got == nil then return true, false end -- no answer: assume it worked, like before
	return got == true, true
end

function A.itemValue(entry, def)
	local price = R.MutatorModule:CalculatePriceForEntry(def.BasePrice or 0, entry)
	local gm = R.Grading.GradeCashMultForEntry(entry)
	if gm ~= 1 then price = price * gm end
	return price
end
local function hasMutation(entry, name)
	if entry[name] == true then return true end
	for _, key in ipairs({ "Mutators", "Mutations", "Mutator" }) do
		local m = entry[key]
		if type(m) == "table" and (m[name] == true or table.find(m, name)) then return true end
	end
	return false
end
-- false = leave this inventory item alone (reason is logged once per item)
local skipLogged = {}
function A.placeable(guid, entry, def)
	local why
	if X.ExcludeItems[def.Name] then why = "excluded item"
	elseif CFG.SkipBroken and (repairableGuids[guid] or unrepairable[guid]) then why = "broken item"
	else
		for name in pairs(X.ExcludeMutations) do
			if hasMutation(entry, name) then
				why = "mutation " .. name
				break
			end
		end
		if not why and (CFG.SkipHighValue or CFG.SkipLowValue) then
			local v = A.itemValue(entry, def)
			if CFG.SkipHighValue and v > CFG.MaxValueToPlace then why = ("value %.0f above %.0f"):format(v, CFG.MaxValueToPlace)
			elseif CFG.SkipLowValue and v < CFG.MinValueToPlace then why = ("value %.0f below %.0f"):format(v, CFG.MinValueToPlace) end
		end
	end
	if why and not skipLogged[guid] then skipLogged[guid] = true log("not shelving", def.Name, "-", why) end
	return why == nil
end

local function stockShelvesImpl()
	if CFG.DisableAutoPlace and State.Running and not State.AutoShelf then return end
	local plot = myPlot()
	if not plot then setStatus("No plot found") return end
	local ok, inv = pcall(function() return R.GetInventory:InvokeServer() end)
	if not ok or type(inv) ~= "table" then setStatus("Inventory failed") log("GetInventory ->", ok, inv) return end

	refreshRepairable()
	refreshWashable()
	local heldBack = 0
	for _ in pairs(repairableGuids) do heldBack = heldBack + 1 end
	if heldBack > 0 then log("stockShelves:", heldBack, "broken item(s) held back until repaired") end

	local now = os.clock()
	local slots = {}
	for _, sl in ipairs(freeSlots(plot)) do
		if not (badSlots[slotKey(sl)] and badSlots[slotKey(sl)] > now) then slots[#slots + 1] = sl end
	end
	log("stockShelves: inventory", inv, "free slots", #slots)

	local used = {}
	for itemGuid, entry in pairs(inv) do
		if not (State.Running or State.AutoShelf or State.AutoUnload) then break end
		local def = R.Items[tostring(entry.ItemId)]
		if def and not R.StockSaleRules.GetSellBlockReason(entry) and not repairableGuids[itemGuid] and not washableGuids[itemGuid] and not isBadItem(itemGuid) and not isKept(entry) and A.placeable(itemGuid, entry, def) then
			-- every free slot that isn't taken yet (the server decides what fits; refusals are remembered)
			local ordered = {}
			for _, sl in ipairs(slots) do
				if not used[slotKey(sl)] then ordered[#ordered + 1] = sl end
			end
			local placed, attempts = false, 0
			for _, sl in ipairs(ordered) do
				attempts = attempts + 1
				setStatus("Stocking shelves")
				local okP, accepted = pcall(tryPlace, itemGuid, entry, def, sl)
				if not okP then
					log("stockShelves: placing", def.Name, "threw an error:", accepted)
					return
				end
				if accepted then
					used[slotKey(sl)] = true
					State.Stocked = State.Stocked + 1
					placed = true
					break
				end
				local k = slotKey(sl)
				slotFails[k] = (slotFails[k] or 0) + 1
				if slotFails[k] >= 3 then badSlots[k] = os.clock() + (CFG.BadCooldown or 600) end
				if attempts >= (CFG.MaxPlaceAttempts or 3) then break end
				task.wait(0.15)
			end
			if not placed and attempts > 0 then
				badItems[itemGuid] = os.clock() + (CFG.BadCooldown or 600)
				log("stockShelves: couldn't place", def.Name, "after", attempts, "attempt(s) - leaving it in the inventory for now")
			end
			task.wait(0.1)
		end
	end
end

-- An error while shelving must never take the whole farm cycle down (it soft-locked the farm). Log it with a traceback
-- so the failing line is visible, then carry on - sellOut treats "nothing got stocked" as unshelvable and moves on.
local function stockShelves()
	local ok, err = xpcall(stockShelvesImpl, function(e) return tostring(e) .. "\n" .. debug.traceback("", 2) end)
	if not ok then log("stockShelves FAILED:", err) end
end
--------------------------------------------------------------------------------
-- Unload vehicle (then stock; repeat until the vehicle is empty or shop is full)
--------------------------------------------------------------------------------
-- inventoryOnly (batch mode): move the vehicle's items into the inventory and leave them there (no shelving)
local function unloadAndStock(inventoryOnly)
	for _ = 1, 15 do
		if not (State.Running or State.AutoUnload) then return end
		local guid = LP:GetAttribute("EquippedVehicle")
		if not guid or guid == "" then return end
		local ok, items = pcall(function() return R.GetVehicleItems:InvokeServer(guid) end)
		log("GetVehicleItems ->", ok, items)
		if not ok or type(items) ~= "table" or next(items) == nil then return end

		local free = (LP:GetAttribute("InventoryCap") or 0) - (LP:GetAttribute("InventoryCount") or 0)
		log("inventory", LP:GetAttribute("InventoryCount"), "/", LP:GetAttribute("InventoryCap"), "free", free)
		if free <= 0 and inventoryOnly then
			log("inventory is full - the rest stays in the vehicle until it's sold")
			return
		end
		if free <= 0 then
			stockShelves()
			free = (LP:GetAttribute("InventoryCap") or 0) - (LP:GetAttribute("InventoryCount") or 0)
			if free <= 0 then setStatus("Inventory/shelves full") return end
		end

		local batch = {}
		for itemGuid in pairs(items) do
			if #batch >= free then break end
			batch[#batch + 1] = itemGuid
		end
		-- the unload only works from the driver's seat: get back in if something (Lost & Found trip, shopper walk) took us out
		local hum = getHumanoid()
		if hum and not hum.SeatPart then
			local vehicle = findVehicle()
			if vehicle then
				log("unload: player is not seated - entering", vehicle.Name)
				for _ = 1, 3 do
					ensureSeated(vehicle)
					if hum.SeatPart then break end
					task.wait(0.5)
				end
			end
			if not hum.SeatPart then log("unload: couldn't get into the vehicle, trying anyway") end
		end
		setStatus("Unloading " .. #batch .. " items")
		R.TransferItems:FireServer(batch)
		task.wait(1.5)
		if not inventoryOnly then stockShelves() end
	end
end

--------------------------------------------------------------------------------
-- NPC offers: accept the best, reject bad ones
--------------------------------------------------------------------------------
local pending, answered, lastOfferAt = {}, {}, 0
-- offers the server keeps re-showing no matter how often we answer (e.g. a stuck/ghost shopper that never completes a sale):
-- after GHOST_AFTER answers to the same id, ignore it so it can't keep the farm waiting forever
local answerCount, GHOST_AFTER = {}, 3
local function isGhostOffer(guid)
	return (answerCount[guid] or 0) >= GHOST_AFTER
end

ctx:Connect(R.ShowOffer.OnClientEvent, function(guid, npc, _text, price, base)
	if not (State.Running or State.AutoOffers) then
		-- explains "the shopper never left and nothing was logged": offers arrive but nothing is switched on to answer them
		if os.clock() - (State.offerIgnoredAt or -1e9) > 30 then
			State.offerIgnoredAt = os.clock()
			log("a shopper made an offer but Auto Farm and Auto Offers are both OFF - nothing will answer it")
		end
		return
	end
	if isGhostOffer(guid) then return end
	-- same rule as the game's own UI: ignore a repeat of an offer we just answered (same id AND price) for 8s only.
	-- A permanent "answered" list is what made us ignore an offer the server re-showed because our first reply didn't take.
	do
		local a = answered[guid]
		if a and os.clock() - a.at < 8 and math.abs((a.price or 0) - (price or 0)) <= 0.005 then return end
	end
	local dist
	do
		local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
		if hrp and typeof(npc) == "Instance" then
			local ok, p = pcall(function() return npc:GetPivot().Position end)
			if ok then dist = (hrp.Position - p).Magnitude end
		end
	end
	log("OFFER", guid, "price", price, "base", base, ("(%+.0f%%)"):format(base and base > 0 and (price - base) / base * 100 or 0), "| shopper", dist and ("%.0f studs away"):format(dist) or "?")
	if typeof(npc) == "Instance" and State.ShopperLearnedFrom ~= npc then
		State.ShopperLearnedFrom = npc
		State.ShopperParent = npc.Parent
		local attrs = {}
		for k, v in pairs(npc:GetAttributes()) do attrs[#attrs + 1] = k .. "=" .. tostring(v) end
		log("shopper NPC model seen in an offer:", npc:GetFullName(), "| class", npc.ClassName, "| attributes", #attrs > 0 and table.concat(attrs, ", ") or "none")
	end	pending[guid] = { price = price, base = base }
	lastOfferAt = os.clock()
	pcall(function() R.OfferPresented:FireServer(guid, price, npc) end)
end)

-- The server hides an offer when it expires / is finished: forget it so it is never answered late.
do
	local hideR = R.NPC:FindFirstChild("HideOffer")
	if hideR then
		ctx:Connect(hideR.OnClientEvent, function(guid)
			if guid ~= nil then pending[guid] = nil end
		end)
	end
end

-- Second source of offers: when the game does show its offer card (shopper within 55 studs) it is a BillboardGui named
-- "NPCShopperOffer_<guid>" with PricePanel.OfferText = "$12.34 [+20%]". Reading it works even if the ShowOffer event was missed.
local function readOfferCards()
	local pg = LP:FindFirstChildOfClass("PlayerGui")
	if not pg then return end
	for _, g in ipairs(pg:GetChildren()) do
		if g:IsA("BillboardGui") and g.Name:sub(1, 16) == "NPCShopperOffer_" then
			local guid = g.Name:sub(17)
			local a = answered[guid]
			if not pending[guid] and not isGhostOffer(guid) and not (a and os.clock() - a.at < 8) then
				local label = g:FindFirstChild("OfferText", true)
				local text = label and label:IsA("TextLabel") and label.Text:gsub("<[^>]->", "") or nil
				local priceStr = text and text:match("%$([%d,%.]+)")
				local price = priceStr and tonumber((priceStr:gsub(",", "")))
				local pctStr = text and text:match("%[([%+%-]%d+)%%%]")
				local pctVal = pctStr and tonumber(pctStr)
				if price then
					local base = pctVal and (price / (1 + pctVal / 100)) or nil
					pending[guid] = { price = price, base = base }
					lastOfferAt = os.clock()
					log("OFFER (read from the offer card)", guid, "price", price, pctVal and ("(%+d%%)"):format(pctVal) or "")
				end
			end
		end
	end
end

task.spawn(function()
	while true do
		task.wait(1.5)
		if State.Running or State.AutoOffers then pcall(readOfferCards) end
	end
end)
local function pct(o)
	if o.base and o.base > 0 then return (o.price - o.base) / o.base * 100 end
	return 0
end

local function resolveOffers()
	if not next(pending) then return end
	local snapshot = pending
	pending = {}
	-- Every offer is a separate sale (a different shopper wants a different item), so accept each one that is good enough and
	-- reject only the bad ones. (Accepting just the "best" of a batch sent paying shoppers away.)
	local floor = State.OfferFloor or CFG.MinOfferPct
	for guid, o in pairs(snapshot) do
		local accept = pct(o) >= floor
		answered[guid] = { price = o.price, at = os.clock() }
		answerCount[guid] = (answerCount[guid] or 0) + 1
		if answerCount[guid] == GHOST_AFTER then
			log("offer", guid, "was answered", GHOST_AFTER, "times and keeps coming back - ignoring it from now on")
		end
		log(accept and "ACCEPT" or "REJECT", guid, "price", o.price, ("(%+.0f%%)"):format(pct(o)))
		R.RespondOffer:FireServer(guid, accept)
		if accept then State.Sold = State.Sold + 1 else State.Rejected = State.Rejected + 1 end
		task.wait(0.15)
	end
end

-- Shopper NPCs physically in MY shop. They aren't described in the dumps, so look for models whose name contains "shopper"
-- (e.g. "ShopperNPC") that belong to my plot: inside the plot folder, owned by me by attribute, or near the plot origin.
local shopperScan = { count = 0, at = -1e9, fullAt = -1e9, container = nil, lastCount = nil }
local noShopperSince = nil

-- The shop's footprint: the bounding box (X/Z) of everything in MY plot folder, cached for 30s.
-- Only NPCs standing inside it (plus a small margin) count - _NPCShoppers is shared by every player's shop.
local shopBounds = { at = -1e9, box = nil }
local function getShopBounds(plot)
	local now = os.clock()
	if shopBounds.box and now - shopBounds.at < 30 then return shopBounds.box end
	if not plot then return shopBounds.box end
	local minX, maxX, minZ, maxZ
	for _, d in ipairs(plot:GetDescendants()) do
		if d:IsA("BasePart") then
			local pos, size = d.Position, d.Size
			local half = math.max(size.X, size.Z) / 2 -- crude (ignores rotation), errs on the large side
			minX = math.min(minX or pos.X - half, pos.X - half)
			maxX = math.max(maxX or pos.X + half, pos.X + half)
			minZ = math.min(minZ or pos.Z - half, pos.Z - half)
			maxZ = math.max(maxZ or pos.Z + half, pos.Z + half)
		end
	end
	if not minX then return shopBounds.box end
	local box = { minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ }
	local old = shopBounds.box
	shopBounds.box, shopBounds.at = box, now
	if not old or math.abs(old.minX - minX) > 5 or math.abs(old.maxX - maxX) > 5 or math.abs(old.minZ - minZ) > 5 or math.abs(old.maxZ - maxZ) > 5 then
		log(("shop area: X %.0f..%.0f, Z %.0f..%.0f (+%d margin)"):format(minX, maxX, minZ, maxZ, CFG.ShopMargin or 25))
	end
	return box
end

local function isInMyShop(m, plot)
	if plot and m:IsDescendantOf(plot) then return true end
	if m:GetAttribute("OwnerUserId") == LP.UserId or m:GetAttribute("PlotOwner") == LP.UserId then return true end
	local pos = m:GetPivot().Position
	local box = getShopBounds(plot)
	if box then
		local margin = CFG.ShopMargin or 25
		return pos.X >= box.minX - margin and pos.X <= box.maxX + margin and pos.Z >= box.minZ - margin and pos.Z <= box.maxZ + margin
	end
	-- no plot geometry available: fall back to a radius around the plot origin
	local pd = plotData or getPlotData()
	if pd and pd.OriginX then
		local dx, dz = pos.X - pd.OriginX, pos.Z - (pd.OriginZ or 0)
		return math.sqrt(dx * dx + dz * dz) <= (CFG.ShopRadius or 150)
	end
	return true -- can't tell whose shop it is, so count it
end
-- a walking NPC: a Model with a Humanoid that is not a player's character and not an auction NPC inside a garage
local function isNPCModel(d)
	if not d:IsA("Model") or not d:FindFirstChildOfClass("Humanoid") then return false end
	if Players:GetPlayerFromCharacter(d) then return false end
	local debris = workspace:FindFirstChild("_Debris")
	local garages = debris and debris:FindFirstChild("Garages")
	if garages and d:IsDescendantOf(garages) then return false end
	return true
end

local function scanShopperNPCs()
	local plot = myPlot()
	local now = os.clock()
	local function scan(root)
		local n, parent, names = 0, nil, {}
		for _, d in ipairs(root:GetDescendants()) do
			if isNPCModel(d) and isInMyShop(d, plot) then
				n = n + 1
				parent = parent or d.Parent
				if #names < 3 then names[#names + 1] = (d:GetFullName():gsub("^Workspace%.", "")) end
			end
		end
		return n, parent, names
	end

	-- Real shoppers live in one folder (offers tell us which; default _NPCShoppers). Quest NPCs and other townspeople elsewhere
	-- in the mall must NOT count, so never fall back to scanning the whole workspace.
	local container = State.ShopperParent
	if not (container and container.Parent) then container = workspace:FindFirstChild("_NPCShoppers") end
	if not container then
		for _, c in ipairs(workspace:GetChildren()) do
			if c.Name:lower():find("shopper", 1, true) then container = c break end
		end
	end
	local n, names = 0, {}
	if container then
		local cnt, nm = 0, {}
		shopperScan.positions = {}
		shopperScan.collectors = {}
		for _, d in ipairs(container:GetDescendants()) do
			if isNPCModel(d) and isInMyShop(d, plot) then
				if d.Name:lower():find("collector", 1, true) then
					shopperScan.collectors[#shopperScan.collectors + 1] = d
					if CFG.CountCollectorsAsShoppers then cnt = cnt + 1 end
				else
					cnt = cnt + 1
					shopperScan.positions[#shopperScan.positions + 1] = d:GetPivot().Position
				end
				if #nm < 3 then nm[#nm + 1] = (d:GetFullName():gsub("^Workspace%.", "")) end
			end
		end
		n, names = cnt, nm
	else
		-- no shopper folder found at all: we can't tell, so assume shoppers exist rather than skipping the sell-out
		if not shopperScan.warnedNoFolder then
			shopperScan.warnedNoFolder = true
			log("no shopper NPC folder found (looked for _NPCShoppers) - assuming shoppers are present")
		end
		n = 1
	end	n = n or 0
	if shopperScan.lastCount ~= n then
		shopperScan.lastCount = n
		log("shopper NPCs in the shop:", n, names and #names > 0 and ("(" .. table.concat(names, ", ") .. ")") or "")
	end
	return n
end
-- seconds the shop has been completely without shopper NPCs (0 while at least one is there)
local function secondsWithoutShoppers()
	local now = os.clock()
	if now - shopperScan.at > 2 then
		shopperScan.at = now
		shopperScan.count = scanShopperNPCs()
	end
	if shopperScan.count > 0 then
		noShopperSince = nil
		return 0
	end
	noShopperSince = noShopperSince or now
	return now - noShopperSince
end

local collectorTick -- defined with the quest dialogs: talks to Collector NPCs in the shop while the farm waits for shoppers
local serviceWhileWaiting -- defined after autoWash: repairs / washes / collects while the farm waits for shoppers

local function offerLoop()
	local plot = myPlot()
	local stock = plot and plot:FindFirstChild("Stock")
	local started = os.clock()
	local seenStock = false
	log("offer wait: stock items on shelves", stock and #stock:GetChildren())
	setStatus("Waiting for offers")
	local lastNpcMove, lastService, lastCollector = -1e9, -1e9, -1e9
	while State.Running and os.clock() - started < CFG.OfferWindow do
		-- Collector NPCs wait for the player to talk to them (a quest dialog); an unanswered one just stands there
		if collectorTick and os.clock() - lastCollector > 12 then
			lastCollector = os.clock()
			secondsWithoutShoppers() -- refreshes the scan (and the collector list)
			pcall(collectorTick)
		end
		-- use the waiting time: broken items -> wrench, dirty items -> wash shop, and collect anything finished
		if serviceWhileWaiting and os.clock() - lastService > 10 then
			lastService = os.clock()
			local acted = serviceWhileWaiting()
			if acted and acted > 0 then
				local okS, errS = pcall(stockShelves)
				if not okS then log("stockShelves error:", errS) end
			end
		end
		-- Shoppers only deal with a player standing close to them (the game's offer card needs <= 55 studs), and the drop-off
		-- point can be far from where they walk: if nothing came in for a while, stand next to the nearest shopper.
		if not next(pending) and os.clock() - lastOfferAt > 8 and os.clock() - lastNpcMove > 15 then
			secondsWithoutShoppers() -- refreshes shopperScan.positions
			local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
			local best, bestD
			for _, pos in ipairs(shopperScan.positions or {}) do
				local d = hrp and (hrp.Position - pos).Magnitude or 0
				if not bestD or d < bestD then best, bestD = pos, d end
			end
			if best and (not bestD or bestD > 45) then -- the game's offer card needs <= 55 studs; don't teleport when already in range
				lastNpcMove = os.clock()
				leaveVehicle()
				log("moving next to the nearest shopper (it was", bestD and ("%.0f"):format(bestD) or "?", "studs away)")
				moveCharacter(CFrame.new(best + Vector3.new(5, 3, 0)))
			end
		end
		-- no shopper NPC anywhere in the shop for a while: nobody is coming, stop waiting
		if not next(pending) and secondsWithoutShoppers() >= CFG.NoShopperNPCTimeout then
			log("no shopper NPC in the shop for", CFG.NoShopperNPCTimeout, "s - ending the offer wait")
			break
		end
		if next(pending) and os.clock() - lastOfferAt >= CFG.OfferSettle then
			local soldBefore = State.Sold
			resolveOffers()
			-- only a sale extends the wait: a shopper re-offering the same rejected price must not hold the loop forever,
			-- or sellOut never gets to relax the accept floor
			if State.Sold ~= soldBefore then started = os.clock() end
		end
		if stock and #stock:GetChildren() > 0 then seenStock = true end
		-- sold out (only trusted once we've seen the new stock appear on the shelves)
		if seenStock and stock and #stock:GetChildren() == 0 and not next(pending) then
			log("stock sold out, ending offer wait")
			break
		end
		task.wait(0.25)
	end
	if next(pending) then resolveOffers() end
	log("offer wait ended after", ("%.1fs"):format(os.clock() - started), "- stock left:", stock and #stock:GetChildren())
end

--------------------------------------------------------------------------------
-- Farm loop
--------------------------------------------------------------------------------
-- take the vehicle to the shop, unload it, stock the shelves and handle NPC offers
local function sellPhase(expected)
	local plot = myPlot()
	local spot = plot and plotSpot(plot)
	local vehicle = findVehicle()
	log("sell phase: plot", plot, "spot", spot and spot.Position, "vehicle", vehicle)
	if not (vehicle and spot) then
		setStatus("Plot or vehicle not found")
		return false
	end
	if expected and expected > 0 then
		deliverWinnings(expected) -- drives to the unpack zone, waits for the pickup to finish, recovers anything that went to Lost & Found
	else
		setStatus("Moving vehicle to shop")
		ensureSeated(vehicle)
		moveVehicle(vehicle, spot)
		task.wait(1.5)
	end
	unloadAndStock()
	offerLoop()
	return true
end

-- the last garage must be finished/reset (pickup done, EnterAuction available again or garage replaced) before bidding again
local function waitLastGarageCleared()
	local g = A.lastGarage
	if not g then return end
	local t = os.clock()
	-- the pickup often only ends when the next auction is entered, so don't stall for long waiting on it
	while State.Running and os.clock() - t < 8 do
		local gone = not g.Parent
		local ready = g.Parent and findEnterPrompt(g)
		if A.pickupEnded and (gone or ready) then
			log("last garage cleared:", gone and "replaced/removed" or "prompt available again", ("(%.1fs)"):format(os.clock() - t))
			A.lastGarage = nil
			return
		end
		setStatus("Waiting for last garage to clear")
		task.wait(0.5)
	end
	log("last garage not confirmed cleared after 8s (pickupEnded =", A.pickupEnded, ") - continuing")
	A.lastGarage = nil
end

--------------------------------------------------------------------------------
-- Lost & Found: GetLostItems(area) -> ClaimLostItem(area, guid) for every flagged area (walks to the box only if the server refuses)
--------------------------------------------------------------------------------
R.UIEvents = Events:FindFirstChild("UI")
R.LostItemsStatus = R.UIEvents and R.UIEvents:FindFirstChild("LostItemsStatus")
R.OpenLostItemsUI = R.UIEvents and R.UIEvents:FindFirstChild("OpenLostItemsUI")
local lostAreas, lostAnywhere = {}, false

if R.LostItemsStatus then
	ctx:Connect(R.LostItemsStatus.OnClientEvent, function(status)
		lostAreas, lostAnywhere = {}, false
		if type(status) == "table" then
			for area, n in pairs(status) do
				if (tonumber(n) or 0) > 0 then
					if area == "_anywhere" then lostAnywhere = true else lostAreas[area] = true end
				end
			end
		elseif (tonumber(status) or 0) > 0 then
			lostAnywhere = true
		end
		local names = {}
		for a in pairs(lostAreas) do names[#names + 1] = a end
		log("LostItemsStatus: anywhere =", lostAnywhere, "areas =", table.concat(names, ", "))
	end)
end

-- log the server's toast messages while a farm/auto feature is on (they explain refusals like "vehicle at max capacity")
R.NotifyR = R.UIEvents and R.UIEvents:FindFirstChild("Notify")
if R.NotifyR then
	ctx:Connect(R.NotifyR.OnClientEvent, function(msg)
		if State.Running or State.AutoCollect or State.AutoBid or State.AutoLost or State.AutoRepair or State.AutoUnload then
			log("NOTIFY:", (tostring(msg):gsub("<[^>]->", "")))
		end
	end)
end

local lostUIOpenedAt = 0
if R.OpenLostItemsUI then
	ctx:Connect(R.OpenLostItemsUI.OnClientEvent, function(...)
		lostUIOpenedAt = os.clock()
		local parts = {}
		for i = 1, select("#", ...) do parts[i] = fmt((select(i, ...))) end
		log("OpenLostItemsUI:", table.concat(parts, ", "))
	end)
end

local function findLostBoxes()
	local out = {}
	local function add(box)
		local area = box:GetAttribute("AreaName") or (box.Parent and box.Parent.Name)
		if lostAnywhere or (area and lostAreas[area]) then out[#out + 1] = box end
	end
	local areas = workspace:FindFirstChild("Areas")
	if areas then
		for _, a in ipairs(areas:GetChildren()) do
			local b = a:FindFirstChild("Lost and Found Box")
			if b then add(b) end
		end
	end
	local ship = workspace:FindFirstChild("CargoShip")
	local sb = ship and ship:FindFirstChild("Lost and Found Box")
	if sb then add(sb) end
	local stop = workspace:FindFirstChild("CargoTrainStop")
	if stop then
		for _, c in ipairs(stop:GetChildren()) do
			if c.Name == "Lost and Found Box" then add(c) end
		end
	end
	return out
end

R.GetLostItems = R.UIEvents and R.UIEvents:FindFirstChild("GetLostItems")
R.ClaimLostItem = R.UIEvents and R.UIEvents:FindFirstChild("ClaimLostItem")

local function boxArea(box)
	return box:GetAttribute("AreaName") or (box.Parent and box.Parent.Name)
end

-- claim everything waiting in one area through the same remotes the Lost & Found UI uses
-- returns claimed, failed
local function claimArea(area)
	local ok, res = pcall(function() return R.GetLostItems:InvokeServer(area) end)
	if not ok or type(res) ~= "table" then
		log("GetLostItems", area, "->", ok, res)
		return 0, 0
	end
	local items = res.items or {}
	local n = 0
	for _ in pairs(items) do n = n + 1 end
	log("GetLostItems", area, "->", n, "items", res.stillInAuction and "(still in auction)" or "")
	local claimed, failed = 0, 0
	for guid in pairs(items) do
		local ok2, r = pcall(function() return R.ClaimLostItem:InvokeServer(area, guid) end)
		if ok2 and type(r) == "table" and r.success then
			claimed = claimed + 1
		else
			log("ClaimLostItem failed", area, guid, ok2, r)
			if ok2 and type(r) == "table" and r.error == "vehicle" then
				-- the vehicle is full: claimed items go INTO it, so walking to the box only moves us away from it
				-- (the "vehicle too far away" loop). Stop; the rest is claimed after the vehicle is unloaded.
				State.LostVehicleFull = true
				break
			end
			failed = failed + 1
		end
		task.wait(0.15)
	end
	return claimed, failed
end

local lostBusy = false
local function collectLostFound(force)
	if lostBusy or not (R.GetLostItems and R.ClaimLostItem) then return 0 end
	lostBusy = true

	-- which areas to check: flagged by the server, plus every box's area when the server says "anywhere"
	local areas, seen = {}, {}
	local function addArea(a) if a and not seen[a] then seen[a] = true areas[#areas + 1] = a end end
	for a in pairs(lostAreas) do addArea(a) end
	if lostAnywhere then
		for _, box in ipairs(findLostBoxes()) do addArea(boxArea(box)) end
		addArea("Junk Yard")
	end
	if force then
		addArea(A.overrideArea)   -- the area the server said still holds unclaimed items
		addArea(A.lastGarageArea) -- the area of the garage we last won at (differs per tier)
		addArea("Junk Yard")
	end -- the status event can lag behind, so check the default area anyway
	if #areas == 0 then lostBusy = false return 0 end

	State.LostVehicleFull = false
	local total = 0
	for _, area in ipairs(areas) do
		if not (State.Running or State.AutoLost or State.AutoCollect) then break end
		setStatus("Collecting Lost & Found: " .. area)
		local claimed, failed = claimArea(area)
		total = total + claimed

		-- the server may want you next to the box: walk there, open it once, and try again
		if State.LostVehicleFull then
			log("vehicle is full - leaving the rest of", area, "in Lost & Found until the vehicle is unloaded")
			break
		end
		if failed > 0 then
			local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
			local home = hrp and hrp.CFrame
			local hum = getHumanoid()
			if hum and hum.SeatPart then leaveVehicle() end
			for _, box in ipairs(findLostBoxes()) do
				if boxArea(box) == area then
					local prompt = box:FindFirstChild("LostFoundPrompt", true)
					local holder = prompt and prompt.Parent
					local pos = holder and holder:IsA("BasePart") and holder.Position or box:GetPivot().Position
					log("claim failed remotely, going to box", box:GetFullName())
					moveCharacter(CFrame.new(pos + Vector3.new(0, 3, 3)))
					task.wait(0.6)
					if prompt and fireproximityprompt then
						prompt.Enabled = true
						prompt.RequiresLineOfSight = false
						pcall(fireproximityprompt, prompt)
						task.wait(1)
					end
					local c2 = claimArea(area)
					total = total + c2
					break
				end
			end
			if home then moveCharacter(home) end
		end
	end
	log("lost&found pass done, claimed", total, "items")
	lostBusy = false
	return total
end

--------------------------------------------------------------------------------
-- Auto Repair: broken items in the inventory are repaired with the equipped wrench (Events.WrenchShop.RepairWithWrench).
-- The repair shop does NOT repair items (it only upgrades the wrench), so there is no shop / slot / collect / claim path.
-- Events.Repair.GetRepairableItems only lists what is broken.
--------------------------------------------------------------------------------
R.RepairR = Events:FindFirstChild("Repair")
local function repairRemote(name) return R.RepairR and R.RepairR:FindFirstChild(name) end

local repairBusy = false

-- what a refusal from RepairWithWrench means: the wrench can't fix this item (value limit), a distance problem, or unknown
local function repairErrorKind(err)
	err = tostring(err or ""):lower()
	if err:find("wrench", 1, true) or err:find("valuable", 1, true) or err:find("value", 1, true) or err:find("tier", 1, true) then return "wrench" end
	if err:find("far", 1, true) or err:find("near", 1, true) or err:find("distance", 1, true) or err:find("range", 1, true)
		or err:find("shop", 1, true) or err:find("close", 1, true) then return "distance" end
	return "unknown"
end

-- Events.WrenchShop.RepairWithWrench repairs an item with the equipped wrench, no shop and no slot needed. Its arguments aren't
-- known, so the most likely shapes (mirroring the other shops' calls without the slot) are tried in order,
-- every answer is logged, and the shape that works is remembered.
local WRENCH_ARGS = {
	function(it) return it.guid end, -- confirmed from a Cobalt capture: RepairWithWrench:InvokeServer(itemGuid)
}
local wrenchPattern = 1       -- index into WRENCH_ARGS
local wrenchTried = {}        -- guid -> os.clock() of the last attempt

-- returns itemsStillBroken, fixedCount, needRequery
local function wrenchRepairPass(list)
	local shop = Events:FindFirstChild("WrenchShop")
	local rw = shop and shop:FindFirstChild("RepairWithWrench")
	if not rw then return list, 0, false end

	local equipped, holdSeconds = nil, 0
	pcall(function()
		local st = shop:FindFirstChild("GetState")
		local res = st and st:InvokeServer()
		equipped = type(res) == "table" and res.equipped or nil
		local W = require(R.Mods:WaitForChild("Wrench", 5))
		if equipped and W.GetHoldSeconds then holdSeconds = tonumber(W.GetHoldSeconds(equipped)) or 0 end
	end)

	local remaining, fixed, requery = {}, 0, false
	for _, it in ipairs(list) do
		local inInventory = it.source == nil or it.source == "Inventory"
		local recent = wrenchTried[it.guid] and os.clock() - wrenchTried[it.guid] < 30
		if not inInventory or recent or (unrepairable[it.guid] and unrepairable[it.guid] > os.clock()) then
			remaining[#remaining + 1] = it
		else
			wrenchTried[it.guid] = os.clock()
			setStatus("Repairing with the wrench")
			-- the wrench takes a moment to repair (hold time) - respect it before asking the server
			task.wait(math.min(holdSeconds, 8))

			local order = {}
			if wrenchPattern then order[1] = wrenchPattern end
			for k = 1, #WRENCH_ARGS do if k ~= wrenchPattern then order[#order + 1] = k end end

			local success = false
			for _, k in ipairs(order) do
				local function args() return WRENCH_ARGS[k](it) end
				local ok, res
				if rw:IsA("RemoteFunction") then
					ok, res = pcall(function() return rw:InvokeServer(args()) end)
				else
					ok = pcall(function() rw:FireServer(args()) end)
					requery = true
				end
				log("RepairWithWrench", it.guid, "(args #" .. k .. ", wrench " .. tostring(equipped) .. ", hold " .. holdSeconds .. "s) ->", ok, dumpValue(res, 2))
				if ok and (res == true or (type(res) == "table" and res.success)) then
					success = true
					wrenchPattern = k
					break
				end
				-- the wrench can't fix this one (value limit) - other argument shapes won't change that
				if ok and type(res) == "table" and repairErrorKind(res.error) == "wrench" then break end
				if rw:IsA("RemoteEvent") then break end -- no answer to learn from
				task.wait(0.3)
			end

			if success then
				fixed = fixed + 1
				-- dealt with: stop holding it back from the shelves
				unrepairable[it.guid] = os.clock() + (CFG.BadCooldown or 600)
			else
				remaining[#remaining + 1] = it
				-- the wrench can't fix it: stop holding it back from the shelves (it is shelved broken) and don't retry for a while
				unrepairable[it.guid] = os.clock() + (CFG.BadCooldown or 600)
				log("this item can't be repaired with the current wrench - it will be shelved as it is")
			end
			task.wait(0.3)
		end
	end
	return remaining, fixed, requery
end
-- Repairs the broken items in the inventory with the wrench; returns the number of items repaired.
-- Items the wrench can't fix are remembered (unrepairable) and shelved as they are.
local function autoRepair()
	local getItems = repairRemote("GetRepairableItems")
	if repairBusy or not getItems then return 0 end
	repairBusy = true

	local ok, res = pcall(function() return getItems:InvokeServer() end)
	local list = ok and type(res) == "table" and res.items or {}
	if #list == 0 then
		repairBusy = false
		return 0
	end
	log("Auto Repair: broken items", #list)

	local _, fixed = wrenchRepairPass(list)
	log("Auto Repair pass done, repaired with the wrench:", fixed)
	repairBusy = false
	return fixed
end
-- After a win: go straight to the shop (seated). Leaving the garage ends the pickup (AuctionPickupEnd) and the server
-- moves the won items into Lost & Found ("You left 6 items behind!"). Claiming them from there puts them directly
-- into the vehicle, ready to be unloaded, shelved and sold.
collectLostFoundRef = collectLostFound

-- Scan the won garage for anything still lying in it: counts what is there and fires every non-entry prompt (pick up / take / loot).
-- Returns how many prompts were fired. The structure of the garage isn't known, so the scan logs a summary to learn from.
local function scanGarage(g)
	if not (g and g.Parent) then log("garage scan: garage already gone") return 0 end
	local classes, prompts, children = {}, {}, {}
	for _, c in ipairs(g:GetChildren()) do children[#children + 1] = c.Name .. "(" .. c.ClassName .. ")" end
	for _, d in ipairs(g:GetDescendants()) do
		classes[d.ClassName] = (classes[d.ClassName] or 0) + 1
		if d:IsA("ProximityPrompt") and d.Enabled then
			local label = (d.Name .. " " .. d.ActionText .. " " .. d.ObjectText):lower()
			if not label:find("enter", 1, true) and not label:find("auction", 1, true) then prompts[#prompts + 1] = d end
		end
	end
	local summary = {}
	for k, n in pairs(classes) do if n > 1 and k ~= "Part" and k ~= "MeshPart" then summary[#summary + 1] = k .. "=" .. n end end
	table.sort(summary)
	log("garage scan:", g.Name, "| children:", table.concat(children, ", "), "| descendants:", table.concat(summary, " "), "| collectable prompts:", #prompts)
	local fired = 0
	for _, p in ipairs(prompts) do
		if not (p.Parent and State.Running) then break end
		local holder = p.Parent
		local pos = holder:IsA("BasePart") and holder.Position or (holder:IsA("Attachment") and holder.WorldPosition)
		if pos then moveCharacter(CFrame.new(pos + Vector3.new(0, 3, 0))) task.wait(0.2) end
		pcall(fireproximityprompt, p)
		fired = fired + 1
		log("garage scan: fired", p:GetFullName(), "|", p.ActionText, p.ObjectText)
		task.wait(0.3)
	end
	return fired
end

deliverWinnings = function(expected)
	expected = (expected or 0) + (State.OwedItems or 0) -- items still owed from an earlier auction count too
	local active = function() return State.Running or State.AutoCollect end
	local plot = myPlot()
	local spot = plot and plotSpot(plot)
	local vehicle = findVehicle()
	if not (vehicle and spot) then log("deliverWinnings: plot or vehicle not found") return end

	-- 0) see what is still lying in the garage and grab it before leaving
	local okScan, errScan = pcall(scanGarage, A.endedGarage or A.currentGarage)
	if not okScan then log("garage scan error:", errScan) end

	-- 1) back into the vehicle and off to the shop
	setStatus("Heading to the shop")
	ensureSeated(vehicle)
	moveVehicle(vehicle, spot)
	log("deliverWinnings: vehicle in the unpack zone, waiting for AuctionPickupEnd")

	local t = os.clock()
	while active() and not A.pickupEnded and os.clock() - t < 15 do task.wait(0.25) end
	log("AuctionPickupEnd after delivery:", A.pickupEnded, ("(%.1fs)"):format(os.clock() - t))

	-- 2) collect the left-behind items from Lost & Found (they are added to the vehicle); retry while they trickle in
	-- The server only moves the items into Lost & Found once the pickup ends, which can lag (or wait for the next auction entry),
	-- so keep polling until the full count is in the vehicle instead of giving up after one empty pass.
	local tw = os.clock()
	local got = vehicleItemCount() or 0
	local startGot = got
	local claimed = 0
	local window = A.pickupEnded and 30 or 45
	while active() and got < expected and os.clock() - tw < window do
		local n = collectLostFound(true)
		claimed = claimed + (n or 0)
		task.wait((n or 0) > 0 and 1 or 2)
		got = vehicleItemCount() or 0
		if State.LostVehicleFull then break end -- capacity reached: unload first, the cycle claims the rest afterwards
		if (n or 0) == 0 and A.pickupEnded and claimed + startGot >= expected then break end
	end
	local missing = math.max(0, expected - got)
	State.OwedItems = missing
	if missing > 0 then
		log("deliverWinnings: STILL MISSING", missing, "of", expected, "items - they are collected from Lost & Found at the start of the next cycle")
	end
	log("deliverWinnings: vehicle holds", got, "items, expected", expected, "| claimed from Lost & Found:", claimed, ("(%.1fs)"):format(os.clock() - tw))
end
--------------------------------------------------------------------------------
-- Auto Locksmith: safes in the inventory/vehicle -> locksmith slots -> open when done -> claim the reward
-- Events.Locksmith: GetLockableItems() -> {items = {{guid, source, vehicleGUID, data}}}, GetSlotState() -> {unlockedCount, slots},
--   StartLocksmith(slot, guid, source, vehicleGUID), OpenSafe(slot) -> {success, reward...}, ClaimItem(slot) -> {success, error}
--------------------------------------------------------------------------------
local shopPosCache = {}
-- the shops aren't named in the dumps, so look for a prompt/part whose name or text contains the keyword
local function locateShop(keyword)
	if shopPosCache[keyword] then return shopPosCache[keyword] end
	local found
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("ProximityPrompt") then
			local text = (d.ActionText .. " " .. d.ObjectText .. " " .. d.Name):lower()
			local p, depth = d.Parent, 0
			while p and p ~= workspace and depth < 4 do
				text = text .. " " .. p.Name:lower()
				p, depth = p.Parent, depth + 1
			end
			if text:find(keyword, 1, true) then
				local holder = d.Parent
				found = holder and holder:IsA("BasePart") and holder.Position
					or (holder and holder:IsA("Attachment") and holder.WorldPosition)
					or (holder and holder:IsA("Model") and holder:GetPivot().Position)
				if found then break end
			end
		end
	end
	if not found then
		for _, d in ipairs(workspace:GetDescendants()) do
			if (d:IsA("Model") or d:IsA("BasePart")) and d.Name:lower():find(keyword, 1, true) then
				found = d:IsA("Model") and d:GetPivot().Position or d.Position
				break
			end
		end
	end
	if found then
		shopPosCache[keyword] = found
		log("shop '" .. keyword .. "' located at", found)
	else
		log("shop '" .. keyword .. "' not found in the workspace")
	end
	return found
end

local function lockSlotPhase(slot)
	if not slot then return "empty" end
	if slot.RewardItemId or (slot.RewardDiamonds and slot.RewardDiamonds > 0) or (slot.RewardGoldNuggets and slot.RewardGoldNuggets > 0) then
		return "revealed"
	end
	local remaining = (slot.StartTime or 0) + (slot.Duration or 0) - workspace:GetServerTimeNow()
	return remaining <= 0 and "complete" or "cracking"
end

local locksmithBusy = false
-- returns the number of actions done (started + opened + claimed)
local function autoLocksmith()
	local LS = Events:FindFirstChild("Locksmith")
	local getItems, getState = LS and LS:FindFirstChild("GetLockableItems"), LS and LS:FindFirstChild("GetSlotState")
	local startR, openR, claimR = LS and LS:FindFirstChild("StartLocksmith"), LS and LS:FindFirstChild("OpenSafe"), LS and LS:FindFirstChild("ClaimItem")
	if locksmithBusy or not (getItems and getState and startR and openR and claimR) then return 0 end
	locksmithBusy = true

	local ok1, itemsRes = pcall(function() return getItems:InvokeServer() end)
	local ok2, stateRes = pcall(function() return getState:InvokeServer() end)
	local list = ok1 and type(itemsRes) == "table" and itemsRes.items or {}
	local slots = ok2 and type(stateRes) == "table" and stateRes.slots or {}
	local unlocked = ok2 and type(stateRes) == "table" and (stateRes.unlockedCount or 1) or 1

	local ready, free = 0, 0
	for i = 1, unlocked do
		local ph = lockSlotPhase(slots[tostring(i)])
		if ph == "complete" or ph == "revealed" then ready = ready + 1 end
		if ph == "empty" then free = free + 1 end
	end
	local startable = math.min(#list, free)
	log("Auto Locksmith: safes", #list, "| slots unlocked", unlocked, "free", free, "ready", ready, "| query ok", ok1 and ok2)

	if startable == 0 and ready == 0 then
		locksmithBusy = false
		return 0
	end

	-- go to the locksmith shop on foot, do the work, then come back
	local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
	local home = hrp and hrp.CFrame
	local wasSeated = getHumanoid() and getHumanoid().SeatPart
	local shop = locateShop("locksmith")
	if shop then
		setStatus("Going to the locksmith")
		leaveVehicle()
		moveCharacter(CFrame.new(shop + Vector3.new(0, 3, 4)))
		task.wait(0.8)
	end

	local done, inventoryFull = 0, false
	setStatus("Locksmith: opening safes")
	for i = 1, unlocked do
		local slot = slots[tostring(i)]
		local ph = lockSlotPhase(slot)
		if ph == "complete" then
			local ok, r = pcall(function() return openR:InvokeServer(i) end)
			log("OpenSafe", i, "->", ok, ok and type(r) == "table" and (r.success and ("ok reward item " .. tostring(r.rewardItemId) .. " diamonds " .. tostring(r.rewardDiamonds)) or r.error) or r)
			if ok and type(r) == "table" and r.success then ph = "revealed"; done = done + 1 end
			task.wait(0.4)
		end
		if ph == "revealed" and not inventoryFull then
			local ok, r = pcall(function() return claimR:InvokeServer(i) end)
			log("ClaimItem", i, "->", ok, ok and type(r) == "table" and (r.success and "ok" or r.error) or r)
			if ok and type(r) == "table" and r.success then
				slots[tostring(i)] = nil
				done = done + 1
			elseif ok and type(r) == "table" and r.error == "Inventory full" then
				inventoryFull = true
				log("Auto Locksmith: inventory full - will claim after selling something")
			end
			task.wait(0.4)
		end
	end

	-- put the remaining safes into free slots
	local idx = 1
	for i = 1, unlocked do
		if lockSlotPhase(slots[tostring(i)]) == "empty" and list[idx] then
			local it = list[idx]
			idx = idx + 1
			local ok, r = pcall(function() return startR:InvokeServer(i, it.guid, it.source, it.vehicleGUID) end)
			log("StartLocksmith slot", i, "safe", it.guid, "source", it.source, "->", ok, ok and type(r) == "table" and (r.success and "ok" or r.error) or r)
			if ok and type(r) == "table" and r.success then done = done + 1 end
			task.wait(0.5)
		end
	end

	if home then moveCharacter(home) end
	if wasSeated then
		local v = findVehicle()
		if v then ensureSeated(v) end
	end
	log("Auto Locksmith pass done, actions:", done)
	locksmithBusy = false
	return done
end

--------------------------------------------------------------------------------
-- Auto Wash: dirty items -> wash shop slots -> collect -> claim (same shape as the locksmith)
-- Known from the spy: Events.Wash.GetWashableItems() and Events.Wash.StartWash(slot, itemGuid, "Inventory", nil).
-- The collect / claim remotes aren't known yet, so they are found by name (collect*/claim*) and every answer is logged.
--------------------------------------------------------------------------------
local washBusy = false

local function washRemote(...)
	local w = Events:FindFirstChild("Wash")
	if not w then return nil end
	for _, name in ipairs({ ... }) do
		local r = w:FindFirstChild(name)
		if r then return r end
	end
	return nil
end

-- first remote in Events.Wash whose lower-case name contains one of the words
local function washRemoteLike(words)
	local w = Events:FindFirstChild("Wash")
	if not w then return nil end
	for _, word in ipairs(words) do
		for _, c in ipairs(w:GetChildren()) do
			if c:IsA("RemoteFunction") and c.Name:lower():find(word, 1, true) then return c end
		end
	end
	return nil
end

local function washItemList(res)
	local list = {}
	if type(res) ~= "table" then return list end
	local src = type(res.items) == "table" and res.items or res
	for _, v in pairs(src) do
		if type(v) == "table" and v.guid then list[#list + 1] = v end
	end
	return list
end

-- returns the number of actions done (started + collected + claimed)
local function autoWash()
	local getItems = washRemote("GetWashableItems")
	local startR = washRemote("StartWash")
	if washBusy or not (getItems and startR) then return 0 end
	washBusy = true

	local getState = washRemote("GetSlotState")
	local collectR = washRemoteLike({ "collect", "finish", "complete" })
	local claimR = washRemoteLike({ "claim", "take", "pickup" })

	local function query()
		local ok1, items = pcall(function() return getItems:InvokeServer() end)
		local list = ok1 and washItemList(items) or {}
		local slots, unlocked = {}, 1
		if getState then
			local ok2, st = pcall(function() return getState:InvokeServer() end)
			if ok2 and type(st) == "table" then
				slots = st.slots or {}
				unlocked = st.unlockedCount or 1
			end
		end
		return list, slots, unlocked
	end

	local list, slots, unlocked = query()
	local pending = {}
	for _, it in ipairs(list) do
		if not (unwashable[it.guid] and unwashable[it.guid] > os.clock()) then pending[#pending + 1] = it end
	end
	local function phase(slot)
		if not slot then return "empty" end
		local remaining = (slot.StartTime or 0) + (slot.Duration or 0) - workspace:GetServerTimeNow()
		return remaining <= 0 and "done" or "washing"
	end
	local free, ready = 0, 0
	for i = 1, unlocked do
		local ph = phase(slots[tostring(i)])
		if ph == "empty" then free = free + 1 elseif ph == "done" then ready = ready + 1 end
	end
	-- nothing dirty, nothing finished: the wash is all done - proceed (and don't repeat the idle line every pass)
	if math.min(#pending, free) == 0 and ready == 0 then
		if State.WashIdleLogged ~= true then
			State.WashIdleLogged = true
			log("Auto Wash: nothing to wash (dirty items", #list, "| slots unlocked", unlocked, "free", free, "finished", ready, ") - continuing")
		end
		washBusy = false
		return 0
	end
	State.WashIdleLogged = false
	log("Auto Wash: dirty items", #list, "(to wash:", #pending .. ") | slots unlocked", unlocked, "free", free, "finished", ready,
		"| remotes:", collectR and collectR.Name or "no collect", "/", claimR and claimR.Name or "no claim", "/", getState and "GetSlotState" or "no GetSlotState")

	local done = 0
	local function collectAndClaim()
		local refused = false
		for i = 1, unlocked do
			if phase(slots[tostring(i)]) == "done" then
				State.WashCollected = State.WashCollected or {}
				local key = tostring(slots[tostring(i)] and slots[tostring(i)].StartTime or i)
				if collectR and not State.WashCollected[key] then
					local ok, r = pcall(function() return collectR:InvokeServer(i) end)
					log("Wash", collectR.Name, i, "->", ok, dumpValue(r, 2))
					if ok and type(r) == "table" and r.success then
						done = done + 1
						State.WashCollected[key] = true
					elseif not (type(r) == "table" and tostring(r.error):lower():find("fast", 1, true)) then
						refused = true
					end
					task.wait(2)
				end
				if claimR then
					for attempt = 1, 4 do
						local ok, r = pcall(function() return claimR:InvokeServer(i) end)
						log("Wash", claimR.Name, i, "->", ok, dumpValue(r, 2))
						if ok and type(r) == "table" and r.success then
							slots[tostring(i)] = nil
							done = done + 1
							break
						end
						local err = ok and type(r) == "table" and tostring(r.error):lower() or ""
						if err:find("fast", 1, true) then
							task.wait(2 + attempt) -- rate limited: back off, not a distance problem
						else
							refused = true
							break
						end
					end
					task.wait(0.5)
				end
			end
		end
		return refused
	end

	-- secondTry = we are already at the wash shop, so a refusal is final
	local function fill(items, secondTry)
		local retry, idx = {}, 1
		for i = 1, unlocked do
			if phase(slots[tostring(i)]) == "empty" then
				while items[idx] do
					local it = items[idx]
					idx = idx + 1
					local ok, r = pcall(function() return startR:InvokeServer(i, it.guid, it.source or "Inventory", it.vehicleGUID) end)
					if ok and type(r) == "table" and r.success then
						log("StartWash slot", i, "item", it.guid, "-> started")
						slots[tostring(i)] = r.slotData or { StartTime = workspace:GetServerTimeNow(), Duration = 60 }
						done = done + 1
						task.wait(0.4)
						break
					end
					local err = ok and type(r) == "table" and (r.error or "failed") or tostring(r)
					log("StartWash slot", i, "item", it.guid, "refused:", err, "|", dumpValue(r, 2))
					if secondTry or tostring(err):lower():find("wrench", 1, true) then
						unwashable[it.guid] = os.clock() + (CFG.BadCooldown or 600)
						log("this item can't be washed right now - it will be shelved as it is")
					else
						retry[#retry + 1] = it
					end
					task.wait(0.4)
				end
			end
		end
		return retry
	end

	setStatus("Washing items")
	local refusedSlots = collectAndClaim()
	local retryItems = fill(pending, false)

	if refusedSlots or #retryItems > 0 then
		local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
		local home = hrp and hrp.CFrame
		local wasSeated = getHumanoid() and getHumanoid().SeatPart
		local shop = locateShop("wash")
		if shop then
			log("Auto Wash: refused from here - going to the wash shop")
			setStatus("Going to the wash shop")
			leaveVehicle()
			moveCharacter(CFrame.new(shop + Vector3.new(0, 3, 4)))
			task.wait(0.8)
			local _, slots2, unlocked2 = query()
			slots, unlocked = slots2, unlocked2
			if refusedSlots then collectAndClaim() end
			if #retryItems > 0 then fill(retryItems, true) end
			if home then moveCharacter(home) end
			if wasSeated then
				local v = findVehicle()
				if v then ensureSeated(v) end
			end
		else
			log("Auto Wash: the wash shop location is unknown - can't retry there")
			for _, it in ipairs(retryItems) do unwashable[it.guid] = os.clock() + (CFG.BadCooldown or 600) end
		end
	end

	log("Auto Wash pass done, actions:", done)
	washBusy = false
	return done
end
-- Wait (briefly) for a wash that was just started, so the cleaned item is collected before the farm moves on.
-- Returns true as soon as a slot has finished.
local function waitForWashToFinish(maxWait)
	local getState = washRemote("GetSlotState")
	if not getState then return false end
	local t = os.clock()
	while (State.Running or State.AutoWash) and os.clock() - t < maxWait do
		local ok, st = pcall(function() return getState:InvokeServer() end)
		local busy, finished = false, false
		if ok and type(st) == "table" then
			for _, sl in pairs(st.slots or {}) do
				local remaining = (sl.StartTime or 0) + (sl.Duration or 0) - workspace:GetServerTimeNow()
				if remaining > 0 then busy = true else finished = true end
			end
		end
		if finished then return true end
		if not busy then return false end
		setStatus("Waiting for the wash to finish")
		task.wait(3)
	end
	return false
end

serviceWhileWaiting = function()
	if not CFG.ServiceWhileWaiting then return 0 end
	local acted = 0
	if CFG.FarmRepair then
		local ok, n = pcall(autoRepair)
		if ok then acted = acted + (n or 0) else log("autoRepair error:", n) repairBusy = false end
	end
	if CFG.FarmWash then
		local ok, n = pcall(autoWash)
		if ok then acted = acted + (n or 0) else log("autoWash error:", n) washBusy = false end
	end
	return acted
end
-- Auto Unload: if the vehicle holds items, park it in the UnpackZone (if it isn't already) and transfer everything
local function autoUnload()
	local count = vehicleItemCount()
	if not count or count == 0 then return end
	local vehicle = findVehicle()
	local plot = myPlot()
	local spot = plot and plotSpot(plot)
	if not (vehicle and spot) then log("Auto Unload: vehicle or plot not found") return end
	local here = vehicle:GetPivot().Position
	local flat = Vector3.new(here.X - spot.X, 0, here.Z - spot.Z).Magnitude
	log("Auto Unload:", count, "items in vehicle, distance to unpack zone", ("%.1f"):format(flat))
	setStatus("Auto unloading vehicle")
	ensureSeated(vehicle)
	if flat > 10 then
		moveVehicle(vehicle, spot)
		task.wait(1.5)
	end
	unloadAndStock()
end

-- Background helpers for the toggles (they stay out of the way while the farm is running; the farm calls them itself)
task.spawn(function()
	local lastShelf, lastLost, lastUnload, lastRepair, lastLocksmith = 0, 0, 0, 0, 0
	while true do
		task.wait(0.5)
		if not State.Running then
			-- auto accept NPC offers: best offer accepted, bad ones rejected (same rule as the farm)
			if State.AutoOffers and next(pending) and os.clock() - lastOfferAt >= CFG.OfferSettle then
				pcall(resolveOffers)
			end
			if State.AutoShelf and os.clock() - lastShelf > 6 then
				lastShelf = os.clock()
				pcall(stockShelves)
			end
			if State.AutoUnload and not lostBusy and os.clock() - lastUnload > 6 then
				lastUnload = os.clock()
				local ok, err = pcall(autoUnload)
				if not ok then log("autoUnload error:", err) end
			end
			if State.AutoRepair and not lostBusy and os.clock() - lastRepair > 12 then
				lastRepair = os.clock()
				local ok, err = pcall(autoRepair)
				if not ok then log("autoRepair error:", err) repairBusy = false end
			end
			if State.AutoLocksmith and not lostBusy and os.clock() - lastLocksmith > 12 then
				lastLocksmith = os.clock()
				local ok, err = pcall(autoLocksmith)
				if not ok then log("autoLocksmith error:", err) locksmithBusy = false end
			end
			if State.AutoLost and os.clock() - lastLost > 15 then
				lastLost = os.clock()
				local ok, err = pcall(collectLostFound)
				if not ok then log("collectLostFound error:", err) end
			end
		end
	end
end)

--------------------------------------------------------------------------------
-- Wrench shop: buy (and equip) the best wrench you can afford right now
-- Events.WrenchShop: GetState() -> {equipped, owned = {toolId = true}, netWorth}, BuyWrench(toolId), EquipWrench(toolId)
-- Modules.Wrench.Tools[toolId] = {tier, cashPrice, minNetWorth, displayName, ...}
--------------------------------------------------------------------------------
local wrenchBusy = false
local function buyBestWrench(reserve)
	if wrenchBusy then return false end
	wrenchBusy = true

	local okMod, Wrench = pcall(require, R.Mods:WaitForChild("Wrench", 5))
	local shop = Events:FindFirstChild("WrenchShop")
	local getState = shop and shop:FindFirstChild("GetState")
	local buyR = shop and shop:FindFirstChild("BuyWrench")
	local equipR = shop and shop:FindFirstChild("EquipWrench")
	if not (okMod and type(Wrench) == "table" and type(Wrench.Tools) == "table" and getState and buyR and equipR) then
		log("Wrench shop: module or remotes not found")
		wrenchBusy = false
		return false
	end

	local okS, st = pcall(function() return getState:InvokeServer() end)
	if not okS or type(st) ~= "table" then
		log("Wrench shop: GetState failed", okS, st)
		wrenchBusy = false
		return false
	end

	local owned = st.owned or {}
	local netWorth = tonumber(st.netWorth) or 0
	local cash = (LP:GetAttribute("Cash") or 0) - (reserve or CFG.WrenchCashReserve or 0)

	-- tier of the best wrench already owned
	local bestOwnedTier = 0
	for id, tool in pairs(Wrench.Tools) do
		if type(tool) == "table" and type(tool.tier) == "number" and owned[id] then
			bestOwnedTier = math.max(bestOwnedTier, tool.tier)
		end
	end

	-- highest tier we can buy for cash right now, plus the next upgrade we can't afford yet (for the log)
	local best, nextUp
	for id, tool in pairs(Wrench.Tools) do
		if type(tool) == "table" and type(tool.tier) == "number" and not owned[id] and tool.tier > bestOwnedTier then
			local price = math.floor(tonumber(tool.cashPrice) or 0)
			local need = math.floor(tonumber(tool.minNetWorth) or 0)
			if price > 0 then
				if price <= cash and netWorth >= need then
					if not best or tool.tier > best.tool.tier then best = { id = id, tool = tool, price = price } end
				elseif not nextUp or tool.tier < nextUp.tool.tier then
					nextUp = { id = id, tool = tool, price = price, need = need }
				end
			end
		end
	end

	if not best then
		if nextUp then
			log("Wrench shop: nothing affordable. Next upgrade:", nextUp.tool.displayName or nextUp.id, "tier", nextUp.tool.tier,
				"costs", nextUp.price, "(cash", cash, ") needs net worth", nextUp.need, "(you have", netWorth, ")")
			setStatus("No affordable wrench upgrade")
		else
			log("Wrench shop: no better wrench available (best owned tier", bestOwnedTier, ")")
			setStatus("Best wrench already owned")
		end
		wrenchBusy = false
		return false
	end

	local name = best.tool.displayName or best.id
	log("Wrench shop: buying", name, "(tier", best.tool.tier, ") for", best.price, "| cash", cash, "| owned best tier", bestOwnedTier)
	setStatus("Buying wrench: " .. name)
	local okB, r = pcall(function() return buyR:InvokeServer(best.id) end)
	if not (okB and type(r) == "table" and r.success) then
		log("Wrench shop: purchase failed:", okB and type(r) == "table" and (r.error or "unknown") or r)
		setStatus("Wrench purchase failed")
		wrenchBusy = false
		return false
	end

	local okE, e = pcall(function() return equipR:InvokeServer(best.id) end)
	log("Wrench shop: bought", name, "| equip ->", okE, okE and type(e) == "table" and (e.success and "ok" or e.error) or e)
	setStatus("Bought wrench: " .. name)
	wrenchBusy = false
	return true
end

--------------------------------------------------------------------------------
-- Shop upgrades (paid in DIAMONDS): buy every upgrade that is unlocked and affordable, cheapest first
-- Events.Upgrades: GetUpgrades() -> {upgradeId = level}, BuyUpgrade(upgradeId) -> {success, level, error}
-- Modules.ShopUpgradesConfig: Upgrades, GetShopTiers(upgrade), GetFloorLimitUpgrade(levels)
--------------------------------------------------------------------------------
local upgradesBusy = false
local function upgradeShop(reserve)
	if upgradesBusy then return 0 end
	upgradesBusy = true

	local okC, Cfg = pcall(require, R.Mods:WaitForChild("ShopUpgradesConfig", 5))
	local up = Events:FindFirstChild("Upgrades")
	local getR, buyR = up and up:FindFirstChild("GetUpgrades"), up and up:FindFirstChild("BuyUpgrade")
	if not (okC and type(Cfg) == "table" and getR and buyR) then
		log("Shop upgrades: module or remotes not found")
		upgradesBusy = false
		return 0
	end

	reserve = reserve or CFG.UpgradeDiamondReserve or 0
	local skip = CFG.ShopUpgradeSkip or {}
	local failed, bought = {}, 0

	-- one purchase per pass by default: always the CHEAPEST unlocked upgrade (see the selection below)
	for _ = 1, (CFG.ShopUpgradesPerPass or 1) do
		local okL, levels = pcall(function() return getR:InvokeServer() end)
		if not okL or type(levels) ~= "table" then log("Shop upgrades: GetUpgrades failed", okL, levels) break end

		-- same card list the Shop Upgrades screen builds
		local entries = {}
		local floorEntry = Cfg.GetFloorLimitUpgrade and Cfg.GetFloorLimitUpgrade(levels)
		for _, v in ipairs(Cfg.Upgrades) do
			if v.floorLimit then
				if floorEntry then entries[#entries + 1] = floorEntry floorEntry = nil end
			else
				entries[#entries + 1] = {
					id = v.id, name = v.name, minNetWorth = v.minNetWorth, requiresUpgrade = v.requiresUpgrade,
					tiers = Cfg.GetShopTiers(v), currentTier = math.min(tonumber(levels[v.id]) or 0, v.maxLevel or 0),
				}
			end
		end

		local diamonds = (LP:GetAttribute("Diamonds") or 0) - reserve
		local netWorth = getNetWorth()
		local best
		for _, e in ipairs(entries) do
			local cur = e.currentTier or 0
			local tier = e.tiers and e.tiers[cur + 1]
			local gamepassOwned = e.id == "CelebritySpawns" and LP:GetAttribute("CelebrityCustomers") == true
			if tier and cur < #e.tiers and not gamepassOwned and not skip[e.id] and not failed[tier.upgradeId or e.id] then
				local missing = false
				if e.requiresUpgrade then
					missing = true
					for _, o in ipairs(entries) do
						if o.id == e.requiresUpgrade and (o.currentTier or 0) >= 1 then missing = false end
					end
				end
				local needNW = tonumber(tier.minNetWorth) or tonumber(e.minNetWorth) or 0
				local cost = tonumber(tier.cost) or 0
				if not missing and netWorth >= needNW and cost > 0 and cost <= diamonds then
					if not best or cost < best.cost then best = { entry = e, tier = tier, cost = cost } end
				end
			end
		end

		if not best then
			if bought == 0 then log("Shop upgrades: nothing unlocked and affordable (diamonds", LP:GetAttribute("Diamonds"), "reserve", reserve, ")") end
			break
		end

		local id = best.tier.upgradeId or best.entry.id
		setStatus("Upgrading shop: " .. tostring(best.entry.name or id))
		local okB, r = pcall(function() return buyR:InvokeServer(id) end)
		if okB and type(r) == "table" and r.success then
			bought = bought + 1
			log("Shop upgrades: bought", best.entry.name or id, "tier", (best.entry.currentTier or 0) + 1, "for", best.cost, "diamonds -> level", r.level)
		else
			failed[id] = true
			log("Shop upgrades: buying", id, "failed:", okB and type(r) == "table" and (r.error or "unknown") or r)
		end
		task.wait(0.4)
	end

	upgradesBusy = false
	return bought
end

--------------------------------------------------------------------------------
-- Auto Quest: read the active quests (Modules.QuestSystem:GetActiveQuests() -> {Id, Data = {Title, Tasks = {{Text, Current, Required}}}})
-- and, for unfinished tasks, run the panel feature that matches the task text. Quests complete server-side when the
-- objective is met, so there is no "claim" call. Tasks with no matching feature are logged once so they can be added.
--------------------------------------------------------------------------------
local questLastLine, questUnhandled, questFeatureAt = {}, {}, {}

local function readActiveQuests()
	local okM, QS = pcall(require, R.Mods:WaitForChild("QuestSystem", 5))
	if not okM or type(QS) ~= "table" or type(QS.GetActiveQuests) ~= "function" then return nil end
	local ok, quests = pcall(function() return QS:GetActiveQuests() end)
	if not ok or type(quests) ~= "table" then return nil end
	return quests
end

-- keyword (lower case, plain find) -> { label, action }. Auctions / selling / stocking are covered by Auto Farm itself.
-- Cleaning (read-only for now): Events.Cleaning.GetDirtyItems() -> {items = {{guid, data}}, bottles = {{guid, name, usesLeft, maxUses}}}.
-- StartCleaning(itemGuid, bottleGuid) opens a brushing mini-game session (OpenCleaning / CleaningAction / CleaningResolved) whose
-- client code isn't in the dumps yet, so we only report what there is to clean instead of wasting a bottle.
local function cleaningStatus()
	local folder = Events:FindFirstChild("Cleaning")
	local get = folder and folder:FindFirstChild("GetDirtyItems")
	if not get then log("Cleaning: remotes not found") return 0 end
	local ok, res = pcall(function() return get:InvokeServer() end)
	if not ok or type(res) ~= "table" then log("Cleaning: GetDirtyItems failed", ok, res) return 0 end
	local items, bottles = res.items or {}, res.bottles or {}
	local bl = {}
	for _, b in ipairs(bottles) do bl[#bl + 1] = ("%s %s/%s uses"):format(tostring(b.name), tostring(b.usesLeft), tostring(b.maxUses)) end
	log("Cleaning:", #items, "dirty item(s) |", #bottles, "bottle(s):", #bl > 0 and table.concat(bl, ", ") or "none",
		"- the cleaning mini-game isn't automated yet (needs its client script)")

	-- the Wash Shop is a second cleaning route (Events.Wash.*): list its remotes and what GetWashableItems returns (read-only)
	local wash = Events:FindFirstChild("Wash")
	if wash then
		local names = {}
		for _, c in ipairs(wash:GetChildren()) do names[#names + 1] = c.ClassName .. ":" .. c.Name end
		log("Wash remotes:", #names > 0 and table.concat(names, ", ") or "none")
		local g = wash:FindFirstChild("GetWashableItems")
		if g and g:IsA("RemoteFunction") then
			local okW, resW = pcall(function() return g:InvokeServer() end)
			log("GetWashableItems ->", okW, dumpValue(resW, 3))
		end
	else
		log("no Events.Wash folder found")
	end
	return 0
end

local QUEST_FEATURES = {
	{ words = { "clean", "wash" },                  label = "wash shop",       run = function() cleaningStatus() return autoWash() end },
	{ words = { "repair" },                         label = "wrench repair",   run = function() return autoRepair() end },
	{ words = { "safe", "locksmith", "crack" },     label = "locksmith",       run = function() return autoLocksmith() end },
	{ words = { "wrench" },                         label = "wrench shop",     run = function() return buyBestWrench() and 1 or 0 end },
	{ words = { "upgrade" },                        label = "shop upgrades",    run = function() return upgradeShop(CFG.UpgradeDiamondReserve) end },
	{ words = { "lost", "found" },                  label = "lost & found",    run = function() return collectLostFound(true) end },
}
local FARM_WORDS = { "auction", "bid", "win", "sell", "sold", "customer", "shelf", "stock", "unload", "vehicle", "garage" }

local function questStep()
	local quests = readActiveQuests()
	if not quests then
		if not questLastLine["__nosystem"] then
			questLastLine["__nosystem"] = true
			log("Auto Quest: couldn't read Modules.QuestSystem:GetActiveQuests()")
		end
		return 0
	end

	local acted = 0
	local now = os.clock()
	local wantedArea -- an area named by an unfinished task (steers the auction garage choice, see scrapGarages)
	for _, q in ipairs(quests) do
		local data = q.Data or {}
		local title = tostring(data.Title or q.Id)
		for ti, t in ipairs(data.Tasks or {}) do
			local cur, req = tonumber(t.Current) or 0, tonumber(t.Required) or 1
			local key = tostring(q.Id) .. "#" .. tostring(t.Id or ti)
			local line = ("%s: %s (%s/%s)"):format(title, tostring(t.Text), tostring(cur), tostring(req))
			if questLastLine[key] ~= line then
				questLastLine[key] = line
				log("QUEST", line, cur >= req and "[done]" or "")
			end
			if cur < req then
				local text = (tostring(t.Text) .. " " .. title):lower()
				if not wantedArea and AreasCfg then
					local taskLower = tostring(t.Text):lower()
					for areaName, v in pairs(AreasCfg) do
						if type(v) == "table" and v.GarageIds and taskLower:find(areaName:lower(), 1, true) then
							wantedArea = areaName
							break
						end
					end
				end
				local handled = false
				for _, f in ipairs(QUEST_FEATURES) do
					for _, w in ipairs(f.words) do
						if text:find(w, 1, true) then
							handled = true
							if now - (questFeatureAt[f.label] or -1e9) > 60 then
								questFeatureAt[f.label] = now
								log("Auto Quest: '" .. tostring(t.Text) .. "' -> running", f.label)
								local ok, res = pcall(f.run)
								if not ok then log("Auto Quest:", f.label, "error:", res)
								elseif res and res ~= 0 and res ~= false then acted = acted + 1 end
							end
							break
						end
					end
					if handled then break end
				end
				if not handled then
					local farmTask = false
					for _, w in ipairs(FARM_WORDS) do
						if text:find(w, 1, true) then farmTask = true break end
					end
					if not questUnhandled[key] then
						questUnhandled[key] = true
						log("Auto Quest:", farmTask and "done by Auto Farm itself:" or "no automation for this task yet:", tostring(t.Text))
					end
				end
			end
		end
	end
	if State.QuestArea ~= wantedArea then
		State.QuestArea = wantedArea
		log("Auto Quest: auction garages now prefer the area:", wantedArea or "any (no area-scoped task open)")
	end
	return acted
end

-- Quest rewards are given by the server; the popup (Screens.QuestRewardPopup) is only a "Continue" window. Log what was
-- rewarded and close the popup so a modal doesn't sit over the screen while the farm runs.
do
	local questEvents = Events:FindFirstChild("Quest")
	local rewardEvent = questEvents and questEvents:FindFirstChild("QuestRewardPopup")
	if rewardEvent then
		ctx:Connect(rewardEvent.OnClientEvent, function(data)
			if type(data) ~= "table" then return end
			local parts = {}
			for _, r in ipairs(data.Rewards or {}) do
				if type(r) == "table" then
					parts[#parts + 1] = tostring(r.Kind) .. ":" .. tostring(r.Name or r.Amount or r.Quantity or r.Mutator or r.Power or "")
				end
			end
			log("QUEST REWARD from", tostring(data.Giver or data.QuestName or "?"), "->", #parts > 0 and table.concat(parts, ", ") or "none listed")
			if State.AutoQuest then
				task.spawn(function()
					for _ = 1, 4 do
						task.wait(2)
						pcall(function() require(R.Mods:WaitForChild("UIController")):Close("QuestRewardPopup") end)
					end
				end)
			end
		end)
	end
end

-- Events.Quest.NewQuestAccepted(questName, tasks, flag) is the server confirming a quest was accepted
do
	local questEvents = Events:FindFirstChild("Quest")
	local accepted = questEvents and questEvents:FindFirstChild("NewQuestAccepted")
	if accepted then
		ctx:Connect(accepted.OnClientEvent, function(name, tasks)
			if not (State.AutoQuest or State.Spy) then return end
			local parts = {}
			for _, t in ipairs(type(tasks) == "table" and tasks or {}) do
				parts[#parts + 1] = ("%s [%s] x%s"):format(tostring(t.DisplayName or t.Key), tostring(t.Type), tostring(t.Target))
			end
			log("QUEST ACCEPTED", tostring(name), "-", table.concat(parts, " | "))
		end)
	end
end

-- Quest conversations. Known calls (from Cobalt / the spy):
--   Events.UI.QuestPromptTriggered:InvokeServer(npcModel)  -> the server starts a dialog by firing Events.UI.StartQuestDialog
--   Events.UI.StartQuestDialog  {QuestName, NPCModel, NPCName, Dialog = {{Speaker, Text, Options = {{Text, Response}}}}}
--   Events.UI.SendQuestDialogResult:FireServer(npcModel, questName, response)  -> the answer ("accept", "decline", "collector_stay", ...)
-- Collector NPCs (customers who stand in the shop waiting to be talked to) use the same dialog; mascot quests too.
R.uiEventsQ = Events:FindFirstChild("UI")
R.startDialog = R.uiEventsQ and R.uiEventsQ:FindFirstChild("StartQuestDialog")
R.sendDialogResult = R.uiEventsQ and R.uiEventsQ:FindFirstChild("SendQuestDialogResult")
R.promptTriggered = R.uiEventsQ and R.uiEventsQ:FindFirstChild("QuestPromptTriggered")
local dialogAnsweredAt = {}

-- pick an option: the preferred response if offered, else the first one containing one of the words
local function pickResponse(responses, preferred, words)
	for _, r in ipairs(responses) do if r == preferred then return r end end
	for _, w in ipairs(words or {}) do
		for _, r in ipairs(responses) do
			if tostring(r):lower():find(w, 1, true) then return r end
		end
	end
	return nil
end

local function answerDialog(npc, questName, response)
	if not R.sendDialogResult then return end
	local key = tostring(npc) .. "|" .. tostring(questName) .. "|" .. tostring(response)
	if dialogAnsweredAt[key] and os.clock() - dialogAnsweredAt[key] < 6 then return end
	dialogAnsweredAt[key] = os.clock()
	local ok, err = pcall(function() R.sendDialogResult:FireServer(npc, questName, response) end)
	log("QUEST DIALOG answered:", tostring(response), "for", tostring(questName), ok and "" or ("(error: " .. tostring(err) .. ")"))
end

if R.startDialog then
	ctx:Connect(R.startDialog.OnClientEvent, function(data)
		if type(data) ~= "table" then return end
		local npc = data.NPCModel
		local isCollector = typeof(npc) == "Instance" and npc.Name:lower():find("collector", 1, true) ~= nil
		local lines, opts, responses = {}, {}, {}
		for _, d in ipairs(data.Dialog or {}) do
			if d.Text then lines[#lines + 1] = tostring(d.Text) end
			for _, o in ipairs(d.Options or {}) do
				opts[#opts + 1] = tostring(o.Response) .. "='" .. tostring(o.Text) .. "'"
				responses[#responses + 1] = o.Response
			end
		end

		local farming = State.Running or State.AutoOffers
		if State.AutoQuest or State.Spy or (isCollector and farming) then
			log("QUEST DIALOG", tostring(data.QuestName), "from", tostring(data.NPCName), isCollector and "[collector]" or "", "|", table.concat(lines, " / "), "| options:", table.concat(opts, ", "))
		end

		local choice
		if isCollector then
			if farming then
				-- if we happen to have the item the collector wants, the dialog should offer a hand-over option: take it first
				choice = pickResponse(responses, nil, { "give", "deliver", "hand", "turn", "trade", "sell", "complete", "yes" })
					or pickResponse(responses, CFG.CollectorResponse, { "stay", "dismiss", "decline" })
			end
		elseif State.AutoQuest then
			-- quest offer: accept it; a lone option (reward / "still working on it" dialogs) just closes the dialog
			choice = pickResponse(responses, "accept", {}) or (#responses == 1 and responses[1] or nil)
		end
		if choice then
			task.delay(0.6, function() answerDialog(npc, data.QuestName, choice) end)
		elseif isCollector and farming then
			log("collector dialog has no '" .. tostring(CFG.CollectorResponse) .. "' option - left unanswered; options were:", table.concat(opts, ", "))
		end
	end)
end

-- walk up to each Collector in the shop and trigger its prompt, like a player pressing E on it (once every 90s per collector)
local collectorAt = {}
collectorTick = function()
	if not (State.Running or State.AutoOffers) or not R.promptTriggered then return end
	for _, model in ipairs(shopperScan.collectors or {}) do
		if model.Parent and os.clock() - (collectorAt[model] or -1e9) > 90 then
			collectorAt[model] = os.clock()
			local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
			local pos = model:GetPivot().Position
			if hrp and (hrp.Position - pos).Magnitude > 15 then
				leaveVehicle()
				moveCharacter(CFrame.new(pos + Vector3.new(4, 3, 0)))
				task.wait(0.4)
			end
			local ok, res = pcall(function() return R.promptTriggered:InvokeServer(model) end)
			log("collector", model.Name, "QuestPromptTriggered ->", ok, dumpValue(res, 1))
			task.wait(1.5) -- the StartQuestDialog handler above answers the dialog
		end
	end
end
-- The server's own quest state: Events.Quest.QuestStateSync fires {MascotName = {QuestName, QuestIndex, TaskProgress,
-- RequiredTasks = {{Key, Type, Target, DisplayName, MutationName?}}, CompletedItems}} whenever something changes.
do
	local questEvents = Events:FindFirstChild("Quest")
	local stateSync = questEvents and questEvents:FindFirstChild("QuestStateSync")
	if stateSync then
		State.QuestSync = {}
		ctx:Connect(stateSync.OnClientEvent, function(data)
			if type(data) ~= "table" then return end
			for npcName, q in pairs(data) do
				if type(q) == "table" then
					State.QuestSync[npcName] = q
					if State.AutoQuest or State.Spy then
						local parts = {}
						for _, t in ipairs(q.RequiredTasks or {}) do
							local prog = type(q.TaskProgress) == "table" and q.TaskProgress[t.Key] or 0
							parts[#parts + 1] = ("%s [%s] %s/%s"):format(tostring(t.DisplayName or t.Key), tostring(t.Type), tostring(prog), tostring(t.Target))
						end
						log("QUEST STATE", npcName, "-", tostring(q.QuestName), "(level " .. tostring(q.QuestIndex) .. "):", table.concat(parts, " | "))
					end
				end
			end
		end)
	end
end

-- background loop for when Auto Farm is off (when it's on, the farm calls questStep itself between auctions)
task.spawn(function()
	while true do
		task.wait(20)
		if State.AutoQuest and not State.Running then
			local ok, err = pcall(questStep)
			if not ok then log("questStep error:", err) end
		end
	end
end)

--------------------------------------------------------------------------------
-- Shop teleports. Shop screens come from the UI list in UIInit (VehicleDealership, TrailerShop, GradingShop, RepairShop, WashShop,
-- LocksmithShop, LockpickShop, WrenchShop, TimeCapsule, PawnShop, EnergyShop, AlienMarket, WildWestMarket, HalloweenMarket,
-- MutationExtractor, GradeRemover, CleaningShop, TravellingMerchant, MixingCauldron, Authentication, CharmForge, Museum).
-- Their world positions aren't in the dumps, so one pass over the workspace looks for prompts / models whose name or text
-- contains one of the keywords.
--------------------------------------------------------------------------------
local SHOPS = {
	{ "Vehicle Dealership", { "dealership", "car dealer", "vehicle shop" } },
	{ "Trailer Shop",       { "trailer" } },
	{ "Grading Shop",       { "grading" } },
	{ "Repair Shop",        { "repair" } },
	{ "Wash Shop",          { "wash" } },
	{ "Cleaning Shop",      { "cleaning" } },
	{ "Locksmith",          { "locksmith" } },
	{ "Lockpick Shop",      { "lockpick" } },
	{ "Wrench Shop",        { "wrench" } },
	{ "Time Capsule",       { "time capsule", "timecapsule" } },
	{ "Pawn Shop",          { "pawn" } },
	{ "Energy Shop",        { "energy" } },
	{ "Alien Market",       { "alien market", "alienmarket" } },
	{ "Wild West Market",   { "wild west market", "wildwestmarket" } },
	{ "Halloween Market",   { "halloween market", "halloweenmarket" } },
	{ "Mutation Extractor", { "extractor" } },
	{ "Grade Remover",      { "grade remover", "graderemover" } },
	{ "Travelling Merchant", { "merchant" } },
	{ "Mixing Cauldron",    { "cauldron" } },
	{ "Authenticator",      { "authentic" } },
	{ "Charm Forge",        { "charm" } },
	{ "Museum",             { "museum" } },
	{ "Lost & Found",       { "lost and found" } },
}

local shopPositions = {}   -- label -> Vector3 (nil = not found)
local shopScanBusy = false

local function posOf(inst)
	if inst:IsA("BasePart") then return inst.Position end
	if inst:IsA("Attachment") then return inst.WorldPosition end
	if inst:IsA("Model") then return inst:GetPivot().Position end
	return nil
end

local function scanAllShops()
	if shopScanBusy then return end
	shopScanBusy = true
	local byPrompt, byModel, n = {}, {}, 0
	for _, d in ipairs(workspace:GetDescendants()) do
		n = n + 1
		if n % 3000 == 0 then task.wait() end
		local text, isPrompt
		if d:IsA("ProximityPrompt") then
			text = (d.ActionText .. " " .. d.ObjectText .. " " .. d.Name):lower()
			local p, depth = d.Parent, 0
			while p and p ~= workspace and depth < 4 do
				text = text .. " " .. p.Name:lower()
				p, depth = p.Parent, depth + 1
			end
			isPrompt = true
		elseif d:IsA("Model") and not d:FindFirstChildOfClass("Humanoid") then
			text = d.Name:lower()
		end
		if text then
			for _, shop in ipairs(SHOPS) do
				local label = shop[1]
				local table_ = isPrompt and byPrompt or byModel
				if not table_[label] then
					for _, kw in ipairs(shop[2]) do
						if text:find(kw, 1, true) then
							local pos = posOf(isPrompt and d.Parent or d)
							if pos then table_[label] = pos end
							break
						end
					end
				end
			end
		end
	end
	local foundCount = 0
	for _, shop in ipairs(SHOPS) do
		shopPositions[shop[1]] = byPrompt[shop[1]] or byModel[shop[1]]
		if shopPositions[shop[1]] then foundCount = foundCount + 1 end
	end
	log("shop scan:", foundCount, "of", #SHOPS, "shops located")
	shopScanBusy = false
end

local function tpToShop(label)
	if State.Running then log("shop teleport ignored: turn Auto Farm off first") return end
	local pos = shopPositions[label]
	if not pos then log("shop '" .. label .. "' hasn't been located in the world") return end
	log("teleporting to", label, pos)
	leaveVehicle()
	moveCharacter(CFrame.new(pos + Vector3.new(0, 3, 4)))
end

-- Area teleports: every area in Modules.Areas that exists under workspace.Areas (mascot first, then its Lost & Found box, then the area itself)
local function areaNames()
	local out = {}
	local folder = workspace:FindFirstChild("Areas")
	if AreasCfg then
		for name, v in pairs(AreasCfg) do
			if type(v) == "table" and v.GarageIds and folder and folder:FindFirstChild(name) then out[#out + 1] = name end
		end
	end
	table.sort(out)
	return out
end

local function tpToArea(name)
	if State.Running then log("area teleport ignored: turn Auto Farm off first") return end
	local folder = workspace:FindFirstChild("Areas")
	local area = folder and folder:FindFirstChild(name)
	if not area then log("area '" .. name .. "' not found in workspace.Areas") return end
	local mascot = AreasCfg and AreasCfg[name] and AreasCfg[name].Mascot
	local target = (mascot and area:FindFirstChild(mascot)) or area:FindFirstChild("Lost and Found Box") or area
	local ok, pos = pcall(function() return target:GetPivot().Position end)
	if not ok then log("area '" .. name .. "' has no position") return end
	log("teleporting to area", name, pos)
	leaveVehicle()
	moveCharacter(CFrame.new(pos + Vector3.new(0, 4, 5)))
end

-- Auto Fishing (Modules.InteractiveItemsClient.FishingRodClient): equip the rod, cast at the nearest water, and answer the reel
-- minigame. Events.Misc: FishingCast:FireServer(waterPart, hitPos) -> FishingState "cast" {castId} -> "reel" {difficulty, rarity, ...}
-- -> the client minigame reports FishingResult:FireServer("caught" | "escaped") -> FishingState "done" {reason, itemName, ...}.
-- The minigame is client-side, so a successful result is reported after the time it takes to fill the meter.
do
	local Misc = Events:FindFirstChild("Misc")
	local castR = Misc and Misc:FindFirstChild("FishingCast")
	local stateR = Misc and Misc:FindFirstChild("FishingState")
	local resultR = Misc and Misc:FindFirstChild("FishingResult")
	local cancelR = Misc and Misc:FindFirstChild("FishingCancel")
	if castR and stateR and resultR then
		local fs = { phase = "idle", at = os.clock(), fails = 0 }
		ctx:Connect(stateR.OnClientEvent, function(kind, data)
			if kind == "cast" then
				fs.phase, fs.at, fs.fails = "waiting", os.clock(), 0 -- the server accepted the cast
			elseif kind == "reel" then
				fs.phase, fs.at = "reel", os.clock()
				if State.AutoFish then log("fishing: a fish bit", type(data) == "table" and data.rarity or "") end
			elseif kind == "done" then
				fs.phase, fs.at = "idle", os.clock()
				if State.AutoFish and type(data) == "table" then
					log("fishing:", data.reason or "done", data.itemName or "", data.rarity or "")
					if data.reason == "caught" and CFG.FishPlace then
						fs.catches = (fs.catches or 0) + 1
						if fs.catches >= (CFG.FishPlaceEvery or 1) then
							fs.catches = 0
							task.spawn(function() task.wait(1) stockShelves() end)
						end
					end
				end
			end
		end)

		local waters, scannedAt = {}, -1e9
		local function scanWater()
			waters, scannedAt = {}, os.clock()
			local n = 0
			for _, d in ipairs(workspace:GetDescendants()) do
				n = n + 1
				if n % 4000 == 0 then task.wait() end
				if d:IsA("BasePart") and d.Name:lower() == "water" then waters[#waters + 1] = d end
			end
			log("fishing: found", #waters, "water part(s)")
		end

		-- nearest point on a water part's top surface
		local function surfacePoint(part, from)
			local rel = part.CFrame:PointToObjectSpace(from)
			local h = part.Size / 2
			return part.CFrame:PointToWorldSpace(Vector3.new(math.clamp(rel.X, -h.X, h.X), h.Y, math.clamp(rel.Z, -h.Z, h.Z)))
		end

		local function nearestWater(from)
			local best, bestPos, bestD
			for _, w in ipairs(waters) do
				if w.Parent then
					local p = surfacePoint(w, from)
					local d = (p - from).Magnitude
					if not bestD or d < bestD then best, bestPos, bestD = w, p, d end
				end
			end
			return best, bestPos, bestD
		end

		-- "TP to Pond": the water closest to your shop (so it is always the same spot), standing a few studs from its edge
		function A.tpPond()
			if State.Running then log("TP to Pond ignored: turn Auto Farm off first") return end
			if os.clock() - scannedAt > 60 or #waters == 0 then scanWater() end
			local plot = myPlot()
			local spot = plot and plotSpot(plot)
			local from = spot and spot.Position or (LP.Character and LP.Character:GetPivot().Position)
			local water, pos = nearestWater(from)
			if not water then log("TP to Pond: no water found") return end
			local dir = (from - pos) * Vector3.new(1, 0, 1)
			dir = dir.Magnitude > 1 and dir.Unit or Vector3.new(0, 0, 1)
			leaveVehicle()
			moveCharacter(CFrame.new(pos + dir * 10 + Vector3.new(0, 4, 0)))
		end

		local function findRod()
			local char = LP.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			for _, container in ipairs({ char, LP:FindFirstChildOfClass("Backpack") }) do
				if container then
					for _, t in ipairs(container:GetChildren()) do
						if t:IsA("Tool") then
							local n = t.Name:lower()
							if n:find("rod", 1, true) or n:find("fishing", 1, true) then return t, hum end
						end
					end
				end
			end
			return nil, hum
		end

		local lastCast, lastNote = 0, 0
		-- a broken rod can't cast: repair it with the wrench (the rod is an inventory item, so Repair.GetRepairableItems lists it)
		local lastRodCheck = -1e9
		local function repairRod(rod, hum)
			local getItems = repairRemote("GetRepairableItems")
			if not getItems or os.clock() - lastRodCheck < 20 then return false end
			lastRodCheck = os.clock()
			local ok, res = pcall(function() return getItems:InvokeServer() end)
			local list = ok and type(res) == "table" and res.items or {}
			local guid = rod:GetAttribute("EquippedGuid")
			local mine = {}
			for _, it in ipairs(list) do
				local nm = tostring(it.name or it.Name or ""):lower()
				if (guid and it.guid == guid) or nm:find("rod", 1, true) or nm:find("fishing", 1, true) then mine[#mine + 1] = it end
			end
			if #mine == 0 then return false end
			log("fishing: the rod is broken - repairing it with the wrench", dumpValue(mine[1], 2))
			if hum and rod.Parent == LP.Character then hum:UnequipTools() task.wait(0.4) end
			setStatus("Fishing: repairing the rod")
			local _, fixed = wrenchRepairPass(mine)
			return fixed > 0
		end
		local function note(msg)
			if os.clock() - lastNote > 15 then lastNote = os.clock() log("fishing:", msg) end
		end

		task.spawn(function()
			while true do
				task.wait(0.4)
				if not State.AutoFish then
					fs.phase = "idle"
				elseif State.Running then
					note("paused while Auto Farm is running")
				else
					local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
					if hrp then
						if fs.phase == "idle" and os.clock() - lastCast > 1.2 then
							local rod, hum = findRod()
							if not rod then
								note("no fishing rod found in the backpack (a tool named like 'rod')")
							else
								if rod.Parent ~= LP.Character and hum then
									hum:EquipTool(rod)
									task.wait(0.6)
								end
								if repairRod(rod, hum) then task.wait(0.5) rod, hum = findRod() end
								if os.clock() - scannedAt > 60 then scanWater() end
								local water, pos, dist = nearestWater(hrp.Position)
								if water and dist >= 200 and CFG.FishWalkToWater then
									-- too far to cast: stand a few studs from the shore (the server only accepts casts within 250 studs)
									local stand = pos + (hrp.Position - pos).Unit * 12 + Vector3.new(0, 4, 0)
									log("fishing: walking to the water,", ("%.0f"):format(dist), "studs away")
									setStatus("Fishing: walking to the water")
									leaveVehicle()
									moveCharacter(CFrame.new(stand))
									task.wait(0.5)
									water, pos, dist = nearestWater(LP.Character.HumanoidRootPart.Position)
								end
								if water and dist < 200 then
									setStatus("Fishing: casting")
									lastCast = os.clock()
									fs.phase, fs.at = "casting", os.clock()
									fs.fails = fs.fails + 1
									log("fishing: cast at", water:GetFullName(), ("(%.0f studs)"):format(dist))
									castR:FireServer(water, pos)
									if fs.fails >= 3 then
										-- the server keeps ignoring direct casts: use the rod's own Activated handler as well
										pcall(function() rod:Activate() end)
									end
								else
									note("no water found within range")
								end
							end
						elseif fs.phase == "casting" and os.clock() - fs.at > 5 then
							fs.phase = "idle" -- the server never confirmed the cast
						elseif fs.phase == "waiting" then
							setStatus("Fishing: waiting for a bite")
							if os.clock() - fs.at > (CFG.FishBiteTimeout or 45) then
								if cancelR then cancelR:FireServer() end
								fs.phase = "idle"
							end
						elseif fs.phase == "reel" then
							setStatus("Fishing: reeling")
							if os.clock() - fs.at >= (CFG.FishReelDelay or 3) then
								resultR:FireServer("caught")
								fs.phase, fs.at = "finishing", os.clock()
							end
						elseif fs.phase == "finishing" and os.clock() - fs.at > 6 then
							fs.phase = "idle"
						end
					end
				end
			end
		end)
	else
		log("fishing remotes (Events.Misc.FishingCast / FishingState / FishingResult) not found - Auto Fish unavailable")
	end
end

-- Auto Consume: drink every drinkable (luck / energy drinks, items with "drink" in their name) found in the inventory.
-- Events.UI.UseEnergyDrink:FireServer(itemGuid) uses one; the server answers with UI.DrinkConsumed {Name, DurationSeconds, ...}.
-- A drink whose effect is still running is not drunk again until it ends.
do
	local ui = Events:FindFirstChild("UI")
	local useR = ui and ui:FindFirstChild("UseEnergyDrink")
	local consumedR = ui and ui:FindFirstChild("DrinkConsumed")
	if useR then
		local activeUntil = {} -- drink name -> os.clock() when its effect ends
		if consumedR then
			ctx:Connect(consumedR.OnClientEvent, function(d)
				if type(d) ~= "table" then return end
				activeUntil[tostring(d.Name)] = os.clock() + (tonumber(d.DurationSeconds) or 0)
				if State.AutoConsume then
					log("consumed", d.Name, "| luck", d.TotalLuckPct, "% for", d.DurationSeconds, "s")
				end
			end)
		end
		task.spawn(function()
			while true do
				task.wait(8)
				if State.AutoConsume then
					local ok, inv = pcall(function() return R.GetInventory:InvokeServer() end)
					if ok and type(inv) == "table" then
						for guid, entry in pairs(inv) do
							if isDrink(entry) and (next(X.DrinksToUse) == nil or X.DrinksToUse[R.Items[tostring(entry.ItemId)].Name]) and A.drinksReady(inv) then
								local name = R.Items[tostring(entry.ItemId)].Name
								if not (activeUntil[name] and activeUntil[name] > os.clock()) then
									log("Auto Consume: drinking", name)
									pcall(function() useR:FireServer(guid) end)
									activeUntil[name] = os.clock() + 5 -- until the server's DrinkConsumed gives the real duration
									task.wait(1.5)
								end
							end
						end
					end
				end
			end
		end)
	else
		log("Events.UI.UseEnergyDrink not found - Auto Consume unavailable")
	end
end

-- Auto Wash toggle when Auto Farm is off (the farm washes by itself between auctions)
task.spawn(function()
	while true do
		task.wait(15)
		if State.AutoWash and not State.Running then
			local ok, err = pcall(autoWash)
			if not ok then log("autoWash error:", err) washBusy = false end
		end
	end
end)
--------------------------------------------------------------------------------
-- Reward claiming.
-- Achievements: Events.Achievements.GetAchievementStatus() -> { [id] = {Status = "locked"|"claimable"|"claimed", Reward, DisplayName, ...} }
--               Events.Achievements.ClaimAchievementReward(id) -> {ok = true, status = "claimed", reward, claimableCount}
-- The Collection Book's "Complete the <area> Index" rewards are achievements too (IndexJunkYard, IndexBackAlley, ...), so they are
-- claimed by the same call. Any other collection-book style remotes are listed once in the log.
--------------------------------------------------------------------------------
local achBusy, collectionListed = false, false

local function listCollectionRemotes()
	if collectionListed then return end
	collectionListed = true
	local names = {}
	for _, d in ipairs(Events:GetDescendants()) do
		if d:IsA("RemoteFunction") or d:IsA("RemoteEvent") then
			local n = d.Name:lower()
			local full = d:GetFullName():lower()
			if n:find("collection", 1, true) or n:find("index", 1, true) or full:find("collectionbook", 1, true) or n:find("book", 1, true) then
				names[#names + 1] = d.ClassName .. ":" .. d:GetFullName():gsub("^.*Events%.", "")
			end
		end
	end
	log("collection book remotes:", #names > 0 and table.concat(names, ", ") or "none found (its rewards are the Index achievements)")
end

-- returns the number of rewards claimed
local function claimRewards()
	local ach = Events:FindFirstChild("Achievements")
	local getR = ach and ach:FindFirstChild("GetAchievementStatus")
	local claimR = ach and ach:FindFirstChild("ClaimAchievementReward")
	if achBusy or not (getR and claimR) then return 0 end
	achBusy = true
	listCollectionRemotes()

	local ok, st = pcall(function() return getR:InvokeServer() end)
	if not ok or type(st) ~= "table" then
		log("achievements: GetAchievementStatus failed", ok, dumpValue(st, 1))
		achBusy = false
		return 0
	end

	local claimable = {}
	for id, a in pairs(st) do
		if type(a) == "table" and a.Status == "claimable" then claimable[#claimable + 1] = id end
	end
	table.sort(claimable)
	if #claimable == 0 then
		achBusy = false
		return 0
	end
	log("achievements: claimable now:", table.concat(claimable, ", "))

	local claimed, total = 0, 0
	for _, id in ipairs(claimable) do
		local ok2, r = pcall(function() return claimR:InvokeServer(id) end)
		local good = ok2 and type(r) == "table" and r.ok == true
		log("claimed achievement", id, "(" .. tostring(st[id].DisplayName) .. ") ->", good and ("+" .. tostring(r.reward) .. " reward") or dumpValue(r, 2))
		if good then
			claimed = claimed + 1
			total = total + (tonumber(r.reward) or 0)
		end
		task.wait(0.4)
	end
	log("achievements: claimed", claimed, "of", #claimable, "| total reward", total)
	achBusy = false
	return claimed
end
--------------------------------------------------------------------------------
-- Collection Book milestones: Events.Collections.ClaimMilestoneReward:InvokeServer(areaName) (confirmed by the spy).
-- There is no known "what is claimable" call, so each area is tried; the server's answer says whether anything was claimed.
-- The first answer per area is logged in full, later ones only when they change.
--------------------------------------------------------------------------------
local collectionsBusy, collectionsListed = false, false
local collectionLast = {}   -- area -> last answer (as text)

local function claimCollectionMilestones()
	local folder = Events:FindFirstChild("Collections")
	local claimR = folder and folder:FindFirstChild("ClaimMilestoneReward")
	if collectionsBusy or not claimR then return 0 end
	collectionsBusy = true

	-- once: what else lives in Events.Collections (a status call would make this smarter)
	if not collectionsListed then
		collectionsListed = true
		local names = {}
		for _, c in ipairs(folder:GetChildren()) do names[#names + 1] = c.ClassName .. ":" .. c.Name end
		log("Events.Collections remotes:", table.concat(names, ", "))
		-- read-only getters (Get*) with no arguments are safe to look at once
		for _, c in ipairs(folder:GetChildren()) do
			if c:IsA("RemoteFunction") and c.Name:sub(1, 3) == "Get" then
				local ok, r = pcall(function() return c:InvokeServer() end)
				log("Events.Collections." .. c.Name .. " ->", ok, dumpValue(r, 3))
			end
		end
	end

	-- every area the game knows (the Collection Book is organised by area), plus the fish index
	local areas, seen = {}, {}
	if AreasCfg then
		for name, v in pairs(AreasCfg) do
			if type(v) == "table" and v.GarageIds and not seen[name] then seen[name] = true areas[#areas + 1] = name end
		end
	end
	if not seen["Fish"] then areas[#areas + 1] = "Fish" end
	table.sort(areas)

	local claimed = 0
	for _, area in ipairs(areas) do
		-- a few milestones can be ready at once: keep claiming this area until the server stops accepting
		local tooFast = 0
		local tries = 0
		while tries < 8 and not collectionLast[area .. "#unknown"] do
			tries = tries + 1
			local ok, r = pcall(function() return claimR:InvokeServer(area) end)
			local err = type(r) == "table" and tostring(r.error):lower() or ""
			if err:find("fast", 1, true) and tooFast < 3 then
				-- rate limited: back off and ask again, don't take it as "nothing to claim"
				tooFast = tooFast + 1
				tries = tries - 1
				task.wait(1.5 * tooFast)
				continue
			end
			if err:find("unknown area", 1, true) then collectionLast[area .. "#unknown"] = true end
			local good = ok and (r == true or (type(r) == "table" and (r.ok == true or r.success == true)))
			local text = tostring(ok) .. " " .. dumpValue(r, 2)
			if good then
				claimed = claimed + 1
				log("collection milestone claimed:", area, "->", dumpValue(r, 2))
				collectionLast[area] = nil
				task.wait(0.4)
			else
				if collectionLast[area] ~= text then
					collectionLast[area] = text
					log("collection milestone", area, "-> nothing to claim:", text)
				end
				break
			end
		end
		task.wait(1.2)
	end
	collectionsBusy = false
	return claimed
end
-- manual teleports (vehicle + you in the seat); disabled while the farm is running so they don't fight it
local function tpShop()
	if State.Running then log("TP Shop ignored: turn Auto Farm off first") return end
	local plot = myPlot()
	local spot = plot and plotSpot(plot)
	if not spot then setStatus("Plot not found") log("TP Shop: no plot/spot") return end
	local vehicle = ensureVehicle()
	if not vehicle then setStatus("No vehicle found") return end
	log("TP Shop ->", spot.Position)
	ensureSeated(vehicle)
	moveVehicle(vehicle, spot)
	setStatus("Teleported to shop")
end

-- Everything must be sold before a new auction: shelves, shelf-able inventory and the vehicle all empty.
local function shelfStockCount()
	local plot = myPlot()
	local stock = plot and plot:FindFirstChild("Stock")
	return stock and #stock:GetChildren() or 0
end

local function shelfableInventoryCount()
	local ok, inv = pcall(function() return R.GetInventory:InvokeServer() end)
	if not ok or type(inv) ~= "table" then return 0 end
	local n = 0
	for guid, entry in pairs(inv) do
		-- items waiting for the wrench can't be shelved yet, so they must not hold up the sell-out
		if not R.StockSaleRules.GetSellBlockReason(entry) and not repairableGuids[guid] and not washableGuids[guid] and not isBadItem(guid) and not isKept(entry) then n = n + 1 end
	end
	return n
end

local function sellOut()
	local t0 = os.clock()
	local lastSale, lastSold = os.clock(), State.Sold
	local stuck = 0
	while State.Running do
		local stock, inv, veh = shelfStockCount(), shelfableInventoryCount(), vehicleItemCount() or 0
		log("sell-out check: shelves", stock, "| inventory", inv, "| vehicle", veh, ("| %.0fs"):format(os.clock() - t0))
		if stock == 0 and inv == 0 and veh == 0 then
			log("everything is sold out")
			State.OfferFloor = nil
			return true
		end
		-- no shopper NPC anywhere in the shop for more than NoShopperNPCTimeout seconds: start the next auction
		-- (a loaded vehicle is always unloaded first, so winnings never get left behind)
		if veh == 0 and not next(pending) and secondsWithoutShoppers() >= CFG.NoShopperNPCTimeout then
			log("no shopper NPC in the shop for", CFG.NoShopperNPCTimeout, "s - starting the next auction with the stock left")
			State.OfferFloor = nil
			return false
		end
		if os.clock() - t0 > CFG.SellOutMaxTime then
			log("sell-out gave up after", CFG.SellOutMaxTime, "s - starting the next auction anyway")
			State.OfferFloor = nil
			return false
		end

		-- no sale for a while: accept the best offer even if it's somewhat below base price
		if State.Sold ~= lastSold then lastSold, lastSale = State.Sold, os.clock() end
		local relaxed = os.clock() - lastSale > CFG.SellOutRelaxAfter
		if relaxed and not State.OfferFloor then
			log("no sale for", CFG.SellOutRelaxAfter, "s - now accepting the best offer down to", CFG.SellOutFloorPct .. "%")
		end
		State.OfferFloor = relaxed and CFG.SellOutFloorPct or nil

		setStatus(("Selling out: %d shelf, %d inv, %d veh"):format(stock, inv, veh))
		if veh > 0 then
			sellPhase()          -- unloads the vehicle, shelves it, and waits for offers
		else
			if inv > 0 then
				local before = State.Stocked
				stockShelves()
				-- items that fit no shelf at all would block us forever
				if State.Stocked == before and stock == 0 then
					stuck = stuck + 1
					if stuck >= 2 then
						log("remaining inventory items don't fit on any shelf - treating them as unsellable")
						State.OfferFloor = nil
						return true
					end
				else
					stuck = 0
				end
			end
			offerLoop()
		end
	end
	State.OfferFloor = nil
	return false
end

-- wait until the character exists and is alive (death / respawn would otherwise break every teleport and seat call)
local function waitForAliveCharacter()
	local waited = false
	while State.Running do
		local hum = getHumanoid()
		local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
		if hum and hrp and hum.Health > 0 then
			if waited then task.wait(1.5) log("character is back") end
			return true
		end
		if not waited then log("character missing/dead - waiting for respawn") setStatus("Waiting for respawn") end
		waited = true
		task.wait(0.5)
	end
	return false
end

local lastUpgradeCheck, lastRewardCheck = 0, 0

-- everything that has to be dealt with before a new auction can safely start
-- Profit tracker. A "run" is one auction plus everything that follows until the next clean slate (everything sold).
-- gain = change in cash across the run, with cash we deliberately spent on upgrades (wrench) added back.
local P = { invested = 0, runs = 0, wins = 0, losses = 0, garages = {} }
local function money(n)
	local s = tostring(math.floor(math.abs(n) + 0.5))
	s = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
	return (n < 0 and "-$" or "+$") .. s
end
function P.reset()
	P.startCash, P.startT, P.invested, P.runs, P.wins, P.losses = LP:GetAttribute("Cash") or 0, os.clock(), 0, 0, 0, 0
	P.garages, P.last, P.base = {}, nil, nil
end
function P.begin()
	P.base = { cash = LP:GetAttribute("Cash") or 0, invested = P.invested }
end
-- called once the previous run is fully sold out: books its result
function P.settle()
	local b = P.base
	P.base = nil
	if not (b and b.garage) then return end
	local gain = (LP:GetAttribute("Cash") or 0) - b.cash + (P.invested - b.invested)
	local g = P.garages[b.garage] or { n = 0, sum = 0 }
	g.n, g.sum = g.n + 1, g.sum + gain
	P.garages[b.garage] = g
	P.runs = P.runs + 1
	if gain >= 0 then P.wins = P.wins + 1 else P.losses = P.losses + 1 end
	P.last = { garage = b.garage, gain = gain }
	log("PROFIT run", P.runs, b.garage, money(gain), "| avg there", money(g.sum / g.n), "(" .. g.n .. " runs)")
	if g.n >= 3 and g.sum < 0 then log("PROFIT hint:", b.garage, "loses money on average - a lower tier may pay better") end
end
-- Net worth -> garage: the best garage the game lets you enter right now (non-event, no special currency, no win requirement)
-- and the next one to unlock. Same rule scrapGarages uses to rank the garages in the world.
local function short(n)
	if n >= 1e9 then return ("%.1fB"):format(n / 1e9) end
	if n >= 1e6 then return ("%.1fM"):format(n / 1e6) end
	if n >= 1e3 then return ("%.1fk"):format(n / 1e3) end
	return tostring(math.floor(n))
end

-- The same readout as separate values, for the info grids of the VVind panel
function P.values()
	local nw = getNetWorth()
	local best, bestNeed, nextName, nextNeed
	if GaragesCfg then
		for name, cfg in pairs(GaragesCfg) do
			if type(cfg) == "table" and cfg.MinNetWorth and not cfg.EventOnly and not cfg.EntryCurrency and not cfg.RequiredGarageWins then
				local need = tonumber(cfg.MinNetWorth) or 0
				if need <= nw then
					if not bestNeed or need > bestNeed then best, bestNeed = name, need end
				elseif not nextNeed or need < nextNeed then
					nextName, nextNeed = name, need
				end
			end
		end
	end
	local v = {
		netWorth = short(nw), bestGarage = best or "-", nextUnlock = nextName and (nextName .. " @" .. short(nextNeed)) or "all unlocked",
		profit = "-", perHour = "-", runs = "0", record = "0 / 0",
		worth = "-", cap = "-", now = "-", last = "-", bestAvg = "-", worstAvg = "-",
	}
	if P.startT then
		local total = (LP:GetAttribute("Cash") or 0) - P.startCash + P.invested
		local hours = math.max(os.clock() - P.startT, 60) / 3600
		v.profit, v.perHour, v.runs, v.record = money(total), money(total / hours) .. "/hr", tostring(P.runs), P.wins .. " / " .. P.losses
	end
	if A.active then
		v.now = "$" .. ("%.0f"):format(tonumber(A.amount) or 0)
		if A.worth then v.worth, v.cap = "$" .. ("%.0f"):format(A.worth), "$" .. ("%.0f"):format(A.bidCap or 0) end
	end
	if P.last then v.last = ("%s (%s)"):format(money(P.last.gain), P.last.garage) end
	local bn, ba, wn, wa
	for name, g in pairs(P.garages) do
		local avg = g.sum / g.n
		if not ba or avg > ba then bn, ba = name, avg end
		if not wa or avg < wa then wn, wa = name, avg end
	end
	if bn then v.bestAvg = ("%s %s"):format(bn, money(ba)) end
	if wn and wn ~= bn then v.worstAvg = ("%s %s"):format(wn, money(wa)) end
	return v
end

local function maintenance()
	-- a. anything still in the vehicle gets unloaded, shelved and sold first
	local leftover = vehicleItemCount()
	log("vehicle items before auction:", leftover)
	if leftover and leftover > 0 then
		setStatus("Selling leftover vehicle items")
		sellPhase()
		if State.Running and (vehicleItemCount() or 0) > 0 then
			-- shelves/inventory full: selling to NPCs is the only way to make room
			log("vehicle still has items after selling (shop/inventory full) - waiting for NPC offers to free space")
			setStatus("Shop full, selling stock")
			offerLoop()
		end
	end
	if not State.Running then return end

	-- b. broken items -> repaired with the wrench
	if CFG.FarmRepair or State.AutoRepair then
		local ok, res = pcall(autoRepair)
		if not ok then log("autoRepair error:", res) repairBusy = false
		elseif res and res > 0 and State.Running then stockShelves() end
	end
	if not State.Running then return end

	-- b1. dirty items -> wash shop (so they are clean before they reach a shelf)
	if CFG.FarmWash or State.AutoWash then
		local ok, res = pcall(autoWash)
		if not ok then log("autoWash error:", res) washBusy = false
		elseif res and res > 0 and State.Running then
			-- a wash started a moment ago is usually done within seconds: wait for it and collect before moving on
			if waitForWashToFinish(CFG.WashWaitMax or 45) then
				local ok2, n2 = pcall(autoWash)
				if not ok2 then log("autoWash error:", n2) washBusy = false end
			end
			stockShelves()
		end
	end
	if not State.Running then return end

	-- b2. safes in the inventory/vehicle -> locksmith (also opens and claims finished ones)
	if CFG.FarmLocksmith or State.AutoLocksmith then
		local ok, res = pcall(autoLocksmith)
		if not ok then log("autoLocksmith error:", res) locksmithBusy = false
		elseif res and res > 0 and State.Running then stockShelves() end
	end
	if not State.Running then return end

	-- c. Lost & Found -> inventory -> shelves
	if CFG.FarmLostFound or State.AutoLost then
		local ok, res = pcall(collectLostFound, true)
		if not ok then log("collectLostFound error:", res) lostBusy = false
		elseif res and res > 0 and State.Running then stockShelves() end
	end
	if not State.Running then return end

	-- d. anything sitting in the inventory that still fits on a shelf
	local okS, errS = pcall(stockShelves)
	if not okS then log("stockShelves error:", errS) end

	-- e. spend money on progression: shop upgrades (diamonds) and a better wrench (cash)
	-- reward claiming: achievements (including the Collection Book index rewards)
	if CFG.FarmClaimRewards and os.clock() - lastRewardCheck > CFG.RewardCheckEvery then
		lastRewardCheck = os.clock()
		local okC, errC = pcall(claimRewards)
		if not okC then log("claimRewards error:", errC) achBusy = false end
		local okM, errM = pcall(claimCollectionMilestones)
		if not okM then log("claimCollectionMilestones error:", errM) collectionsBusy = false end
	end

	-- quests: log progress and run the feature a quest task asks for
	if State.AutoQuest then
		local okQ, errQ = pcall(questStep)
		if not okQ then log("questStep error:", errQ) end
	end

	if CFG.FarmUpgrades and os.clock() - lastUpgradeCheck > CFG.UpgradeCheckEvery then
		lastUpgradeCheck = os.clock()
		local okU, errU = pcall(upgradeShop, CFG.UpgradeDiamondReserve)
		if not okU then log("upgradeShop error:", errU) upgradesBusy = false end
		local cashBefore = LP:GetAttribute("Cash") or 0
		local okW, errW = pcall(buyBestWrench, CFG.FarmWrenchCashReserve)
		P.invested = P.invested + math.max(0, cashBefore - (LP:GetAttribute("Cash") or 0))
		if not okW then log("buyBestWrench error:", errW) wrenchBusy = false end
	end
end

local lostStreak = 0

local function farmCycle()
	log("=== new cycle ===")
	if not waitForAliveCharacter() then return end

	local batch = CFG.BatchMode
	if batch then
		-- batch mode: bid until the inventory is (nearly) full or cash runs short, then sell everything in one go
		local free = (LP:GetAttribute("InventoryCap") or 0) - (LP:GetAttribute("InventoryCount") or 0)
		if not State.BatchSelling and (free < CFG.BatchReserve or lostStreak >= CFG.LostStreakLimit or (vehicleItemCount() or 0) > 0 or (CFG.PlaceEveryN > 0 and (State.BatchAuctions or 0) >= CFG.PlaceEveryN)) then
			State.BatchAuctions = 0
			State.BatchSelling = true
			log("batch: selling round (free inventory slots:", free, "| lost streak:", lostStreak, ")")
			if lostStreak >= CFG.LostStreakLimit then
				State.TierSkip = (State.TierSkip or 0) + 1
				lostStreak = 0
			end
		end
		if State.BatchSelling then
			maintenance()
			if not State.Running then return end
			sellOut()
			if not State.Running then return end
			waitLastGarageCleared()
			P.settle()
			P.begin()
			State.BatchSelling = false
			return
		end
		if not P.base then P.begin() end
	else
		maintenance()
		if not State.Running then return end

		-- everything has to be sold before the next auction starts
		sellOut()
		if not State.Running then return end
	end

	-- the previous garage must be finished before bidding again
	waitLastGarageCleared()
	if not State.Running then return end

	if not batch then
		-- clean slate: book the previous run's profit and start measuring the next one
		P.settle()
		P.begin()
	end

	-- several lost auctions in a row usually means not enough cash: sell stock to NPCs to earn some
	if not batch and lostStreak >= CFG.LostStreakLimit then
		log("lost", lostStreak, "auctions in a row - selling stock to build up cash (cash:", LP:GetAttribute("Cash"), ")")
		setStatus("Low on cash, selling stock")
		State.TierSkip = (State.TierSkip or 0) + 1
		log("stepping down one garage tier for a while (TierSkip =", State.TierSkip, ")")
		offerLoop()
		lostStreak = 0
		return
	end

	if (vehicleItemCount() or 0) > 0 then
		log("vehicle still loaded - skipping auction this cycle")
		task.wait(5)
		return
	end

	-- last chance before bidding: anything sitting in Lost & Found (e.g. items left behind by the previous pickup) is claimed
	-- first, because entering a new auction can wipe it. Claimed items land in the vehicle, so sell them before continuing.
	local claimed = collectLostFound(true)
	if claimed and claimed > 0 then
		State.OwedItems = math.max(0, (State.OwedItems or 0) - claimed)
		log("claimed", claimed, "item(s) from Lost & Found right before the auction - selling them first")
		if (vehicleItemCount() or 0) > 0 then
			if batch then
				local v = findVehicle()
				if v then ensureSeated(v) end
				unloadAndStock(true)
			else
				sellPhase()
			end
		end
		return
	end

	local won, why = auctionPhase()
	if batch and (won or why ~= "retry") then State.BatchAuctions = (State.BatchAuctions or 0) + 1 end
	log("auctionPhase returned", won, why or "")
	if P.base and A.garageName and (won or why ~= "retry") then P.base.garage = A.garageName end
	if not State.Running then return end
	if won then
		lostStreak = 0
		State.TierSkip = 0
		-- AuctionPickupStart (which carries the item count) arrives a moment after the auction ends - wait for it
		local tw = os.clock()
		while State.Running and not A.pickupStarted and os.clock() - tw < 4 do task.wait(0.1) end
		local expected = (A.pickupCount and A.pickupCount > 0) and A.pickupCount or 6
		log("won - expecting", expected, "items (pickup started:", A.pickupStarted, ")")
		if batch then
			-- deliver, claim the left-behind items and park everything in the inventory; selling happens once it's full
			deliverWinnings(expected)
			unloadAndStock(true)
			local f = (LP:GetAttribute("InventoryCap") or 0) - (LP:GetAttribute("InventoryCount") or 0)
			log("batch: auction done, inventory", LP:GetAttribute("InventoryCount"), "/", LP:GetAttribute("InventoryCap"), "free", f)
		elseif not sellPhase(expected) then task.wait(5) end
	elseif why == "retry" then
		-- Lost & Found was emptied instead of bidding: unload what came out of it and start the cycle over
		if (vehicleItemCount() or 0) > 0 then
			if batch then unloadAndStock(true) else sellPhase() end
		end
	else
		lostStreak = lostStreak + 1
	end
end

local function farm()
	lostStreak = 0
	P.reset()
	if CFG.AutoJoin then
		local okJ, errJ = pcall(A.joinGame)
		if not okJ then log("join error:", errJ) end
	end
	while State.Running do
		-- a runtime error in one cycle must not kill the farm
		local ok, err = xpcall(farmCycle, function(e) return tostring(e) .. "\n" .. debug.traceback("", 2) end)
		if not ok then
			log("CYCLE ERROR:", err)
			setStatus("Error, retrying")
			repairBusy, lostBusy = false, false
			task.wait(3)
		end
		task.wait(CFG.LoopDelay)
	end
	setStatus("Stopped")
end
--------------------------------------------------------------------------------
-- Police event: officers chase you and your own client reports the arrest (Events.Misc.PoliceChase:FireServer("Arrest") when a
-- police car reaches you). With Avoid Arrest on, that call is dropped, so the chase can never end in an arrest (and the Freeze
-- that follows an arrest never comes). The chase events are logged.
--------------------------------------------------------------------------------
do
	local chase = Events:FindFirstChild("Misc") and Events.Misc:FindFirstChild("PoliceChase")
	if chase and chase:IsA("RemoteEvent") then
		ctx:Connect(chase.OnClientEvent, function(kind)
			if kind == "Start" or kind == "Stop" or kind == "Freeze" then
				log("police chase:", tostring(kind), State.AvoidArrest and "(arrest is blocked)" or "")
			end
		end)
		ctx:HookMeta(game, "__namecall", function(old, self, ...)
			if State.AvoidArrest and self == chase and getnamecallmethod() == "FireServer" and (...) == "Arrest" then
				A.arrestsBlocked = (A.arrestsBlocked or 0) + 1
				if A.arrestsBlocked <= 3 or A.arrestsBlocked % 20 == 0 then log("police: arrest blocked (", A.arrestsBlocked, ")") end
				return
			end
			return old(self, ...)
		end)
	end
end

--------------------------------------------------------------------------------
-- Auto Museum: visitors leave a gift in a museum slot (slot.Pending). GetState() -> {Unlocked, MaxSlots, Slots = {["1"] = {ItemGUID,
-- Pending, ...}}, NextRewardIn}; Collect(slotIndex) -> success, error, mutation ("Too fast" = rate limited, try again later).
-- The remote folder's name comes from Modules.MuseumConfig, so it is found by looking for the folder that has these remotes.
--------------------------------------------------------------------------------
do
	local folder
	for _, c in ipairs(Events:GetChildren()) do
		if c:FindFirstChild("GetState") and c:FindFirstChild("Collect") and c:FindFirstChild("Donate") and c:FindFirstChild("UnlockSlot") then
			folder = c
			break
		end
	end
	function A.museumPass()
		if not folder then return 0 end
		local ok, st = pcall(function() return folder.GetState:InvokeServer() end)
		if not ok or type(st) ~= "table" then log("Museum GetState ->", ok, dumpValue(st, 2)) return 0 end
		local collected = 0
		for i = 1, tonumber(st.MaxSlots) or 0 do
			local slot = (st.Slots or {})[tostring(i)]
			if slot and slot.Pending then
				for attempt = 1, 3 do
					local ok2, success, err, mutation = pcall(function() return folder.Collect:InvokeServer(i) end)
					log("Museum Collect slot", i, "->", ok2, success, err, mutation)
					if ok2 and success then collected = collected + 1 break end
					if not (ok2 and tostring(err) == "Too fast") then break end
					task.wait(2 + attempt)
				end
				task.wait(1.5)
			end
		end
		return collected
	end
	task.spawn(function()
		while ctx:Alive() do
			task.wait(30)
			if State.AutoMuseum and folder then pcall(A.museumPass) end
		end
	end)
	if not folder then log("Museum remotes not found - Auto Museum unavailable") end
end

--------------------------------------------------------------------------------
-- Anti-AFK: the idle kick fires after 20 minutes without input; answer it with a fake click
--------------------------------------------------------------------------------
do
	local VU = game:GetService("VirtualUser")
	ctx:Connect(LP.Idled, function()
		if not CFG.AntiAFK then return end
		pcall(function()
			VU:CaptureController()
			VU:ClickButton2(Vector2.new())
		end)
	end)
end

--------------------------------------------------------------------------------
-- Panel: built from the hub's subtabs
--------------------------------------------------------------------------------
A.vvindUI = function()
	ctx:OnCleanup(function()
		State.Running = false
		State.Spy = false
		State.onStatus = nil
		logSink = nil
	end)

	local function notify(title, text) ctx.Notify((text and text ~= "") and (title .. ": " .. text) or title, "info", 3) end

	-- boolean setting stored in State or CFG
	local function tg(tab, text, store, key, desc, onChange)
		return tab:AddToggle({
			Text = text, Description = desc, Default = store[key] == true,
			Callback = function(v)
				store[key] = v
				log(text, v and "enabled" or "disabled")
				if onChange then onChange(v) end
			end,
		})
	end
	-- numeric setting as a slider (scale: 100 for fractions shown as percent)
	local function sl(tab, text, store, key, min, max, inc, scale, suffix, desc)
		scale = scale or 1
		return tab:AddSlider({
			Text = text, Description = desc, Min = min, Max = max, Increment = inc or 1, Suffix = suffix or "",
			Default = math.clamp((tonumber(store[key]) or min) * scale, min, max),
			Callback = function(v) store[key] = v / scale end,
		})
	end
	-- numeric setting typed in (accepts "inf")
	local function num(tab, text, store, key, desc)
		return tab:AddTextbox({
			Text = text, Description = desc, Placeholder = "number",
			Default = store[key] == math.huge and "inf" or tostring(store[key]),
			Callback = function(t)
				local n = tostring(t):lower():find("inf") and math.huge or tonumber((tostring(t):gsub("[^%d%.%-]", "")))
				if n then store[key] = n log(text, "=", tostring(n)) end
			end,
		})
	end
	local function btn(tab, text, desc, fn)
		return tab:AddButton({
			Text = text, Description = desc,
			Callback = function()
				local ok, res = pcall(fn)
				notify(text, ok and (type(res) == "string" and res or "Done") or ("Error: " .. tostring(res)))
			end,
		})
	end
	-- a multi-select dropdown that keeps a set (X.*) in sync
	local function setDropdown(tab, text, set, options, desc)
		local chosen = {}
		for name in pairs(set) do chosen[#chosen + 1] = name end
		return tab:AddDropdown({
			Text = text, Description = desc, Options = options, MultiSelect = true, Default = chosen,
			Callback = function(list)
				for k in pairs(set) do set[k] = nil end
				for _, name in ipairs(list or {}) do set[name] = true end
				log(text, "->", #(list or {}), "selected")
			end,
		})
	end

	---------------------------------------------------------------- Dashboard
	local dash = ctx:SubTab("Farm", "Lucide:coins")
	dash:AddSection("Auto Farm", "Lucide:play")
	local farmToggle
	farmToggle = dash:AddToggle({
		Text = "Auto Farm", Description = "Bid, collect, shelve and sell on a loop",
		Default = false,
		Callback = function(v)
			if v == State.Running then return end
			State.Running = v
			if v then task.spawn(farm) else setStatus("Stopping...") end
		end,
	})
	-- Readouts: info grids (labelled chips) that are updated in place with SetValue
	local gStatus = dash:AddInfoGrid({ Title = "Status", Columns = 1, Items = { { Label = "Now", Value = "Idle" } } })
	local gSession = dash:AddInfoGrid({ Title = "Session", Columns = 4, Items = {
		{ Label = "Wins", Value = "0" }, { Label = "Sold", Value = "0" }, { Label = "Rejected", Value = "0" }, { Label = "Stocked", Value = "0" },
	} })
	local gProfit = dash:AddInfoGrid({ Title = "Profit", Columns = 4, Items = {
		{ Label = "Total", Value = "-" }, { Label = "Per hour", Value = "-" }, { Label = "Runs", Value = "0" }, { Label = "Won / lost", Value = "0 / 0" },
	} })
	local gAuction = dash:AddInfoGrid({ Title = "Auction", Columns = 3, Items = {
		{ Label = "Garage worth", Value = "-" }, { Label = "Bid cap", Value = "-" }, { Label = "Current bid", Value = "-" },
		{ Label = "Last run", Value = "-" }, { Label = "Best garage avg", Value = "-" }, { Label = "Worst garage avg", Value = "-" },
	} })
	local gNet = dash:AddInfoGrid({ Title = "Progress", Columns = 3, Items = {
		{ Label = "Net worth", Value = "-" }, { Label = "Best garage", Value = "-" }, { Label = "Next unlock", Value = "-" },
	} })
	local function refreshCards()
		gSession:SetValue("Wins", State.Wins)
		gSession:SetValue("Sold", State.Sold)
		gSession:SetValue("Rejected", State.Rejected)
		gSession:SetValue("Stocked", State.Stocked)
		local v = P.values()
		gProfit:SetValue("Total", v.profit)
		gProfit:SetValue("Per hour", v.perHour)
		gProfit:SetValue("Runs", v.runs)
		gProfit:SetValue("Won / lost", v.record)
		gAuction:SetValue("Garage worth", v.worth)
		gAuction:SetValue("Bid cap", v.cap)
		gAuction:SetValue("Current bid", v.now)
		gAuction:SetValue("Last run", v.last)
		gAuction:SetValue("Best garage avg", v.bestAvg)
		gAuction:SetValue("Worst garage avg", v.worstAvg)
		gNet:SetValue("Net worth", v.netWorth)
		gNet:SetValue("Best garage", v.bestGarage)
		gNet:SetValue("Next unlock", v.nextUnlock)
	end
	State.onStatus = function(s)
		gStatus:SetValue("Now", s)
		refreshCards()
	end
	refreshCards()
	task.spawn(function()
		while State.onStatus do
			pcall(refreshCards)
			task.wait(2)
		end
	end)
	dash:AddSection("Loop", "Lucide:repeat")
	tg(dash, "Batch Auctions", CFG, "BatchMode", "Run several auctions, then sell everything")
	sl(dash, "Sell After N Auctions", CFG, "PlaceEveryN", 0, 20, 1, 1, "", "0 = only when the inventory is nearly full")
	sl(dash, "Sell When Free Slots Below", CFG, "BatchReserve", 1, 20, 1)
	tg(dash, "Auto Collect Winnings", State, "AutoCollect")
	tg(dash, "Auto Unload Truck", State, "AutoUnload")
	tg(dash, "Auto Lost & Found", State, "AutoLost")
	tg(dash, "Auto Locksmith", State, "AutoLocksmith")
	tg(dash, "Auto Quest", State, "AutoQuest")
	tg(dash, "Auto Museum", State, "AutoMuseum", "Collect the visitors' gifts")
	tg(dash, "Avoid Arrest", State, "AvoidArrest", "Blocks the arrest report so police chases never end in an arrest")
	tg(dash, "Anti-AFK", CFG, "AntiAFK")
	dash:AddSection("Vehicle", "Lucide:truck")
	btn(dash, "Unload Truck", nil, function()
		if (vehicleItemCount() or 0) == 0 then return "Truck is empty" end
		autoUnload()
		return "Unloaded"
	end)
	btn(dash, "Recall Vehicle", "Bring the truck to you", function()
		local v = ensureVehicle()
		if not v then return "No vehicle" end
		local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
		if hrp then moveVehicle(v, hrp.CFrame * CFrame.new(0, 2, -14)) end
		return "Recalled"
	end)
	btn(dash, "Teleport To Base", nil, function() tpShop() end)

	---------------------------------------------------------------- Auction
	local auc = ctx:SubTab("Auction", "Lucide:gavel")
	auc:AddSection("Bidding", "Lucide:gavel")
	tg(auc, "Auto Bid", State, "AutoBid")
	num(auc, "Max Bid ($)", CFG, "MaxBid", "Never bid above this price (inf = no limit)")
	sl(auc, "Max % Of Garage Worth", CFG, "MaxBidValueFraction", 1, 100, 1, 100, "%", "Uses the in-game calculator")
	sl(auc, "Max % Of Cash", CFG, "MaxBidCashFraction", 1, 100, 1, 100, "%")
	tg(auc, "Kick NPCs", State, "AutoKick", "Kick a rival NPC bidder at the start of each auction")
	auc:AddSection("Garage Types", "Lucide:warehouse")
	local areaOpts = { "(none)" }
	for _, n in ipairs(areaNames()) do areaOpts[#areaOpts + 1] = n end
	local function repack()
		local packed = {}
		for k = 1, 3 do if X.GaragePrio[k] then packed[#packed + 1] = X.GaragePrio[k] end end
		for k = 1, 3 do X.GaragePrio[k] = packed[k] end
	end
	for i = 1, 3 do
		auc:AddDropdown({
			Text = ("Priority %d%s"):format(i, i == 1 and " (highest)" or i == 3 and " (lowest)" or ""),
			Options = areaOpts, Default = X.GaragePrio[i] or "(none)", Flag = false,
			Callback = function(v)
				X.GaragePrio[i] = v ~= "(none)" and v or nil
				repack()
				log("garage priority", i, "=", tostring(v))
			end,
		})
	end
	tg(auc, "Prioritize Nearest To Vehicle", CFG, "PrioritizeNearest")
	tg(auc, "Prioritize Alien Garages", CFG, "PrioritizeAlien")

	---------------------------------------------------------------- Items
	local items = ctx:SubTab("Items", "Lucide:package")
	items:AddSection("Offers", "Lucide:tag")
	tg(items, "Auto Accept Offers", State, "AutoOffers")
	sl(items, "Min Accept %", CFG, "MinOfferPct", -100, 100, 1, 1, "%", "Offers below this % of the base price are rejected")
	items:AddSection("Shelving", "Lucide:layout-grid")
	tg(items, "Auto Shelf", State, "AutoShelf")
	tg(items, "Disable Auto Place", CFG, "DisableAutoPlace", "Auto Farm leaves shelving to you")
	tg(items, "Keep Favourites", State, "KeepFavorites")
	tg(items, "Skip Broken Items", CFG, "SkipBroken")
	tg(items, "Skip High Value Items", CFG, "SkipHighValue")
	num(items, "Max Value To Place ($)", CFG, "MaxValueToPlace")
	tg(items, "Skip Low Value Items", CFG, "SkipLowValue")
	num(items, "Min Value To Place ($)", CFG, "MinValueToPlace")
	local exLabel = items:AddLabel("Excluded items: none")
	local function showExcluded()
		local names = {}
		for n in pairs(X.ExcludeItems) do names[#names + 1] = n end
		table.sort(names)
		exLabel.Set(exLabel, "Excluded items: " .. (#names > 0 and table.concat(names, ", ") or "none"))
	end
	items:AddTextbox({
		Text = "Exclude Or Include Item", Description = "Type part of a name and press Enter to toggle it off the shelves",
		Placeholder = "item name", Flag = false,
		Callback = function(t)
			local q = tostring(t):lower():gsub("^%s+", ""):gsub("%s+$", "")
			if q == "" then return end
			local hit
			for _, def in pairs(R.Items) do
				if type(def) == "table" and def.Name then
					local n = def.Name:lower()
					if n == q then hit = def.Name break end
					if not hit and n:find(q, 1, true) then hit = def.Name end
				end
			end
			if not hit then notify("Exclude item", "No item matches '" .. tostring(t) .. "'") return end
			X.ExcludeItems[hit] = (not X.ExcludeItems[hit]) or nil
			notify("Exclude item", hit .. (X.ExcludeItems[hit] and " excluded" or " allowed again"))
			showExcluded()
		end,
	})
	setDropdown(items, "Exclude Mutations", X.ExcludeMutations, { "Dirty", "Broken", "Gold", "Silver", "Diamond", "Corrupted", "Spotless", "Pure", "Moonlit", "Sandy" })
	items:AddSection("Repair & Wash", "Lucide:wrench")
	tg(items, "Auto Repair Broken Items", State, "AutoRepair")
	tg(items, "Auto Wash", State, "AutoWash")

	---------------------------------------------------------------- Drinks
	local drinks = ctx:SubTab("Drinks", "Lucide:cup-soda")
	drinks:AddSection("Energy And Luck Drinks", "Lucide:cup-soda")
	tg(drinks, "Auto Use Energy Drinks", State, "AutoConsume")
	local drinkNames = {}
	if okDrinks and type(DrinkCfg) == "table" then
		for _, d in pairs(DrinkCfg) do
			if type(d) == "table" and d.ItemId and not d.Targeted and not d.GradeRerollCharge and d.Name then drinkNames[#drinkNames + 1] = d.Name end
		end
		table.sort(drinkNames)
	end
	setDropdown(drinks, "Drinks To Use", X.DrinksToUse, drinkNames, "None selected means any drink")
	tg(drinks, "Only Use When All Selected Available", CFG, "OnlyUseAllDrinks")

	---------------------------------------------------------------- Fish
	local fish = ctx:SubTab("Fish", "Lucide:fish")
	fish:AddSection("Fishing", "Lucide:fish")
	tg(fish, "Auto Fish", State, "AutoFish")
	btn(fish, "Teleport To Pond", nil, function() if A.tpPond then A.tpPond() else return "Fishing unavailable" end end)
	tg(fish, "Enable Placement", CFG, "FishPlace", "Shelve the catches")
	sl(fish, "Place Every N Catches", CFG, "FishPlaceEvery", 1, 30, 1)
	sl(fish, "Bite Timeout", CFG, "FishBiteTimeout", 10, 120, 5, 1, "s")
	sl(fish, "Reel Delay", CFG, "FishReelDelay", 1, 15, 1, 1, "s")

	---------------------------------------------------------------- Teleport
	local tp = ctx:SubTab("Teleports", "Lucide:map-pin")
	tp:AddSection("Shops", "Lucide:store")
	btn(tp, "Teleport To Your Shop", nil, function() tpShop() end)
	local shopNames = {}
	for _, s in ipairs(SHOPS) do shopNames[#shopNames + 1] = s[1] end
	local pickedShop = shopNames[1]
	tp:AddDropdown({ Text = "Shop", Options = shopNames, Default = pickedShop, Flag = false, Callback = function(v) pickedShop = v end })
	btn(tp, "Teleport To Selected Shop", nil, function()
		if not shopPositions[pickedShop] then scanAllShops() end
		tpToShop(pickedShop)
	end)
	btn(tp, "Rescan Shops", nil, function() shopPositions = {} scanAllShops() end)
	tp:AddSection("Areas", "Lucide:map")
	local pickedArea = areaOpts[2]
	tp:AddDropdown({ Text = "Area", Flag = false, Options = (function() local o = {} for i = 2, #areaOpts do o[#o + 1] = areaOpts[i] end return o end)(), Default = pickedArea, Callback = function(v) pickedArea = v end })
	btn(tp, "Teleport To Selected Area", nil, function() if pickedArea then tpToArea(pickedArea) end end)

	---------------------------------------------------------------- Misc
	local tools = ctx:SubTab("Misc", "Lucide:ellipsis")
	tools:AddSection("Upgrades", "Lucide:hammer")
	btn(tools, "Buy Best Wrench", nil, function() return buyBestWrench() and "Bought!" or "Nothing to buy" end)
	btn(tools, "Upgrade Shop", nil, function()
		local n = upgradeShop(CFG.UpgradeDiamondReserve)
		return n > 0 and ("Bought " .. n .. " upgrade(s)") or "Nothing to buy"
	end)

	---------------------------------------------------------------- Debug
	local dbg = ctx:SubTab("Debug", "Lucide:bug")
	dbg:AddSection("Debug", "Lucide:bug")
	dbg:AddToggle({
		Text = "Spy", Description = "Log remote calls", Default = false, Flag = false,
		Callback = function(v)
			State.Spy = v
			log("Spy", v and "enabled" or "disabled")
			if v then installSpy() end
		end,
	})
	btn(dbg, "Scan Remotes", nil, scanRemotes)
	btn(dbg, "Copy Logs", nil, function()
		local text = table.concat(LogBuffer, "\n")
		if setclipboard then pcall(setclipboard, text) return "Copied" end
		print(text)
		return "Printed"
	end)

	setStatus("Idle")
	log("Loaded.")

	-- Auto Farm starts by itself when the script is loaded (set CFG.AutoStart = false to turn that off)
	if CFG.AutoStart then farmToggle:Set(true) end
end

A.vvindUI()
