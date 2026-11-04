-- Phone Empire
local ctx = ...
local task = ctx.task

-- Phone Tycoon automation, all in one script: Auto Research, Auto Move In, Auto-Place Furniture,
-- Auto Claim Candy, Auto Design & Launch, with a small draggable panel to toggle each one. Replaces AutoResearch.luau and AutoMoveIn.luau
-- (don't run those alongside this).
--
-- The "start research" and "move office" requests are sent from the Panels module (not in the dump),
-- so their action names are unknown:
--   * Research: start ONE research by hand and the script learns the exact call (needs the namecall hook),
--     otherwise it tries RESEARCH_CANDIDATES.
--   * Move: tries MOVE_CANDIDATES and remembers the first the server accepts.
-- Auto-place uses the real calls from PhoneTycoonClient.luau: ackMoveIn, then build/autoPlace.

local CHECK_INTERVAL = 2
local STATUS_EVERY = 15 -- seconds between "why isn't it researching" status lines
local RESEARCH_CANDIDATES = {
	"research", "startResearch", "beginResearch", "setResearch", "queueResearch",
	"pickResearch", "selectResearch", "researchTech", "unlockResearch", "buyResearch",
}
local MOVE_CANDIDATES = { "moveOffice", "upgradeOffice", "moveOut", "buyOffice", "relocate", "move", "officeMove" }

local Players = game:GetService("Players")

local PhoneTycoon = game:GetService("ReplicatedStorage"):WaitForChild("PhoneTycoon")
local Config = require(PhoneTycoon:WaitForChild("Config"))
local Economy = require(PhoneTycoon:WaitForChild("Economy"))
local Action = PhoneTycoon:WaitForChild("Remotes"):WaitForChild("Action")

-- Furniture (same shared module the client uses) tells how many desks are placed
local furnitureLoaded, Furniture = pcall(function()
	return require(PhoneTycoon:WaitForChild("Furniture", 5))
end)

if not furnitureLoaded then
	Furniture = nil
end

-- Toggles (read live by the loop, flipped by the panel); the Lunar subtab holds the same set for the Moon

-- Auto Spend on the Empire, the lunar colony and furniture (filled in further down). learned[categoryKey] =
-- { args = {...}, idIndex = n or nil }: the calls recorded from the game's own purchases.
local Empire = { learned = {} }

-- Each world has its own switches: the Toggles tab edits Earth's (earth), the Lunar tab the Moon's (moon).
-- `Settings` is what the automation reads and always points at the world the game is in right now (Empire.cur);
-- the Main and Lunar subtabs edit Earth's and the Moon's switches.
Empire.earth = {}
Empire.moon = {}
Empire.cur = Empire.earth

function Empire.defaults(settings)
	for _, key in { "research", "moveIn", "autoPlace", "candy", "closePopups", "insurance", "moonChoices", "contracts", "meteors" } do
		if settings[key] == nil then
			settings[key] = true
		end
	end

	-- these spend cash, raise wages or can't be undone, so they start off:
	-- design (pricing: "suggested" or "premium" = just under premium), training, hiring, selling the company
	-- (sellAt = Legacy points to wait for), Legacy perks, the Empire purchases and the furniture upgrades
	for _, key in { "design", "train", "hire", "sell", "perks", "services", "factories", "megaprojects", "upgradeGear", "upgradeTables", "districts", "repair", "expedition" } do
		if settings[key] == nil then
			settings[key] = false
		end
	end

	if settings.sellAt == nil then
		settings.sellAt = 5
	end

	if settings.pricing == nil then
		settings.pricing = "premium" -- the highest price the studio doesn't call "premium", so the most margin per unit
	end

	-- device: "first" (the studio's default device), "random" (a random unlocked one each design), or a device id
	if settings.device == nil then
		settings.device = "first"
	end

	-- designInterval: minimum in-game days between starting two designs (0 = start the next one right away)
	if settings.designInterval == nil then
		settings.designInterval = 0
	end
end

Empire.defaults(Empire.earth)
Empire.defaults(Empire.moon)

local Settings = setmetatable({}, {
	__index = function(_, key)
		return Empire.cur[key]
	end,
	__newindex = function(_, key, value)
		Empire.cur[key] = value
	end,
})

-- ================================ Logging ================================
-- Everything this script prints or warns goes to the hub's Debug Console.
local function pushLog(isWarn, ...)
	local parts = table.pack(...)

	for index = 1, parts.n do
		parts[index] = tostring(parts[index])
	end

	ctx.Log(table.concat(parts, " ", 1, parts.n), isWarn and "warn" or "info")
end

local function print(...)
	pushLog(false, ...)
end

local function warn(...)
	pushLog(true, ...)
end

local running = true

ctx:OnCleanup(function()
	running = false
end)

local function invoke(action, ...)
	local ok, result = pcall(function(...)
		return Action:InvokeServer(action, ...)
	end, ...)

	if not ok then
		return nil, tostring(result)
	end

	return result
end

-- =============================== Auto Research ===============================
-- Mirrors researchOptions() from PhoneTycoonClient.luau (prerequisites met, year reached,
-- not researched/active, affordable).

local function affordableTechs(state)
	local currentYear = Economy.year(state.day)
	local affordable = {}

	for _, tech in Economy.techTree() do
		if not (state.researched[tech.id] or (tech.year > currentYear or Economy.researchEntry(state, tech.id))) then
			local prerequisitesMet = true

			for _, requiredId in tech.requires do
				if not state.researched[requiredId] then
					prerequisitesMet = false
					break
				end
			end

			if prerequisitesMet and state.rp >= tech.cost then
				table.insert(affordable, tech)
			end
		end
	end

	table.sort(affordable, function(a, b)
		return a.cost < b.cost
	end)

	return affordable
end

-- LEARN: watch for the game's own research request (any Action call carrying a tech id)
local learned -- { args = {...}, techIndex = n }
local learnedHire -- { args = {...}, idIndex = n or nil } (see Auto Hire Staff)
local lastPoolIds = {} -- ids of the people currently up for hire, so a manual hire can be recognised
local learnedSell -- { args = {...} } the call that sold the company (see Auto Sell Company)
local pendingSellCall -- a "sell" call seen but not yet confirmed by Legacy points going up
local lastLegacyPoints = 0

do
	local techIds = {}

	for _, tech in Economy.techTree() do
		techIds[tech.id] = true
	end

	ctx:HookMeta(game, "__namecall", function(original, self, ...)
		if running and self == Action and getnamecallmethod() == "InvokeServer" and not (checkcaller and checkcaller()) then
			local args = table.pack(...)

			if type(args[1]) == "string" then
				for index = 2, args.n do
					if techIds[args[index]] then
						learned = { args = args, techIndex = index }
						task.defer(print, string.format("[Auto] Learned research call: %s (tech id at arg %d)", args[1], index))
						break
					end
				end

				-- the Staff panel's hire request: any call named like "hire" / "recruit"
				local callName = string.lower(args[1])

				if string.find(callName, "hire", 1, true) or string.find(callName, "recruit", 1, true) then
					local idIndex

					for index = 2, args.n do
						if lastPoolIds[args[index]] then
							idIndex = index
							break
						end
					end

					learnedHire = { args = args, idIndex = idIndex }
					task.defer(print, string.format("[Auto] Learned hire call: %s (candidate id %s)", args[1], idIndex and ("at arg " .. idIndex) or "not passed"))
				end

				-- the player's own shot at a meteor (MoonFX, not in the dump): learned so it can be repeated
				if string.find(callName, "meteor", 1, true) or string.find(callName, "shoot", 1, true) or string.find(callName, "laser", 1, true) or string.find(callName, "zap", 1, true) then
					Empire.learned.shoot = { args = args }
					task.defer(print, "[Auto] Learned the meteor shot call: " .. tostring(args[1]))
				end

				-- the player's own expedition launch: its extra arguments (crew / rover) are reused
				if args[1] == "launchExpedition" then
					Empire.learned.expedition = { args = args, idIndex = 2 }
					task.defer(print, "[Auto] Learned the expedition call: launchExpedition(" .. tostring(args[2]) .. ", " .. tostring(args[3]) .. ")")
				end

				-- an Empire purchase (the Empire panel is not in the dump): any "empire" call except the perk shop
				if Empire.classify and ((args[1] == "empire" and args[2] ~= "perk") or string.find(callName, "colony", 1, true) or string.find(callName, "moon", 1, true) or string.find(callName, "district", 1, true) or string.find(callName, "system", 1, true)) then
					pcall(Empire.classify, args)
				end

				-- a company sale: "sell" in one of the first two arguments (not the Build tab's furniture sale).
				-- It only counts once Legacy points go up afterwards (see trackSell).
				if args[1] ~= "build" then
					for index = 1, math.min(2, args.n) do
						if type(args[index]) == "string" and string.find(string.lower(args[index]), "sell", 1, true) then
							pendingSellCall = { args = args, pointsBefore = lastLegacyPoints, at = os.clock() }
							break
						end
					end
				end
			end
		end

		return original(self, ...)
	end)
end

local researchActionName
local researchFailures = {}

local function startResearch(tech)
	if learned then
		local args = table.clone(learned.args)
		args[learned.techIndex] = tech.id
		local result, err = invoke(table.unpack(args, 1, args.n))

		if result and result.ok then
			print(string.format("[Auto] Research started: %s (%s)", tostring(tech.name or tech.id), tostring(args[1])))
			return true
		end

		warn("[Auto] Learned research call was refused: " .. tostring(result and result.msg or err or "no response"))
		return false
	end

	for _, candidate in researchActionName and { researchActionName } or RESEARCH_CANDIDATES do
		local result, err = invoke(candidate, tech.id)

		if result and result.ok then
			researchActionName = candidate
			print(string.format("[Auto] Research started: %s (%s)", tostring(tech.name or tech.id), candidate))
			return true
		end

		researchFailures[candidate] = tostring(result and result.msg or err or "no response")
	end

	return false
end

local lastStatus = 0

local function reportResearchStatus(state, affordable)
	if os.clock() - lastStatus < STATUS_EVERY then
		return
	end

	lastStatus = os.clock()

	local ok, free = pcall(Economy.researchFree, state)
	print(string.format(
		"[Auto] research waiting: slot free=%s, affordable techs=%d, RP=%s, research call %s",
		tostring(ok and free), #affordable, tostring(state.rp),
		learned and "learned" or (researchActionName and ("= " .. researchActionName) or "UNKNOWN, start one research by hand")
	))

	if not learned and not researchActionName then
		for candidate, message in researchFailures do
			print(string.format("    tried %s -> %s", candidate, message))
		end
	end
end

-- ============================ Auto Move In / Place ============================
-- Uses the game's own Panels.moveStatus(state) (what drives the "You can move office" nudge),
-- which returns { ready = bool, next = <next OfficeLevels entry> }.

-- Find one of the client's own modules (siblings of DesignStudio under the Phone Tycoon LocalScript)
local function findGameModule(name, requiredField)
	if not getloadedmodules then
		return nil
	end

	for _, module in getloadedmodules() do
		if module.Name == name and module.Parent and module.Parent:FindFirstChild("DesignStudio") then
			local ok, result = pcall(require, module)

			if ok and type(result) == "table" and result[requiredField] then
				return result
			end
		end
	end

	return nil
end

local function findPanels()
	return findGameModule("Panels", "moveStatus")
end

local Panels
local warnedPanels = false
local moveActionName
local moveFailedRounds = 0

local function moveOffice(nextOffice)
	for _, candidate in moveActionName and { moveActionName } or MOVE_CANDIDATES do
		local result = invoke(candidate)

		if result and result.ok then
			moveActionName = candidate
			print(string.format("[Auto] Moved to office level %s (%s)", tostring(table.find(Config.OfficeLevels, nextOffice)), candidate))
			return true
		end
	end

	return false
end

-- Fires a button's Activated handlers, the same as the player pressing it
local function activate(button)
	if firesignal then
		firesignal(button.Activated)
	elseif getconnections then
		for _, connection in getconnections(button.Activated) do
			connection:Fire()
		end
	else
		return false
	end

	return true
end

-- Clicks a UI button by its text
local function clickButton(text)
	local playerGui = Players.LocalPlayer.PlayerGui:FindFirstChild("PhoneTycoonGui")

	if not playerGui then
		return false
	end

	for _, descendant in playerGui:GetDescendants() do
		if descendant:IsA("TextButton") and descendant.Text == text then
			return activate(descendant)
		end
	end

	return false
end

local placing = false
local lastAutoPlace = -math.huge

local function moveInCard()
	return Players.LocalPlayer.PlayerGui:FindFirstChild("MoveInCard", true)
end

-- Closes the welcome card the way its "Later" button does (closeMoveIn: remove the card, un-blur, ackMoveIn).
-- If clicking can't do it, remove the card and the blur by hand so the screen is never left stuck.
local function dismissMoveInCard()
	for _ = 1, 6 do
		if not moveInCard() then
			return
		end

		clickButton("Later")
		task.wait(0.5)
	end

	local card = moveInCard()

	if card then
		card:Destroy()
		invoke("ackMoveIn")

		local blur = game:GetService("Lighting"):FindFirstChild("UIBlur")

		if blur then
			blur.Size = 0
		end

		warn("[Auto] The move-in card ignored 'Later', so it was removed directly.")
	end
end

-- Mirrors the welcome card's "Auto-place it for me" button: closeMoveIn() -> ackMoveIn, then build/autoPlace.
-- Whichever way the furniture gets placed, it then makes sure the card is gone.
local function autoPlace()
	if not Settings.autoPlace or placing or os.clock() - lastAutoPlace < 8 then
		return
	end

	placing = true
	lastAutoPlace = os.clock()

	-- The game holds the welcome card back while other popups are open, so give it time to appear
	local deadline = os.clock() + 25

	while running and os.clock() < deadline and not moveInCard() do
		task.wait(0.25)
	end

	if moveInCard() and clickButton("Auto-place it for me") then
		print("[Auto] Clicked 'Auto-place it for me'")
	else
		-- No button (nothing auto-placeable, or the card never showed): do it server-side
		invoke("ackMoveIn")
		invoke("build", "autoPlace")
		print("[Auto] Auto-placed via server calls")
	end

	task.wait(1)
	dismissMoveInCard()
	placing = false
end

-- Continuous placing, independent of moving: whenever something placeable sits in storage, or no desk is placed at
-- all, ask the server to place it (the same build/autoPlace the welcome card's button sends).
-- "Placeable" follows the welcome card: attachments, Structure pieces and wall pieces are not auto-placed.
local AUTO_PLACE_EVERY = 5 -- seconds between tries while there's something to place
local lastStoredPlace = -math.huge
local storedPlaceBackoff = 0

local function storedPlaceable(state)
	local count = 0

	if not Furniture then
		return count
	end

	for furnitureId, amount in state.office and state.office.storage or {} do
		local def = Furniture.ById[furnitureId]

		if def and amount > 0 and not (def.attach or def.cat == "Structure" or def.wall) then
			count = count + amount
		end
	end

	return count
end

local function autoPlaceStored(state)
	if placing or os.clock() < storedPlaceBackoff or os.clock() - lastStoredPlace < AUTO_PLACE_EVERY then
		return
	end

	local stored = storedPlaceable(state)
	local noDesks = Furniture ~= nil and #Furniture.desks(state.office) == 0

	if stored == 0 and not noDesks then
		return
	end

	lastStoredPlace = os.clock()
	local result = invoke("build", "autoPlace")

	if result and result.ok then
		print(string.format("[Auto] Auto-placed furniture (%d stored item(s)%s)", stored, noDesks and ", no desks yet" or ""))
	else
		storedPlaceBackoff = os.clock() + 20 -- nothing to place or no room: don't ask every few seconds
	end
end

-- ============================ Auto Design & Launch ============================
-- Designs the best phone the company can make (the studio's "Best I have" pick for every part), prices it
-- like the studio's "Suggested" / "Just under premium" chips, starts development (call "startDev"),
-- then plans the launch through the game's own launch window (Plan the launch -> LAUNCH!).
-- Only starts a NEW design once there's nothing left to research (when Auto Research is on).

local INCLUDE_FEATURES = true -- switch on every feature you've researched
local RETRY_AFTER = 30 -- seconds to wait after a rejected design/launch before trying again

-- Copy tracking: the launch result has { similar = true, similarTo = "<older product>" } when buyers see a copy.
-- The game judges "copy" by shared TECH (parts, features, cameras), not looks: critics drop and sales fall.
-- So the next design is steered to a different device (if the dropdown allows), and every candidate design is
-- scored with Economy.copyTarget (see the profit model below).
local lastLaunchWasCopy = false
local lastDesign -- { device } of the last design this script started

local function noteLaunchResult(data)
	if type(data) ~= "table" then
		return
	end

	lastLaunchWasCopy = data.similar == true

	if lastLaunchWasCopy then
		print("[Auto] That launch was seen as a copy of the " .. tostring(data.similarTo) .. ". The next design will be different.")
	end
end

-- The launch window passes its result to Ceremony.play(app, data); watch that call
local ceremonyHooked = false

local function hookCeremony()
	if ceremonyHooked then
		return
	end

	local ceremony = findGameModule("Ceremony", "play")

	if not ceremony then
		return
	end

	ceremonyHooked = true
	local originalPlay = ceremony.play
	local patchedPlay

	patchedPlay = function(app, data, ...)
		if running then
			pcall(noteLaunchResult, data)
		end

		return originalPlay(app, data, ...)
	end

	ceremony.play = patchedPlay

	-- put the game's own function back at shutdown (unless something else replaced it since)
	ctx:OnCleanup(function()
		if ceremony.play == patchedPlay then
			ceremony.play = originalPlay
		end
	end)
end

-- Same rule as the studio's "Best I have": highest tier that's unlocked and out by this year
local function bestOption(categoryId, state, currentYear)
	local best

	for _, option in Config.Options[categoryId] do
		if Economy.isUnlocked(option, state.researched) and option.year <= currentYear and (not best or option.tier > best.tier) then
			best = option
		end
	end

	return best
end

-- Device from the dropdown: the studio's default, a random unlocked one, or one specific device (if unlocked)
local function chooseDevice(state, currentYear)
	local order = Economy.deviceOrder()
	local unlocked = {}

	for _, device in order do
		if Economy.deviceUnlocked(device, state.researched, currentYear, state) then
			table.insert(unlocked, device)
		end
	end

	local choice = Settings.device

	-- Last launch was a copy: switch to another device, unless one specific device was picked in the dropdown
	if lastLaunchWasCopy and lastDesign and choice ~= "profit" and (choice == "first" or choice == "random" or not table.find(unlocked, choice)) then
		local others = {}

		for _, device in unlocked do
			if device ~= lastDesign.device then
				table.insert(others, device)
			end
		end

		if #others > 0 then
			return choice == "random" and others[math.random(#others)] or others[1]
		end
	end

	if choice == "random" and #unlocked > 0 then
		return unlocked[math.random(#unlocked)]
	end

	if choice ~= "first" and choice ~= "random" and table.find(unlocked, choice) then
		return choice
	end

	return order[1]
end

-- ================================ Profit model ================================
-- Built from what the studio itself shows (DesignStudio): unit cost ("To make one"), the hidden critic estimate,
-- the fair "Suggested" price from it, and the copy penalty (Economy.copyTarget: critics -X, sales -Y%).
-- Three studio hints drive the choices below:
--   * "Size does not change reviews. Bigger screens cost more to make"   -> smallest screen (not foldables)
--   * Specs "Every upgrade adds to the unit cost" / features cost per unit  -> keep a part/feature only if it
--     raises per-unit profit at the fair price
--   * "New technology, features or camera hardware make it feel fresh"   -> a design sharing tech with an older
--     product is scored down, so the optimizer prefers fresher parts/features or another device

local function unitCostOf(design, state, currentYear)
	return (Economy.unitCost(design, currentYear, Economy.costEffects(state)))
end

local function criticEstimate(design, state, currentYear)
	local techScore = Economy.techScore(design, currentYear, Economy.tierBonus(state))
	local designScore = Economy.designScore(design, currentYear)

	return math.clamp(Economy.criticCurve(10 * (0.5 * techScore + 0.22 * designScore + 0.21)) - 0.6, 1, 10)
end

local function copyPenaltyOf(design, state)
	local ok, _, _, penalty = pcall(Economy.copyTarget, state, design)

	return ok and tonumber(penalty) or 0
end

local evaluations = 0

-- Per-unit profit at the fair price after the copy penalty (critics and sales). Higher is better.
local function profitScore(design, state, currentYear)
	evaluations = evaluations + 1

	if evaluations % 40 == 0 then
		task.wait() -- keep the game responsive while searching
	end

	local penalty = copyPenaltyOf(design, state)
	local estimate = math.clamp(criticEstimate(design, state, currentYear) - Config.SIMILAR_CRITIC_PENALTY * penalty, 1, 10)
	local price = math.min(Config.PRICE_CAP, math.floor(Economy.valuePrice(estimate, currentYear, design.device)))
	local margin = price - unitCostOf(design, state, currentYear)
	local salesMultiplier = 1 - (1 - Config.SIMILAR_SALES_MULT) * penalty

	return margin > 0 and margin * salesMultiplier or margin
end

local function snapshot(design)
	local copy = table.clone(design)
	copy.specs = table.clone(design.specs or {})
	copy.features = table.clone(design.features or {})

	return copy
end

-- Starts from "Best I have" for every part and keeps a change only when it raises profitScore by more than 0.5%
-- (ties keep the higher tier / the feature). Returns the final score, or nil if the search failed.
local function optimizeDesign(design, state, currentYear)
	local backup = snapshot(design)

	local ok, finalScore = pcall(function()
		local best = profitScore(design, state, currentYear)

		local function better(score)
			return score > best + math.abs(best) * 0.005
		end

		for _ = 1, 2 do
			local improved = false

			for _, category in Economy.catsFor(design.device) do
				local current = design.specs[category.id]
				local winner = current

				for _, option in Config.Options[category.id] do
					if option.id ~= current and Economy.isUnlocked(option, state.researched) and option.year <= currentYear then
						design.specs[category.id] = option.id
						local score = profitScore(design, state, currentYear)

						if better(score) then
							best = score
							winner = option.id
						end
					end
				end

				design.specs[category.id] = winner
				improved = improved or winner ~= current
			end

			for _, feature in Config.Features do
				if state.researched[feature.research] and feature.year <= currentYear and Economy.featureFor(feature, design.device) then
					local function flip()
						local index = table.find(design.features, feature.id)

						if index then
							table.remove(design.features, index)
						else
							table.insert(design.features, feature.id)
						end
					end

					flip()
					local score = profitScore(design, state, currentYear)

					if better(score) then
						best = score
						improved = true
					else
						flip() -- undo
					end
				end
			end

			if not improved then
				break
			end
		end

		return best
	end)

	if not ok then
		warn("[Auto] Design optimizer failed, using the plain best parts: " .. tostring(finalScore))

		for key, value in backup do
			design[key] = value
		end

		return nil
	end

	return finalScore
end

-- One device's best design: "Best I have" parts, newest chassis/style, smallest screen, researched features,
-- then the profit optimizer. Returns the design and its profit score.
local function buildDesignFor(device, state, currentYear)
	local design = Economy.defaultDesign(device, currentYear)

	if Economy.usesChassis(device) then
		design.chassis = Economy.bestChassis(state.researched, currentYear).id
	end

	if Economy.stylesFor(device) then
		design.style = Economy.bestStyle(device, currentYear)
	end

	design.specs = design.specs or {}

	for _, category in Economy.catsFor(device) do
		local option = bestOption(category.id, state, currentYear)

		if option then
			design.specs[category.id] = option.id
		end
	end

	if not Economy.isObject(device) then
		local info = Economy.device(device)

		if Economy.base(device) == "foldable" then
			-- a foldable's size follows its fold style, keep the default
			design.screenW = math.clamp(design.screenW, info.minW, info.maxW)
			design.screenH = math.clamp(design.screenH, info.minH, info.maxH)
		else
			-- size doesn't change reviews but costs money: as small as allowed
			design.screenW = info.minW
			design.screenH = info.minH
		end

		design.bezel = math.clamp(design.bezel, Economy.bezelMin(state.researched), 0.5)
	end

	design.features = {}

	if INCLUDE_FEATURES then
		for _, feature in Config.Features do
			if state.researched[feature.research] and feature.year <= currentYear and Economy.featureFor(feature, device) then
				table.insert(design.features, feature.id)
			end
		end
	end

	return design, optimizeDesign(design, state, currentYear)
end

local function buildDesign(state)
	local currentYear = Economy.year(state.day)
	local design

	if Settings.device == "profit" then
		-- try every unlocked device and keep the one that earns the most per unit
		local bestScore

		for _, device in Economy.deviceOrder() do
			if Economy.deviceUnlocked(device, state.researched, currentYear, state) then
				local ok, candidate, score = pcall(buildDesignFor, device, state, currentYear)

				if ok and candidate and score and (not bestScore or score > bestScore) then
					design, bestScore = candidate, score
				end
			end
		end
	end

	design = design or buildDesignFor(chooseDevice(state, currentYear), state, currentYear)
	design.name = string.sub(string.format("%s %d", state.companyName or "Nova", #(state.phones or {}) + 1), 1, 24)

	return design, currentYear
end

-- The studio's price chips: "Suggested" = value price, "Just under premium" = 1.5x of it (both capped)
local function choosePrice(design, state, currentYear)
	local estimate = criticEstimate(design, state, currentYear)
	local suggested = math.min(Config.PRICE_CAP, math.floor(Economy.valuePrice(estimate, currentYear, design.device)))
	local budget = design.line == "budget" and Economy.lineOk(design.device)
	local cap = budget and Economy.budgetCap(design.device, currentYear) or Config.PRICE_CAP

	if budget then
		suggested = math.max(1, math.min(cap, math.floor(suggested * 0.5)))
	end

	local premium = math.max(1, math.min(cap, math.floor(suggested * 1.5)))

	if Settings.pricing == "premium" and suggested < premium then
		return premium
	end

	return suggested
end

-- Same marketing pick as the launch window's default
local function chooseMarketing(state)
	local currentYear = Economy.year(state.day)
	local forecast = invoke("forecast")
	local weekly = forecast and forecast.ok and forecast.data and tonumber(forecast.data.weekly) or 0
	local profit = (tonumber(state.dev.price) or 0) - (tonumber(state.dev.unitCost) or 0)
	local budget = weekly * math.max(0, profit) * 2
	local chosen = "none"

	for _, marketing in Config.Marketing do
		local cost = Economy.marketingCost(marketing, currentYear)

		if cost <= state.money * 0.2 and cost <= budget then
			chosen = marketing.id
		end
	end

	return chosen
end

local launching = false
local launchBackoff = 0
local designBackoff = 0
local lastDesignDay -- in-game day the last design was started by this script

local function launchPhone(state)
	if launching then
		return
	end

	launching = true
	launchBackoff = os.clock() + RETRY_AFTER

	local playerGui = Players.LocalPlayer.PlayerGui
	local windowOpened = false

	if clickButton("Plan the launch") then
		local deadline = os.clock() + 6

		while running and os.clock() < deadline and not playerGui:FindFirstChild("LaunchSetup", true) do
			task.wait(0.25)
		end

		windowOpened = playerGui:FindFirstChild("LaunchSetup", true) ~= nil

		if windowOpened then
			task.wait(0.5)

			if clickButton("LAUNCH!") then
				print("[Auto] Launched " .. tostring(state.dev.name or "the phone"))
			else
				clickButton("Not yet") -- the button says "Can't afford"
				warn("[Auto] Can't afford the launch yet, will retry.")
			end
		end
	end

	if not windowOpened then
		-- Launch window unavailable (e.g. button not on screen): call the server like the window does
		local result = invoke("launch", chooseMarketing(state))

		if result and result.ok then
			noteLaunchResult(result.data)
			print("[Auto] Launched via server call")
		else
			warn("[Auto] Launch refused: " .. tostring(result and result.msg or "no response"))
		end
	end

	launching = false
end

-- Idle RP has no better use once research is done: the dev card's "+ quality" and "Fix bugs" buttons spend it.
-- Same enable rules as those buttons (affordable, quality under its cap, bugs left).
local function boostDevelopment(state)
	local dev = state.dev
	local currentYear = Economy.year(state.day)
	local cost = Economy.rpBoostCost(currentYear)
	local rp = state.rp

	if rp >= cost and dev.blue < Economy.expectedBlue(dev.daysTotal or 1, currentYear) * 1.1 - 0.01 then
		invoke("rpBoost", "quality")
		rp = rp - cost
	end

	if rp >= cost and dev.red >= 0.5 then
		invoke("rpBoost", "bugs")
	end
end

-- Bugs lower the score at launch and waiting removes them (at the price of wages). Launch once the easy bugs are
-- gone, once only tough ones remain with nobody senior to fix them, or after READY_WAIT_DAYS regardless.
local READY_WAIT_DAYS = 5
local readySince

local function readyToLaunch(state)
	local dev = state.dev
	readySince = readySince or state.day

	local bugs = dev.red or 0
	local tough = dev.hard or 0
	local easy = bugs - tough

	if easy < 0.5 and (tough < 0.5 or not dev.hasMaster) then
		return true
	end

	return state.day - readySince >= READY_WAIT_DAYS
end

local function autoDesign(state, researchPending)
	local dev = state.dev

	if dev then
		if not researchPending then
			pcall(boostDevelopment, state)
		end

		if dev.phase ~= "dev" and not launching and os.clock() >= launchBackoff and readyToLaunch(state) then
			task.spawn(launchPhone, state)
		end

		return
	end

	readySince = nil

	if researchPending or os.clock() < designBackoff or not Economy.canStartDev(state) or #state.employees == 0 then
		return
	end

	-- Wait out the chosen number of in-game days since the last design started
	if lastDesignDay and state.day - lastDesignDay < (tonumber(Settings.designInterval) or 0) then
		return
	end

	local design, currentYear = buildDesign(state)
	local valid, problem = Economy.validate(design, state.researched, currentYear, state)

	if not valid or Economy.designPassProblem(design, state) then
		designBackoff = os.clock() + RETRY_AFTER
		warn("[Auto] Design rejected: " .. tostring(problem or "needs a game pass"))
		return
	end

	local price = choosePrice(design, state, currentYear)
	local unitCost = unitCostOf(design, state, currentYear)

	-- Never start a design that would lose money on every sale ("You'd lose money on every one sold.")
	if price <= unitCost then
		designBackoff = os.clock() + RETRY_AFTER
		warn(string.format("[Auto] Skipped %s: price %s is not above the cost to make one (%s).", design.name, tostring(price), tostring(math.floor(unitCost))))
		return
	end

	local result, err = invoke("startDev", design, price)

	if result and result.ok then
		lastDesignDay = state.day
		lastDesign = { device = design.device }
		lastLaunchWasCopy = false -- handled for this design; the next launch result sets it again
		print(string.format("[Auto] Development started: %s at %s", design.name, tostring(price)))
	else
		designBackoff = os.clock() + RETRY_AFTER
		warn("[Auto] startDev refused: " .. tostring(result and result.msg or err or "no response"))
	end
end

-- ================================== Main loop ==================================

-- ============================== Auto Claim Candy ==============================
-- The Halloween candy event (AdminEvents.Horde) shows tappable targets as TextButtons named
-- "Zombie_<packetId>" in PlayerGui.ZombieTargets. Tapping one runs
-- Remotes.Action:InvokeServer(claim or "claimPacket", packetId). Targets expire after ~14s.

local claimedTargets = {}

local function claimCandyTargets()
	local targets = Players.LocalPlayer.PlayerGui:FindFirstChild("ZombieTargets")

	if not targets then
		return
	end

	for _, button in targets:GetChildren() do
		local packetId = button:IsA("TextButton") and tonumber(string.match(button.Name, "^Zombie_(.+)$"))

		if packetId and not claimedTargets[packetId] then
			claimedTargets[packetId] = true

			-- Prefer the game's own tap (animations, rewards, its claim action); fall back to the raw call
			if not activate(button) then
				task.spawn(invoke, "claimPacket", packetId)
			end

			print("[Auto] Claimed candy target " .. packetId)
		end
	end
end

task.spawn(function()
	while running do
		if Settings.candy then
			local ok, err = pcall(claimCandyTargets)

			if not ok then
				warn("[Auto] Candy claim error: " .. tostring(err))
			end
		end

		task.wait(0.25)
	end
end)

-- ============================== Auto Close Popups ==============================
-- Dismisses the game's popups: the launch results screen ("Continue" in PhoneTycoonCinematic), the move-in
-- welcome card ("Later", only while Auto-Place is off so that feature can use the card), and generic offer
-- popups ("No thanks", "Not now", ...). Never clicks inside the Design Studio window or the launch window.
-- Add entries below for popups you want closed too.

local POPUPS = {
	{ container = "PhoneTycoonCinematic", texts = { ["Continue"] = true } },
	{ container = "MoveInCard", texts = { ["Later"] = true }, skipWhen = "autoPlace" },
	-- the Empire celebration overlay: the awards one ends with "Take a bow", the other empire moments with
	-- "Incredible" / "Legendary" (all from the Company panel's empire code)
	{ container = "EmpireMoment", texts = { ["Take a bow"] = true, ["Incredible"] = true, ["Legendary"] = true } },
}
local GENERIC_DISMISS = { ["No thanks"] = true, ["Not now"] = true, ["Maybe later"] = true, ["Got it"] = true }
local PROTECTED = { "LaunchSetup", "GameWindow", "NamePopup" } -- never auto-click inside these
local lastClicked = setmetatable({}, { __mode = "k" })

local function isShown(guiObject)
	local current = guiObject

	while current do
		if current:IsA("GuiObject") and not current.Visible then
			return false
		end

		if current:IsA("ScreenGui") and not current.Enabled then
			return false
		end

		current = current.Parent
	end

	return true
end

local function shouldDismiss(button)
	for _, name in PROTECTED do
		if button:FindFirstAncestor(name) then
			return false
		end
	end

	if GENERIC_DISMISS[button.Text] then
		return true
	end

	for _, popup in POPUPS do
		if popup.texts[button.Text] and button:FindFirstAncestor(popup.container) and not (popup.skipWhen and Settings[popup.skipWhen]) then
			return true
		end
	end

	return false
end

-- The "Sales run complete" popup comes from the SalesHud module (not in the dump), so find it by its title:
-- a visible label saying sales/run + complete, then press the dismiss-looking button next to it.
local DISMISS_WORDS = {
	["continue"] = true, ["close"] = true, ["ok"] = true, ["okay"] = true, ["done"] = true, ["nice"] = true,
	["awesome"] = true, ["great"] = true, ["collect"] = true, ["got it"] = true, ["thanks"] = true,
	["dismiss"] = true, ["x"] = true, ["×"] = true, ["✕"] = true, ["✖"] = true,
}
local loggedSummary = false

local function closeSalesSummary()
	local playerGui = Players.LocalPlayer.PlayerGui

	for _, descendant in playerGui:GetDescendants() do
		if descendant:IsA("TextLabel") and descendant.Text ~= "" and isShown(descendant) then
			local text = string.lower(descendant.Text)

			if string.find(text, "complete", 1, true) and (string.find(text, "sales", 1, true) or string.find(text, "run", 1, true)) then
				-- the popup is the nearest ancestor (a few levels up) that holds visible buttons
				local container = descendant.Parent

				for _ = 1, 5 do
					if not container or container == playerGui then
						break
					end

					local buttons = {}

					for _, candidate in container:GetDescendants() do
						if candidate:IsA("TextButton") and isShown(candidate) then
							table.insert(buttons, candidate)
						end
					end

					if #buttons > 0 then
						local choice

						for _, button in buttons do
							local buttonText = string.lower(button.Text)
							local buttonName = string.lower(button.Name)

							if DISMISS_WORDS[buttonText] or string.find(buttonName, "close", 1, true) or string.find(buttonName, "continue", 1, true) then
								choice = button
								break
							end
						end

						choice = choice or (#buttons == 1 and buttons[1] or nil)

						if choice and os.clock() - (lastClicked[choice] or -10) > 3 then
							lastClicked[choice] = os.clock()

							if activate(choice) then
								print(string.format("[Auto] Closed '%s' (button '%s')", descendant.Text, choice.Text))
							end
						elseif not choice and not loggedSummary then
							loggedSummary = true
							local found = {}

							for _, button in buttons do
								table.insert(found, string.format("%s '%s'", button.Name, button.Text))
							end

							warn(string.format("[Auto] Found '%s' but no dismiss button. Buttons: %s", descendant.Text, table.concat(found, ", ")))
						end

						return
					end

					container = container.Parent
				end
			end
		end
	end
end

-- Nudge toasts whose only button does something else ("Take a look" opens the Company tab, "Research" opens
-- the Research tab), so clicking would navigate. Remove them directly, like the game's own close() does.
local NUDGE_FRAMES = { "MoveNudge" } -- "You can move office"
local NUDGE_CAPTIONS = { ["new research available"] = true }

local function removeNudges()
	local playerGui = Players.LocalPlayer.PlayerGui

	for _, name in NUDGE_FRAMES do
		local frame = playerGui:FindFirstChild(name, true)

		if frame then
			frame:Destroy()
			print("[Auto] Closed popup: " .. name)
		end
	end

	for _, descendant in playerGui:GetDescendants() do
		if descendant:IsA("TextLabel") and NUDGE_CAPTIONS[string.lower(descendant.Text)] then
			local toast = descendant.Parent

			if toast and toast:IsA("GuiObject") then
				toast:Destroy()
				print("[Auto] Closed popup: " .. descendant.Text)
			end
		end
	end
end

local function closePopups()
	removeNudges()
	closeSalesSummary()

	for _, descendant in Players.LocalPlayer.PlayerGui:GetDescendants() do
		if descendant:IsA("TextButton") and descendant.Text ~= "" and os.clock() - (lastClicked[descendant] or -10) > 3 then
			if shouldDismiss(descendant) and isShown(descendant) then
				lastClicked[descendant] = os.clock()

				if activate(descendant) then
					print("[Auto] Closed popup: " .. descendant.Text)
				end
			end
		end
	end
end

task.spawn(function()
	while running do
		if Settings.closePopups then
			local ok, err = pcall(closePopups)

			if not ok then
				warn("[Auto] Popup close error: " .. tostring(err))
			end
		end

		task.wait(1)
	end
end)

-- ================================ Auto Train Staff ================================
-- The staff card's Train button runs App.call("train", employee.id) and costs Economy.trainCost(skill, year).
-- Skill tops out at 5. Lowest skill first (cheapest levels first), and never more than a set share of your cash
-- on one training so launches and payroll stay funded.

local TRAIN_MAX_CASH_FRACTION = 0.1
local trainBackoff = {} -- [employeeId] = os.clock() time to wait until after a refused training

local function trainStaff(state)
	local currentYear = Economy.year(state.day)
	local money = state.money
	local staff = {}

	for _, employee in state.employees do
		if employee.skill < 5 and os.clock() >= (trainBackoff[employee.id] or 0) then
			table.insert(staff, employee)
		end
	end

	table.sort(staff, function(a, b)
		return a.skill < b.skill
	end)

	for _, employee in staff do
		local cost = Economy.trainCost(employee.skill, currentYear)

		if cost <= money * TRAIN_MAX_CASH_FRACTION then
			local result = invoke("train", employee.id)

			if result and result.ok then
				money = money - cost
				print(string.format("[Auto] Trained %s (skill %d)", tostring(employee.name or employee.id), employee.skill))
			else
				trainBackoff[employee.id] = os.clock() + 30
			end
		end
	end
end

-- ================================ Auto Hire Staff ================================
-- The Staff panel (Panels module, not in the dump) sends the hire request, so, as with research:
--   * LEARN: hire ONE person by hand and the script records the call (any action named like "hire"/"recruit"),
--     including which argument is the candidate (matched against the candidates listed in your save).
--   * GUESS: otherwise it tries HIRE_CANDIDATES with the candidate's id.
-- It only hires while a desk is free (staff without a desk don't work, per the staff card) and while cash covers
-- HIRE_CASH_MONTHS of the new wage without using more than HIRE_MAX_CASH_FRACTION of your cash.

local HIRE_CANDIDATES = { "hire", "hireEmployee", "hireStaff", "recruit", "hireCandidate" }
local HIRE_CASH_MONTHS = 6
local HIRE_MAX_CASH_FRACTION = 0.25

local function looksLikePool(list)
	return type(list) == "table" and type(list[1]) == "table" and list[1].skill ~= nil and list[1].wage ~= nil
end

-- The list of people up for hire: a list of { skill, wage, ... } somewhere in the save (not the employees)
local function findCandidatePool(state)
	for key, value in state do
		if key ~= "employees" and type(value) == "table" then
			if looksLikePool(value) then
				return value, tostring(key)
			end

			for innerKey, inner in value do
				if looksLikePool(inner) then
					return inner, tostring(key) .. "." .. tostring(innerKey)
				end
			end
		end
	end

	return nil
end

local function trackCandidates(state)
	local ids = {}
	local pool = findCandidatePool(state)

	if pool then
		for _, candidate in pool do
			if candidate.id ~= nil then
				ids[candidate.id] = true
			end
		end
	end

	lastPoolIds = ids
end

-- Desks that are placed and allowed by the office level, minus people already on the team
local function freeDesks(state)
	if not Furniture then
		return 0
	end

	local desks = #Furniture.desks(state.office)
	local level = Config.OfficeLevels[state.officeLevel]
	local capacity = math.min(desks, level and level.desks or desks)

	return capacity - #state.employees
end

local hireActionName
local hireFailures = {}
local hireBackoff = 0
local lastHireStatus = 0

local function hireCandidate(candidate)
	if learnedHire then
		local args = table.clone(learnedHire.args)

		if learnedHire.idIndex then
			args[learnedHire.idIndex] = candidate.id
		end

		local result, err = invoke(table.unpack(args, 1, args.n))

		return result and result.ok, tostring(result and result.msg or err or "no response")
	end

	for _, name in hireActionName and { hireActionName } or HIRE_CANDIDATES do
		local result, err = invoke(name, candidate.id)

		if result and result.ok then
			hireActionName = name
			return true
		end

		hireFailures[name] = tostring(result and result.msg or err or "no response")
	end

	return false, "no hire call worked"
end

local function reportHireStatus(state, free, poolName, poolSize)
	if os.clock() - lastHireStatus < STATUS_EVERY then
		return
	end

	lastHireStatus = os.clock()

	print(string.format(
		"[Auto] hire waiting: free desks=%d, candidates=%s, cash=%s, hire call %s",
		free,
		poolName and (poolSize .. " in " .. poolName) or "NOT FOUND in the save",
		tostring(state.money),
		learnedHire and "learned" or (hireActionName and ("= " .. hireActionName) or "UNKNOWN, hire one person by hand")
	))

	if not learnedHire and not hireActionName then
		for name, message in hireFailures do
			print(string.format("    tried %s -> %s", name, message))
		end
	end
end

local function hireStaff(state)
	if os.clock() < hireBackoff then
		return
	end

	local free = freeDesks(state)

	if free <= 0 then
		return -- no desk for a new person
	end

	local pool, poolName = findCandidatePool(state)
	local best

	for _, candidate in pool or {} do
		local wage = tonumber(candidate.wage) or 0

		if wage * HIRE_CASH_MONTHS <= state.money * HIRE_MAX_CASH_FRACTION then
			if not best or candidate.skill > best.skill or (candidate.skill == best.skill and wage < (tonumber(best.wage) or 0)) then
				best = candidate
			end
		end
	end

	if not best then
		reportHireStatus(state, free, poolName, pool and #pool or 0)
		return
	end

	local ok, message = hireCandidate(best)

	if ok then
		print(string.format("[Auto] Hired %s (skill %s, wage %s)", tostring(best.name or best.id), tostring(best.skill), tostring(best.wage)))
	else
		hireBackoff = os.clock() + 30
		warn("[Auto] Hire refused: " .. tostring(message))
		reportHireStatus(state, free, poolName, pool and #pool or 0)
	end
end

-- ============================== Auto Sell Company ==============================
-- Selling the company ends the run and pays Legacy points (Company > Legacy > Sell company: "Selling now earns +N",
-- N from Economy.legacyPointsFor). The sale request is sent by the Company panel (not in the dump), so:
--   * LEARN: sell the company ONCE by hand. The script remembers the call, but only after your Legacy points
--     really went up, so a stray "sell" call (furniture, etc.) is never mistaken for it.
--   * Then, with the switch on, it repeats that call as soon as selling would earn at least `sellAt` points.
-- There is no guessing here on purpose: a wrong guess could sell something else, and selling the company can't be undone.

local SELL_COOLDOWN = 60 -- seconds between sale attempts
local sellBackoff = 0
local lastSellStatus = 0

-- Confirms a seen "sell" call by watching Legacy points go up afterwards
local function trackSell(state)
	local points = tonumber(state.legacyPoints) or 0

	if pendingSellCall then
		if points > pendingSellCall.pointsBefore then
			learnedSell = pendingSellCall
			pendingSellCall = nil
			print(string.format("[Auto] Learned the company-sale call: %s", tostring(learnedSell.args[1])))
		elseif os.clock() - pendingSellCall.at > 30 then
			pendingSellCall = nil
		end
	end

	lastLegacyPoints = points
end

local function autoSell(state)
	local ok, total = pcall(Economy.legacyPointsFor, state)
	total = ok and tonumber(total) or 0
	local target = tonumber(Settings.sellAt) or 5

	if total < target then
		return
	end

	if not learnedSell then
		if os.clock() - lastSellStatus >= STATUS_EVERY then
			lastSellStatus = os.clock()
			print(string.format(
				"[Auto] Sell waiting: selling now earns +%d Legacy points (target %d), but the sale call isn't known yet. Sell once by hand (Company > Legacy > Sell company) so it can be learned.",
				total, target
			))
		end

		return
	end

	if os.clock() < sellBackoff then
		return
	end

	sellBackoff = os.clock() + SELL_COOLDOWN

	local args = learnedSell.args
	local result, err = invoke(table.unpack(args, 1, args.n))

	if result and result.ok then
		print(string.format("[Auto] Sold the company for about +%d Legacy points", total))
	else
		warn("[Auto] Company sale refused: " .. tostring(result and result.msg or err or "no response"))
	end
end

-- ========================== Auto Spend Legacy Points ==========================
-- The Legacy > Perks page buys a perk rank with App.call("empire", "perk", perkId). Rank N of a perk costs N points,
-- a perk stops at its `max`, and Economy.perk(state, id) is the current rank (all from the Legacy panel code).
-- Each purchase picks a random perk that still has a rank left and is affordable, until the points run out.

local MAX_PERKS_PER_TICK = 5
local perkBackoff = 0

local function spendLegacyPoints(state)
	if os.clock() < perkBackoff then
		return
	end

	local points = tonumber(state.legacyPoints) or 0
	local ranks = {}

	for _, perk in Config.LegacyPerks do
		ranks[perk.id] = Economy.perk(state, perk.id)
	end

	local bought = 0

	while bought < MAX_PERKS_PER_TICK do
		local options = {}

		for _, perk in Config.LegacyPerks do
			local rank = ranks[perk.id]

			if rank < perk.max and rank + 1 <= points then
				table.insert(options, perk)
			end
		end

		if #options == 0 then
			return
		end

		local perk = options[math.random(#options)]
		local cost = ranks[perk.id] + 1
		local result, err = invoke("empire", "perk", perk.id)

		if result and result.ok then
			points = points - cost
			ranks[perk.id] = ranks[perk.id] + 1
			bought = bought + 1
			print(string.format("[Auto] Legacy perk: %s, now rank %d (%d point(s))", tostring(perk.name or perk.id), ranks[perk.id], cost))
		else
			perkBackoff = os.clock() + 30
			warn("[Auto] Legacy perk refused: " .. tostring(result and result.msg or err or "no response"))
			return
		end
	end
end

-- ====================== Auto Spend on Services / Factories / Megaprojects ======================
-- The Empire panel (require(script.Empire), not in the dump) sends these purchases with App.call("empire", ...), like
-- the perk shop does. Its action names are unknown, so, as with research and hiring:
--   * LEARN: buy ONE service / factory / megaproject by hand and the script records the call and which argument
--     is the item id (items are matched against the lists found in Config).
--   * GUESS: otherwise it tries the candidate action names below on the cheapest item.
-- Items come from the Config table whose name contains "service" / "factor" / "mega" (also looked for inside a
-- Config table named like "empire"). It buys cheapest first, never spending more than EMPIRE_MAX_CASH_FRACTION
-- of the cash on one purchase (when the item's cost is known).

do
local EMPIRE_MAX_CASH_FRACTION = 0.5
local MAX_EMPIRE_BUYS_PER_TICK = 3
local EMPIRE_COST_FIELDS = { "cost", "price", "baseCost", "buildCost", "buyCost" }

local EMPIRE_CATEGORIES = {
	{ key = "services", name = "Service", patterns = { "service" }, candidates = { "service", "buyService", "services", "launchService", "startService", "buy" } },
	{ key = "factories", name = "Factory", patterns = { "factor" }, candidates = { "factory", "buyFactory", "factories", "buildFactory", "build", "buy" } },
	{ key = "megaprojects", name = "Megaproject", patterns = { "mega" }, candidates = { "megaproject", "megaprojects", "mega", "buyMegaproject", "project", "buy" } },
	-- the Moon colony's systems (ColonyDistricts.luau: habitat, solar, o2plant, defense, extractor, pad, comms,
	-- battery). Building / upgrading one is App.call("upgradeSystem", id, false) (seen in a remote spy; it is
	-- pre-learned below). A table candidate is a full argument prefix for the id, a string one an "empire" action.
	{
		key = "districts", name = "District", patterns = { "district", "colony", "system" },
		ids = { "habitat", "solar", "o2plant", "comms", "battery", "extractor", "defense", "pad", "shield" },
		candidates = {
			{ "colony", "build" }, { "colony", "district" }, { "colony", "buy" }, { "colony", "upgrade" },
			{ "moon", "build" }, { "buildDistrict" }, { "colony" }, "district", "colony",
		},
	},
}

local function nameMatches(name, patterns)
	local lowered = string.lower(tostring(name))

	for _, pattern in patterns do
		if string.find(lowered, pattern, 1, true) then
			return true
		end
	end

	return false
end

local function itemCost(def)
	for _, field in EMPIRE_COST_FIELDS do
		if type(def[field]) == "number" then
			return def[field]
		end
	end

	return nil
end

-- Turns a Config table (array or id-keyed dictionary) into a list of { id, name, cost }, cheapest first
local function readItems(source)
	local items = {}

	for key, def in source do
		if type(def) == "table" then
			local id = def.id or (type(key) == "string" and key or nil)

			if id ~= nil then
				table.insert(items, { id = id, name = def.name or tostring(id), cost = itemCost(def), def = def })
			end
		end
	end

	table.sort(items, function(a, b)
		return (a.cost or math.huge) < (b.cost or math.huge)
	end)

	return items
end

local function findEmpireItems(category)
	if category.items then
		return category.items
	end

	local function search(container)
		for key, value in container do
			if type(value) == "table" and nameMatches(key, category.patterns) then
				local items = readItems(value)

				if #items > 0 then
					return items, tostring(key)
				end
			end
		end
	end

	local items, source = search(Config)

	if not items then
		for key, value in Config do
			if type(value) == "table" and nameMatches(key, { "empire" }) then
				items, source = search(value)

				if items then
					break
				end
			end
		end
	end

	if not items and category.ids then
		-- Config has no list for them: fall back to the district ids (cost unknown, tried in this order)
		items, source = {}, "built-in list"

		for _, id in category.ids do
			table.insert(items, { id = id, name = id })
		end
	end

	category.items = items or {}
	category.source = source
	category.idSet = {}

	for _, item in category.items do
		category.idSet[item.id] = true
	end

	return category.items
end

local FINISH_WORDS = { "finish", "rush", "complete", "speed", "instant" }

function Empire.classify(args)
	-- rushSystem(id) finishes a system under construction: kept apart from the build call
	if args[1] == "rushSystem" then
		Empire.learned.finish = { args = args, idIndex = 2 }
		task.defer(print, "[Auto] Learned district finish call: rushSystem(id)")
		return
	end

	-- a colony "finish / rush" call is kept apart from the build call
	if args[1] ~= "empire" and nameMatches(args[2], FINISH_WORDS) then
		local districts = EMPIRE_CATEGORIES[4]
		findEmpireItems(districts)

		for index = 2, args.n do
			if districts.idSet[args[index]] then
				Empire.learned.finish = { args = args, idIndex = index }
				task.defer(print, string.format("[Auto] Learned district finish call: %s/%s (id at arg %d)", tostring(args[1]), tostring(args[2]), index))
				return
			end
		end
	end

	for _, category in EMPIRE_CATEGORIES do
		findEmpireItems(category)

		local idIndex
		local actionMatches = nameMatches(args[2], category.patterns) or (args[1] ~= "empire" and nameMatches(args[1], category.patterns))

		for index = 2, args.n do
			if category.idSet[args[index]] then
				idIndex = index
				break
			end
		end

		if idIndex or actionMatches then
			Empire.learned[category.key] = { args = args, idIndex = idIndex }
			task.defer(print, string.format("[Auto] Learned %s call: %s/%s (item id %s)", category.name, tostring(args[1]), tostring(args[2]), idIndex and ("at arg " .. idIndex) or "not passed"))

			return
		end
	end
end

local function buyEmpireItem(category, item)
	local learnedCall = Empire.learned[category.key]

	if learnedCall then
		local args = table.clone(learnedCall.args)

		if learnedCall.idIndex then
			args[learnedCall.idIndex] = item.id
		end

		local result, err = invoke(table.unpack(args, 1, args.n))

		return result and result.ok, tostring(result and result.msg or err or "no response")
	end

	local lastMessage = "no response"

	for _, action in category.action and { category.action } or category.candidates do
		local prefix = type(action) == "table" and action or { "empire", action }
		local args = table.clone(prefix)
		table.insert(args, item.id)
		local result, err = invoke(table.unpack(args))

		if result and result.ok then
			category.action = action
			return true
		end

		lastMessage = tostring(result and result.msg or err or "no response")
		category.failures = category.failures or {}
		category.failures[table.concat(prefix, "/")] = lastMessage
	end

	return false, lastMessage
end

function Empire.spend(state, category)
	if os.clock() < (category.backoff or 0) then
		return
	end

	local items = findEmpireItems(category)

	if #items == 0 then
		category.backoff = os.clock() + 60
		warn(string.format("[Auto] No %s list found in Config, so Auto %s is idle.", string.lower(category.name), category.name))
		return
	end

	category.itemBackoff = category.itemBackoff or {}
	local money = tonumber(state.money) or 0
	local bought = 0
	local guessing = not Empire.learned[category.key] and not category.action

	for _, item in items do
		if bought >= MAX_EMPIRE_BUYS_PER_TICK then
			return
		end

		local affordable = not item.cost or item.cost <= money * EMPIRE_MAX_CASH_FRACTION

		if affordable and os.clock() >= (category.itemBackoff[item.id] or 0) then
			local ok, message = buyEmpireItem(category, item)

			if ok then
				bought = bought + 1
				money = money - (item.cost or 0)
				print(string.format("[Auto] Bought %s: %s", string.lower(category.name), tostring(item.name)))
			else
				category.itemBackoff[item.id] = os.clock() + 30

				if guessing then
					-- no call to repeat yet: don't try every item with every guessed name
					category.backoff = os.clock() + 60
					warn(string.format("[Auto] %s purchase failed (%s). Buy one %s by hand so the call can be learned.", category.name, message, string.lower(category.name)))

					for action, failure in category.failures or {} do
						print(string.format("    tried %s -> %s", action, failure))
					end

					return
				end
			end
		end
	end
end

-- ---- finishing districts (runs with Auto Build Colony Districts) ----
-- Under construction, a system can be rushed: App.call("rushSystem", id) (seen in a remote spy, pre-learned below). Two ways:
--   * that call, repeated for every system id (a system that isn't being built simply refuses and is skipped for 20s);
--   * the panel's own buttons: any visible button reading "Finish" / "Rush" / "Complete" / "Speed up" whose price
--     is cash ("$1.5M"), never Robux ("R$" or the Robux glyph), and within the same cash limits as buying.
local FINISH_BUTTON_WORDS = { "finish", "rush", "speed up", "complete" }
local SUFFIX = { k = 1e3, m = 1e6, b = 1e9, t = 1e12 }
local lastFinishClick = setmetatable({}, { __mode = "k" })
local finishBackoff = {}
local lastFinishCall = 0

local function cashCost(text)
	local digits, suffix = string.match(text, "%$%s*([%d,%.]+)%s*([KkMmBbTt]?)")
	local amount = digits and tonumber((string.gsub(digits, ",", "")))

	return amount and amount * (SUFFIX[string.lower(suffix)] or 1)
end

function Empire.finish(state)
	local money = tonumber(state.money) or 0
	local limit = money * EMPIRE_MAX_CASH_FRACTION

	local learnedCall = Empire.learned.finish

	if learnedCall and os.clock() - lastFinishCall >= 5 then
		lastFinishCall = os.clock()

		for _, item in findEmpireItems(EMPIRE_CATEGORIES[4]) do
			if os.clock() >= (finishBackoff[item.id] or 0) then
				local args = table.clone(learnedCall.args)
				args[learnedCall.idIndex] = item.id
				local result = invoke(table.unpack(args, 1, args.n))

				if result and result.ok then
					print("[Auto] Finished district: " .. tostring(item.name))
				else
					finishBackoff[item.id] = os.clock() + 20 -- nothing to finish there, or not affordable yet
				end
			end
		end
	end

	local playerGui = Players.LocalPlayer.PlayerGui

	for _, descendant in playerGui:GetDescendants() do
		if descendant:IsA("TextButton") and descendant.Text ~= "" and os.clock() - (lastFinishClick[descendant] or -10) > 5 then
			local text = descendant.Text

			if nameMatches(text, FINISH_BUTTON_WORDS) and not (string.find(text, "R%$") or string.find(text, utf8.char(57346), 1, true)) then
				local cost = cashCost(text)

				if cost and cost <= limit and isShown(descendant) and not descendant:FindFirstAncestor("LaunchSetup") then
					lastFinishClick[descendant] = os.clock()

					if activate(descendant) then
						print("[Auto] Pressed '" .. text .. "'")
					end
				end
			end
		end
	end
end

-- ---- Auto Moon Choices ----
-- When a Moon choice shows up, answer it with "yes". The choice window isn't in the dumps, so:
--   * a visible window/frame whose name contains "MoonChoice": press its affirmative button (Yes / Accept / Approve /
--     Confirm / ...), or the first button if none reads like a yes;
--   * a pending choice in the save (state.moonChoices / state.moonChoice): send the call with true.
local YES_WORDS = { "yes", "accept", "approve", "confirm", "agree", "allow", "do it", "go ahead", "fund", "ok" }
local lastChoiceClick = setmetatable({}, { __mode = "k" })
local choiceBackoff = 0
local choiceAction

function Empire.moonChoices(state)
	for _, descendant in Players.LocalPlayer.PlayerGui:GetDescendants() do
		if (descendant:IsA("Frame") or descendant:IsA("ScreenGui")) and nameMatches(descendant.Name, { "moonchoice" }) and isShown(descendant) then
			local buttons = {}
			local choice

			for _, button in descendant:GetDescendants() do
				if button:IsA("TextButton") and isShown(button) then
					table.insert(buttons, button)

					if not choice and button.Text ~= "" and nameMatches(button.Text, YES_WORDS) then
						choice = button
					end
				end
			end

			choice = choice or buttons[1]

			if choice and os.clock() - (lastChoiceClick[choice] or -10) > 3 then
				lastChoiceClick[choice] = os.clock()

				if activate(choice) then
					print("[Auto] Moon choice: pressed '" .. choice.Text .. "'")
				end
			end
		end
	end

	local pending = state.moonChoices or state.moonChoice

	if pending and (type(pending) ~= "table" or next(pending) ~= nil) and os.clock() >= choiceBackoff then
		choiceBackoff = os.clock() + 15

		for _, action in choiceAction and { choiceAction } or { "moonChoice", "moonChoices" } do
			local result = invoke(action, true)

			if result and result.ok then
				choiceAction = action
				print("[Auto] Moon choice: answered yes (" .. action .. ")")
				return
			end
		end
	end
end

-- ---- Auto Claim Contracts ----
-- A finished contract is claimed with App.call("claimContract", contractId) (seen in a remote spy: it pays He3 and RP).
-- Where the save keeps the contracts isn't in the dumps, so the list is looked for in state.contracts, then
-- state.colony / state.moon (a table whose name contains "contract"). An entry is tried when it isn't claimed and
-- not marked unfinished (done / complete / completed / ready / claimable = false); the server refuses early claims.
local DONE_FLAGS = { "done", "complete", "completed", "ready", "claimable" }
local contractBackoff = {}

local function findContracts(state)
	if type(state.contracts) == "table" then
		return state.contracts
	end

	for _, container in { state.colony, state.moon } do
		if type(container) == "table" then
			if type(container.contracts) == "table" then
				return container.contracts
			end

			for key, value in container do
				if type(value) == "table" and nameMatches(key, { "contract" }) then
					return value
				end
			end
		end
	end

	return nil
end

function Empire.claimContracts(state)
	local contracts = findContracts(state)

	if not contracts then
		return
	end

	for key, entry in contracts do
		local id = type(entry) == "table" and (entry.id or (type(key) == "number" and key or key)) or entry
		local finished = true

		if type(entry) == "table" then
			if entry.claimed or entry.claimedAt then
				finished = false
			end

			for _, flag in DONE_FLAGS do
				if entry[flag] == false then
					finished = false
				end
			end
		elseif type(entry) ~= "number" then
			finished = false
		end

		if finished and id ~= nil and os.clock() >= (contractBackoff[id] or 0) then
			local result = invoke("claimContract", id)

			if result and result.ok then
				print("[Auto] " .. tostring(result.msg or ("Claimed contract " .. tostring(id))))
			else
				contractBackoff[id] = os.clock() + 20 -- not finished yet (or already claimed)
			end
		end
	end
end

-- ---- Auto Expedition ----
-- Launching is App.call("launchExpedition", siteId, 1) (seen in a remote spy: "Selene is on its way to Shackleton
-- Crater. Back in 20 min, even if you leave."). The sites come from the Config table whose name contains
-- "expedition"; the best one is tried first (highest tier / level / reward / cost, whichever the entries have),
-- skipping sites whose research isn't done, and the next one is tried when the server refuses (locked, busy...).
-- Launch one by hand and its extra arguments are used from then on.
local EXPEDITION_SCORE_FIELDS = { "tier", "level", "reward", "rewards", "cost", "price", "days", "minutes", "duration" }
local EXPEDITION_LOCK_FIELDS = { "research", "requires", "tech", "unlock" }
local expeditionCategory = { patterns = { "expedition" }, ids = { "shackleton" } }
local expeditionBackoff = 0

local function expeditionScore(def)
	for _, field in EXPEDITION_SCORE_FIELDS do
		if type(def[field]) == "number" then
			return def[field]
		end
	end

	return 0
end

function Empire.sendExpedition(state)
	if os.clock() < expeditionBackoff then
		return
	end

	local sites = {}

	for index, item in findEmpireItems(expeditionCategory) do
		local locked = false

		for _, field in EXPEDITION_LOCK_FIELDS do
			local needed = item.def and item.def[field]

			if type(needed) == "string" and state.researched and not state.researched[needed] then
				locked = true
			end
		end

		if not locked then
			table.insert(sites, { item = item, score = item.def and expeditionScore(item.def) or 0, order = index })
		end
	end

	table.sort(sites, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end

		return a.order > b.order -- equal: later in the list is usually the harder site
	end)

	local base = Empire.learned.expedition and Empire.learned.expedition.args or table.pack("launchExpedition", "shackleton", 1)

	for tries, site in sites do
		if tries > 6 then
			break
		end

		local args = table.clone(base)
		args[2] = site.item.id
		local result = invoke(table.unpack(args, 1, args.n))

		if result and result.ok then
			print("[Auto] Expedition: " .. tostring(result.msg or site.item.name))
			expeditionBackoff = os.clock() + 60
			return
		end
	end

	expeditionBackoff = os.clock() + 45 -- one already out, nothing unlocked, or not affordable: try again later
end

-- ---- Auto Repair Systems ----
-- Repairing is App.call("repairSystem", systemId) (seen in a remote spy; it answers { ok = false } when there's
-- nothing to repair). Every colony system is tried in turn, each at most every REPAIR_EVERY seconds; right after a
-- meteor storm the wait is cleared so the damage is fixed at once.
local REPAIR_EVERY = 15
Empire.repairBackoff = {}

function Empire.repairSystems(state)
	for _, item in findEmpireItems(EMPIRE_CATEGORIES[4]) do
		if os.clock() >= (Empire.repairBackoff[item.id] or 0) then
			Empire.repairBackoff[item.id] = os.clock() + REPAIR_EVERY

			local result = invoke("repairSystem", item.id)

			if result and result.ok then
				print("[Auto] Repaired " .. tostring(item.name) .. (result.msg and (": " .. tostring(result.msg)) or ""))
			end
		end
	end
end

-- ---- Auto Destroy Meteors ----
-- The server announces a storm with Remotes.Event:FireClient("meteor", { count, rocks, report, ... }); the player
-- shoots the rocks in MoonFX (not in the dumps). So for METEOR_WINDOW seconds after the event it:
--   * fires moonShoot for every rock of the storm (see moonShootStorm), plus any other shot call that was learned
--     (a call named like meteor / shoot / laser / zap is recorded);
--   * presses every visible GUI button named like meteor / rock / asteroid;
--   * fires every ClickDetector on a workspace object named like that.
local METEOR_WINDOW = 25
local METEOR_NAMES = { "meteor", "asteroid", "rock" }
local meteorUntil = 0
local lastMeteorLog = 0
local storm -- { id, count, done = { [rock] = true } } of the storm being shot
local shotsSwapped = false -- moonShoot(storm, rock) is the assumed order; flips if the server refuses all of them

-- The player's shot is App.call("moonShoot", a, b) (seen in a remote spy: moonShoot(8, 7) -> { ok = true, value = 0 }).
-- The storm event carries an id and the rock count, so a = storm id and b = rock number is assumed: every rock of
-- the storm is shot once, and if the server refuses a whole pass the two arguments are swapped.
local function moonShootStorm()
	local refused, tried = 0, 0

	for rock = 1, storm.count do
		if not storm.done[rock] then
			tried = tried + 1
			local first, second = storm.id, rock

			if shotsSwapped then
				first, second = rock, storm.id
			end

			local result = invoke("moonShoot", first, second)

			if result and result.ok then
				storm.done[rock] = true
			else
				refused = refused + 1
			end
		end
	end

	if tried > 0 and refused == tried then
		shotsSwapped = not shotsSwapped
	end
end

local function shootMeteors()
	if storm then
		moonShootStorm()
	end

	local shoot = Empire.learned.shoot

	if shoot and shoot.args[1] ~= "moonShoot" then
		invoke(table.unpack(shoot.args, 1, shoot.args.n))
	end

	for _, descendant in Players.LocalPlayer.PlayerGui:GetDescendants() do
		if (descendant:IsA("TextButton") or descendant:IsA("ImageButton")) and nameMatches(descendant.Name, METEOR_NAMES) and isShown(descendant) then
			activate(descendant)
		end
	end

	if fireclickdetector then
		for _, descendant in workspace:GetDescendants() do
			if descendant:IsA("ClickDetector") and descendant.Parent and nameMatches(descendant.Parent.Name, METEOR_NAMES) then
				pcall(fireclickdetector, descendant)
			end
		end
	end
end

do
	local remotes = PhoneTycoon:FindFirstChild("Remotes")
	local eventRemote = remotes and remotes:FindFirstChild("Event")

	if eventRemote then
		Empire.eventConnection = ctx:Connect(eventRemote.OnClientEvent, function(kind, data)
			if kind == "meteor" and Settings.meteors and Empire.cur == Empire.moon then
				meteorUntil = os.clock() + METEOR_WINDOW
				table.clear(Empire.repairBackoff)

				if type(data) == "table" and data.id ~= nil then
					local rocks = type(data.rocks) == "table" and #data.rocks or 0
					storm = { id = data.id, count = math.max(tonumber(data.count) or 0, rocks), done = {} }
				end

				if os.clock() - lastMeteorLog > 5 then
					lastMeteorLog = os.clock()
					print(string.format("[Auto] Meteor storm (%s rocks): shooting", tostring(type(data) == "table" and data.count or "?")))
				end
			end
		end)
	else
		warn("[Auto] Remotes.Event not found: Auto Destroy Meteors is idle.")
	end

	task.spawn(function()
		while running do
			if os.clock() < meteorUntil and Settings.meteors then
				pcall(shootMeteors)
			end

			task.wait(0.2)
		end
	end)
end

Empire.categories = EMPIRE_CATEGORIES
Empire.nameMatches = nameMatches

-- from the spy: upgradeSystem("solar", false) starts the Solar Array ("about 9 days"); the id is argument 2
Empire.learned.districts = { args = table.pack("upgradeSystem", "solar", false), idIndex = 2 }

-- and rushSystem("comms") finishes one that's being built; Empire.finish repeats it for every system
Empire.learned.finish = { args = table.pack("rushSystem", "comms"), idIndex = 2 }
end

-- ============================== Auto Insurance Rescue ==============================
-- The bankrupt screen shows "Use insurance rescue" once the free investor rescue is used, the insurance pass is owned
-- and it hasn't been claimed yet; the button runs App.call("claimInsuranceRescue"). Same conditions here.

do
local nextClaim = 0

function Empire.insurance(state)
	if not state.bankrupt or not state.investorRescueUsed or state.insuranceRescueUsed or os.clock() < nextClaim then
		return
	end

	if not Economy.hasPass(state, "bankruptcyInsurance") then
		return
	end

	nextClaim = os.clock() + 10
	local result, err = invoke("claimInsuranceRescue")

	if result and result.ok then
		print("[Auto] Claimed the bankruptcy insurance rescue")
	else
		warn("[Auto] Insurance rescue refused: " .. tostring(result and result.msg or err or "no response"))
	end
end
end

-- ============================ Auto Upgrade Furniture ============================
-- From the Build module's own calls (build/attach, build/attachAll, build/place, build/store, build/sellStored):
--   * Chairs & PCs are "attachments" (def.attach = the field on a desk item that holds the attached id). Fitting a
--     better one is build/attach <deskUid> <id> (bought if not in storage). The replaced piece ends up in storage,
--     where build/sellStored <id> sells it.
--   * Tables are desks (def.desk). A better one is swapped in at the old one's spot: store the old desk, place the
--     new one there (build/place <id> x z r, bought if not in storage), re-fit what was attached, then sell the old
--     desk from storage. The swap is only attempted if Furniture.canPlace says the new one fits, and if the placing
--     fails the old desk is put back from storage.
-- Never goes into debt: a purchase must cost at most FURN_MAX_CASH_FRACTION of the cash and leave
-- FURN_RESERVE_MONTHS of wages. Seasonal, candy, pass-locked and not-yet-unlocked pieces are skipped.

do
local FURN_MAX_CASH_FRACTION = 0.3
local FURN_RESERVE_MONTHS = 3
local FURN_MAX_ATTACH_PER_TICK = 6

local GEAR_PATTERNS = { chairs = { "chair" }, computers = { "computer", "pc" } }
local nameMatches = Empire.nameMatches

local function usable(state, def)
	if type(def.price) ~= "number" or def.price <= 0 or def.candyPrice or def.wall then
		return false
	end

	if (def.office or 1) > (state.officeLevel or 1) or (def.season and not Config.seasonOpen(def.season)) then
		return false
	end

	return not (def.pass and not Economy.hasBundle(state, def.pass))
end

local function wagesTotal(state)
	local total = 0

	for _, employee in state.employees or {} do
		total = total + (tonumber(employee.wage) or 0)
	end

	return total
end

-- cash left after a purchase that is "safe": small share of the cash and wages still covered
local function budgetFor(state)
	local money = tonumber(state.money) or 0

	return money * FURN_MAX_CASH_FRACTION, money - wagesTotal(state) * FURN_RESERVE_MONTHS
end

local function affordable(price, maxSpend, spendable)
	return price <= maxSpend and price <= spendable
end

local function stored(state, id)
	return (state.office.storage or {})[id] or 0
end

local function isGear(def, patterns)
	if type(def.attach) ~= "string" or def.attach == "door" then
		return false
	end

	for _, field in { def.attach, def.cat, def.id, def.name } do
		if nameMatches(field, patterns) then
			return true
		end
	end

	return false
end

-- Chairs / PCs: fit the best affordable piece on every desk that doesn't have it yet, then sell leftovers
local function upgradeGear(state, familyKey)
	local patterns = GEAR_PATTERNS[familyKey]
	local desks = Furniture.desks(state.office)

	if #desks == 0 then
		return
	end

	local maxSpend, spendable = budgetFor(state)
	local attachKey
	local best

	for _, def in Furniture.ById do
		if isGear(def, patterns) and usable(state, def) and (not best or def.price > best.price) then
			if affordable(def.price, maxSpend, spendable) or stored(state, def.id) > 0 then
				best, attachKey = def, def.attach
			end
		end
	end

	if not best then
		return
	end

	local fitted = 0

	for _, desk in desks do
		if fitted >= FURN_MAX_ATTACH_PER_TICK then
			break
		end

		local current = Furniture.ById[desk[attachKey]]

		if desk[attachKey] ~= best.id and (not current or current.price < best.price) then
			local free = stored(state, best.id) > 0
			local safe = affordable(best.price, maxSpend, spendable)

			if free or safe then
				local result = invoke("build", "attach", desk.u, best.id)

				if result and result.ok then
					fitted = fitted + 1

					if not free then
						spendable = spendable - best.price
						maxSpend = maxSpend - best.price
					end
				end
			end
		end
	end

	if fitted > 0 then
		print(string.format("[Auto] Fitted %d x %s", fitted, tostring(best.name or best.id)))
	end

	-- leftovers of an older piece (replaced ones go to storage) are sold once no desk uses them
	local response = invoke("getState")
	local fresh = response and response.data

	if fresh and fresh.office then
		local inUse = {}

		for _, desk in Furniture.desks(fresh.office) do
			inUse[desk[attachKey]] = true
		end

		for id, count in table.clone(fresh.office.storage or {}) do
			local def = Furniture.ById[id]

			if def and id ~= best.id and count > 0 and isGear(def, patterns) and def.attach == attachKey and def.price < best.price and not inUse[id] then
				for _ = 1, count do
					local result = invoke("build", "sellStored", id)

					if not (result and result.ok) then
						break
					end
				end

				print("[Auto] Sold the old " .. tostring(def.name or id))
			end
		end
	end
end

-- First free floor spot where `def` can be placed (scans the room on a 1-unit grid, like the build ghost's snapping)
local function findSpot(state, def, r)
	local width, depth = Furniture.room(state.officeLevel)
	local dimX, dimZ = Furniture.dims(def, r)
	local zStart = -depth / 2 + (Furniture.BACK_CLEAR or 0) + dimZ / 2
	local tries = 0

	for rawZ = zStart, depth / 2 - dimZ / 2, 1 do
		for rawX = -width / 2 + dimX / 2, width / 2 - dimX / 2, 1 do
			local x = Furniture.snap(rawX, dimX, 1)
			local z = Furniture.snap(rawZ, dimZ, 1)
			tries = tries + 1

			if tries % 100 == 0 then
				task.wait()
			end

			if Furniture.canPlace(state.office, state.officeLevel, def, x, z, r) then
				return x, z
			end
		end
	end

	return nil
end

-- Tables: build the best affordable one until the office's desk limit is reached (the team is full), then swap the
-- cheapest desk for a better affordable one. One action per call.
local function upgradeTable(state)
	local desks = Furniture.desks(state.office)
	local maxSpend, spendable = budgetFor(state)
	local best

	for _, def in Furniture.ById do
		if def.desk and usable(state, def) and (not best or def.price > best.price) then
			if affordable(def.price, maxSpend, spendable) or stored(state, def.id) > 0 then
				best = def
			end
		end
	end

	if best and #desks < Furniture.deskCapacity(state) then
		local r = desks[1] and desks[1].r or 0
		local x, z = findSpot(state, best, r)

		local result = x and invoke("build", "place", best.id, x, z, r)

		if result and result.ok then
			print(string.format("[Auto] Built a table: %s (%d/%d desks)", tostring(best.name or best.id), #desks + 1, Furniture.deskCapacity(state)))
		end

		return
	end

	local oldDesk, oldDef

	for _, desk in desks do
		local def = Furniture.ById[desk.id]

		if best and def and def.price < best.price and (not oldDef or def.price < oldDef.price) then
			oldDesk, oldDef = desk, def
		end
	end

	if not oldDesk then
		return
	end

	local x, z, r = oldDesk.x, oldDesk.z, oldDesk.r

	local fits = pcall(function()
		assert(Furniture.canPlace(state.office, state.officeLevel, best, x, z, r, oldDesk.u))
	end)

	if not fits then
		return
	end

	-- remember what's fitted on the old desk, so it can be fitted on the new one
	local attached = {}

	for _, value in oldDesk do
		local def = type(value) == "string" and Furniture.ById[value]

		if def and def.attach then
			table.insert(attached, def.id)
		end
	end

	local function succeeded(result)
		return result and result.ok
	end

	if not succeeded(invoke("build", "store", oldDesk.u)) then
		return
	end

	if not succeeded(invoke("build", "place", best.id, x, z, r)) then
		-- put the old desk back from storage (free)
		invoke("build", "place", oldDef.id, x, z, r)
		warn("[Auto] Couldn't place the " .. tostring(best.name or best.id) .. ", kept the old table.")
		return
	end

	print(string.format("[Auto] Swapped %s for %s", tostring(oldDef.name or oldDef.id), tostring(best.name or best.id)))

	local response = invoke("getState")
	local fresh = response and response.data

	if not (fresh and fresh.office) then
		return
	end

	-- fit what was on the old desk onto the new one
	for _, item in fresh.office.items or {} do
		if item.id == best.id and item.x == x and item.z == z then
			for _, attachedId in attached do
				invoke("build", "attach", item.u, attachedId)
			end

			break
		end
	end

	-- the old desk is in storage now: sell it
	if stored(fresh, oldDef.id) > 0 then
		local result = invoke("build", "sellStored", oldDef.id)

		if succeeded(result) then
			print("[Auto] Sold the old table: " .. tostring(oldDef.name or oldDef.id))
		end
	end
end

function Empire.upgradeFurniture(state, familyKeys)
	if not Furniture or not state.office then
		return
	end

	for _, familyKey in familyKeys do
		local ok, err = pcall(familyKey == "tables" and upgradeTable or upgradeGear, state, familyKey)

		if not ok then
			warn("[Auto] Furniture upgrade error: " .. tostring(err))
		end
	end
end
end

task.spawn(function()
	print("[Auto] Running")

	while running do
		pcall(hookCeremony)

		local response = invoke("getState")
		local state = response and response.data

		if state and state.researched then
			-- the switches of the world the game is in (Toggles tab = Earth, Lunar tab = Moon)
			Empire.cur = state.world == "moon" and Empire.moon or Empire.earth

			if Empire.cur == Empire.moon then
				for _, key in { "sell", "perks", "insurance", "services", "factories", "megaprojects" } do
					Empire.moon[key] = false -- not part of the Lunar tab
				end

				if Settings.expedition then
					pcall(Empire.sendExpedition, state)
				end

				if Settings.repair then
					pcall(Empire.repairSystems, state)
				end

				if Settings.contracts then
					pcall(Empire.claimContracts, state)
				end

				if Settings.moonChoices then
					pcall(Empire.moonChoices, state)
				end
			end

			local affordable = affordableTechs(state)

			-- Auto Insurance Rescue (only acts on the bankrupt screen)
			if Settings.insurance then
				pcall(Empire.insurance, state)
			end

			-- Auto Research
			if Settings.research then
				if Economy.researchFree(state) and #affordable > 0 then
					if not startResearch(affordable[1]) then
						reportResearchStatus(state, affordable)
					end
				else
					reportResearchStatus(state, affordable)
				end
			end

			-- Auto Design & Launch (a new design only starts once there's nothing left to research)
			if Settings.design and not state.bankrupt then
				autoDesign(state, Settings.research and #affordable > 0)
			end

			pcall(trackSell, state) -- confirms a manual company sale, so it can be learned

			pcall(trackCandidates, state) -- remembers who is up for hire, so a manual hire can be learned

			-- Auto Hire Staff
			if Settings.hire and not state.bankrupt then
				pcall(hireStaff, state)
			end

			-- Auto Train Staff
			if Settings.train and not state.bankrupt then
				pcall(trainStaff, state)
			end

			-- Auto Sell Company (once selling would earn the chosen number of Legacy points)
			if Settings.sell and not state.bankrupt then
				pcall(autoSell, state)
			end

			-- Auto Spend Legacy Points (random perks, whenever a rank is affordable)
			if Settings.perks and not state.bankrupt then
				pcall(spendLegacyPoints, state)
			end

			-- Auto Spend on the Empire: Services, Factories, Megaprojects
			if not state.bankrupt then
				if Settings.upgradeGear then
					Empire.upgradeFurniture(state, { "chairs", "computers" })
				end

				if Settings.upgradeTables then
					Empire.upgradeFurniture(state, { "tables" })
				end

				for _, category in Empire.categories do
					if Settings[category.key] then
						local ok, err = pcall(Empire.spend, state, category)

						if category.key == "districts" then
							pcall(Empire.finish, state)
						end

						if not ok then
							warn("[Auto] Empire spend error: " .. tostring(err))
						end
					end
				end
			end

			-- Auto-Place Furniture, always: place whatever is in storage, and try when no desk is placed
			if Settings.autoPlace and not state.bankrupt then
				pcall(autoPlaceStored, state)
			end

			-- Auto Place (a move is waiting to be set up, e.g. you moved by hand) and Auto Move In
			if not state.bankrupt then
				-- a move is waiting to be set up, or the welcome card showed up late
				if state.moveIn or (Settings.autoPlace and moveInCard()) then
					task.spawn(autoPlace)
				end

				if Settings.moveIn then
					Panels = Panels or findPanels()

					if not Panels then
						if not warnedPanels then
							warnedPanels = true
							warn("[Auto] Couldn't find the Panels module (needs getloadedmodules): Auto Move In is idle.")
						end
					else
						local ok, status = pcall(Panels.moveStatus, state)

						if ok and status and status.ready then
							if moveOffice(status.next) then
								moveFailedRounds = 0
								task.spawn(autoPlace)
							else
								moveFailedRounds = moveFailedRounds + 1

								if moveFailedRounds == 3 and not moveActionName then
									warn("[Auto] None of the guessed move action names worked. Move once by hand with a remote spy running to find the real name, then set MOVE_CANDIDATES.")
								end
							end
						end
					end
				end
			end
		end

		task.wait(CHECK_INTERVAL)
	end
end)

-- ===================================== Panel =====================================
-- Two subtabs edit the two worlds' switches: Main = Earth (Empire.earth), Lunar = the Moon (Empire.moon).
-- Each toggle writes straight into its world's settings table; the loop above reads the world the game is in.

local OPTIONS = {
	{ key = "research", name = "Auto Research", hint = "Starts every affordable tech" },
	{ key = "moveIn", name = "Auto Move In", hint = "Moves when the next office is ready" },
	{ key = "autoPlace", name = "Auto-Place Furniture", hint = "Keeps stored furniture placed" },
	{ key = "candy", name = "Auto Claim Candy", hint = "Taps the candy targets that appear" },
	{ key = "design", name = "Auto Design & Launch", hint = "Designs, builds, launches (spends cash)" },
	{ key = "closePopups", name = "Auto Close Popups", hint = "Dismisses result and offer popups" },
	{ key = "train", name = "Auto Train Staff", hint = "Trains staff while cash allows" },
	{ key = "hire", name = "Auto Hire Staff", hint = "Fills free desks with new staff" },
	{ key = "sell", name = "Auto Sell Company", hint = "Sells for Legacy points (ends the run)", earthOnly = true },
	{ key = "perks", name = "Auto Spend Legacy Points", hint = "Buys random perks when affordable", earthOnly = true },
	{ key = "insurance", name = "Auto Insurance Rescue", hint = "Claims the rescue when bankrupt", earthOnly = true },
	{ key = "upgradeGear", name = "Auto Upgrade Chairs & PCs", hint = "Buys better, places it, sells the old" },
	{ key = "upgradeTables", name = "Auto Upgrade Tables", hint = "Best table you can afford, sells old one" },
	{ key = "services", name = "Auto Spend on Services", hint = "Empire: buys services, cheapest first", earthOnly = true },
	{ key = "factories", name = "Auto Spend on Factories", hint = "Empire: buys factories, cheapest first", earthOnly = true },
	{ key = "megaprojects", name = "Auto Spend on Megaprojects", hint = "Empire: funds megaprojects when affordable", earthOnly = true },
	{ key = "districts", name = "Auto Build Colony Districts", hint = "Moon: habitat, power, O2, comms, defense", lunarOnly = true },
	{ key = "expedition", name = "Auto Expedition", hint = "Moon: sends the best unlocked expedition", lunarOnly = true },
	{ key = "repair", name = "Auto Repair Systems", hint = "Moon: repairs every colony system (spends cash)", lunarOnly = true },
	{ key = "meteors", name = "Auto Destroy Meteors", hint = "Moon: shoots the meteors when a storm hits", lunarOnly = true },
	{ key = "contracts", name = "Auto Claim Contracts", hint = "Moon: claims finished contracts", lunarOnly = true },
	{ key = "moonChoices", name = "Auto Moon Choices", hint = "Moon: always says yes when a choice appears", lunarOnly = true },
}

local OPTION_BY_KEY = {}

for _, option in OPTIONS do
	OPTION_BY_KEY[option.key] = option
end

-- sections of a world's subtab, in order (options not meant for that world are skipped)
local SECTIONS = {
	{ title = "Automation", icon = "Lucide:bot", keys = { "research", "moveIn", "autoPlace", "candy", "design", "closePopups" } },
	{ title = "Staff", icon = "Lucide:users", keys = { "train", "hire" } },
	{ title = "Legacy", icon = "Lucide:gem", keys = { "sell", "perks", "insurance" } },
	{ title = "Furniture", icon = "Lucide:armchair", keys = { "upgradeGear", "upgradeTables" } },
	{ title = "Empire", icon = "Lucide:building", keys = { "services", "factories", "megaprojects" } },
	{ title = "Colony", icon = "Lucide:rocket", keys = { "districts", "expedition", "repair", "meteors", "contracts", "moonChoices" } },
}

-- Dropdowns for Auto Design: price ("Suggested" / "Just under premium") and style (best / random / specific)
local PRICING_CHOICES = {
	{ key = "suggested", name = "Suggested price" },
	{ key = "premium", name = "Just under premium" },
}

local function deviceChoices()
	local choices = {
		{ key = "first", name = "Default" },
		{ key = "random", name = "Random" },
		{ key = "profit", name = "Best margin" },
	}

	local ok, order = pcall(Economy.deviceOrder)

	if ok and type(order) == "table" then
		for _, device in order do
			local info = Economy.device(device)
			table.insert(choices, { key = device, name = info and info.name or tostring(device) })
		end
	end

	return choices
end

local INTERVAL_CHOICES = {
	{ key = 0, name = "No wait" },
	{ key = 7, name = "7 days" },
	{ key = 14, name = "14 days" },
	{ key = 30, name = "30 days" },
	{ key = 60, name = "60 days" },
	{ key = 90, name = "90 days" },
	{ key = 180, name = "180 days" },
	{ key = 365, name = "1 year" },
}

local SELL_CHOICES = {
	{ key = 2, name = "2+ Legacy points" },
	{ key = 4, name = "4+ Legacy points" },
	{ key = 5, name = "5+ Legacy points" },
	{ key = 6, name = "6+ Legacy points" },
	{ key = 8, name = "8+ Legacy points" },
	{ key = 10, name = "10+ Legacy points" },
	{ key = 15, name = "15+ Legacy points" },
}

local function addChoiceDropdown(tab, world, flag, text, description, choices, settingKey)
	local names, keyByName, nameByKey = {}, {}, {}

	for _, choice in choices do
		table.insert(names, choice.name)
		keyByName[choice.name] = choice.key
		nameByKey[choice.key] = choice.name
	end

	tab:AddDropdown({
		Text = text,
		Description = description,
		Icon = "Lucide:list",
		Options = names,
		Default = nameByKey[world[settingKey]] or names[1],
		Flag = flag,
		Callback = function(value)
			local key = keyByName[value]

			if key ~= nil then
				world[settingKey] = key
			end
		end,
	})
end

local function buildWorld(tab, world, flagPrefix, isMoon)
	for _, section in SECTIONS do
		local added = false

		for _, key in section.keys do
			local option = OPTION_BY_KEY[key]
			local shown = if isMoon then not option.earthOnly else not option.lunarOnly

			if shown then
				if not added then
					added = true
					tab:AddSection(section.title, section.icon)
				end

				tab:AddToggle({
					Text = option.name,
					Description = option.hint,
					Default = world[key] == true,
					Flag = flagPrefix .. key,
					Callback = function(value)
						world[key] = value
					end,
				})
			end
		end
	end

	tab:AddSection("Design Settings", "Lucide:settings")
	addChoiceDropdown(tab, world, flagPrefix .. "pricing", "Design Price", "Price chosen when Auto Design launches a phone", PRICING_CHOICES, "pricing")
	addChoiceDropdown(tab, world, flagPrefix .. "device", "Design Device", "Which device Auto Design builds", deviceChoices(), "device")
	addChoiceDropdown(tab, world, flagPrefix .. "designInterval", "Design Every", "Minimum in-game time between two designs", INTERVAL_CHOICES, "designInterval")

	if not isMoon then
		addChoiceDropdown(tab, world, flagPrefix .. "sellAt", "Sell Company At", "Legacy points to wait for before Auto Sell Company sells", SELL_CHOICES, "sellAt")
	end
end

buildWorld(ctx:SubTab("Main", "Lucide:house"), Empire.earth, "earth_", false)
buildWorld(ctx:SubTab("Lunar", "Lucide:moon"), Empire.moon, "moon_", true)
