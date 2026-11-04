-- Trading Tycoon
local ctx = ...
local task = ctx.task

-- TradingPanel: toggle button that spams the TradeTap remote at an adjustable interval

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TradeTap = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("TradeTap")

local MIN_INTERVAL = 0.01
local MAX_INTERVAL = 5

local enabled = false
local interval = 0.1 -- seconds between calls
local runId = 0

-- Auto upgrade (uses the game's own modules, same call as the Upgrades panel button)
local Shared = ReplicatedStorage:WaitForChild("Shared")
local okMods, Upgrades, Net, ClientData = pcall(function()
	return require(Shared.Config.Upgrades),
		require(Shared.Net),
		require(Players.LocalPlayer.PlayerScripts.Controllers.ClientData)
end)

local upgradeEnabled = false
local upgradeRunId = 0
local UPGRADE_INTERVAL = 0.3

local function upgradePass()
	local data = ClientData.data
	if not data then return end
	for _, up in Upgrades.List do
		local id = up.id
		local level = data.upgrades[id] or 1
		local unlocked = not up.requires or data.built[up.requires]
		if unlocked and level < up.maxLevel and Upgrades.Cost(id, level) <= data.cash then
			pcall(function()
				Net.Get("UpgradeBuy"):InvokeServer(id)
			end)
		end
	end
end

local function startUpgrade()
	upgradeRunId = upgradeRunId + 1
	local myRun = upgradeRunId
	task.spawn(function()
		while ctx:Alive() and upgradeEnabled and upgradeRunId == myRun do
			pcall(upgradePass)
			task.wait(UPGRADE_INTERVAL)
		end
	end)
end

-- Auto train: picks a random built desk whose trader can be trained and is affordable
local okStaff, Build, Staff = pcall(function()
	return require(Shared.Config.Build), require(Shared.Config.Staff)
end)

local trainEnabled = false
local trainRunId = 0
local TRAIN_INTERVAL = 0.5

local function trainPass()
	local data = ClientData.data
	if not data then return end
	local candidates = {}
	for _, item in Build.Items do
		if item.kind == "desk" and data.built[item.id] then
			local member = data.staff[item.id]
			local level = member and (member.level or 0) or 0
			if member and level < Staff.MaxLevel and Staff.TrainCost(item.role, level) <= data.cash then
				table.insert(candidates, item.id)
			end
		end
	end
	if #candidates > 0 then
		local id = candidates[math.random(#candidates)]
		pcall(function()
			Net.Get("StaffAction"):InvokeServer(id)
		end)
	end
end

local function startTrain()
	trainRunId = trainRunId + 1
	local myRun = trainRunId
	task.spawn(function()
		while ctx:Alive() and trainEnabled and trainRunId == myRun do
			pcall(trainPass)
			task.wait(TRAIN_INTERVAL)
		end
	end)
end

local function tap()
	pcall(function()
		TradeTap:InvokeServer()
	end)
end

local function start()
	runId = runId + 1
	local myRun = runId
	task.spawn(function()
		while ctx:Alive() and enabled and runId == myRun do
			task.spawn(tap) -- don't let a slow server response stall the interval
			task.wait(interval)
		end
	end)
end

-- UI
local Main = ctx:SubTab("Main", "Lucide:house")

Main:AddSection("Trading", "Lucide:coins")
Main:AddToggle({
	Text = "Auto Tap",
	Description = "Fires the trade tap remote repeatedly",
	Icon = "Lucide:mouse-pointer-click",
	Default = false,
	Flag = "tt_auto_tap",
	Callback = function(value)
		enabled = value
		if enabled then
			start()
		end
	end,
})
Main:AddSlider({
	Text = "Tap Interval",
	Description = "Seconds between each tap",
	Icon = "Lucide:timer",
	Min = MIN_INTERVAL,
	Max = MAX_INTERVAL,
	Default = 0.1,
	Increment = 0.01,
	Suffix = "s",
	Flag = "tt_tap_interval",
	Callback = function(value)
		interval = math.clamp(value, MIN_INTERVAL, MAX_INTERVAL)
	end,
})

Main:AddSection("Automation", "Lucide:cog")
Main:AddToggle({
	Text = "Auto Upgrade",
	Description = "Buys every affordable upgrade",
	Icon = "Lucide:arrow-up",
	Default = false,
	Locked = not okMods,
	Flag = "tt_auto_upgrade",
	Callback = function(value)
		if value and not okMods then
			ctx.Notify("Upgrade modules failed to load", "error")
			return
		end
		upgradeEnabled = value
		if upgradeEnabled then
			startUpgrade()
		end
	end,
})
Main:AddToggle({
	Text = "Auto Train",
	Description = "Trains a random affordable trader",
	Icon = "Lucide:graduation-cap",
	Default = false,
	Locked = not (okMods and okStaff),
	Flag = "tt_auto_train",
	Callback = function(value)
		if value and not (okMods and okStaff) then
			ctx.Notify("Staff modules failed to load", "error")
			return
		end
		trainEnabled = value
		if trainEnabled then
			startTrain()
		end
	end,
})

ctx:OnCleanup(function()
	enabled, upgradeEnabled, trainEnabled = false, false, false
	runId, upgradeRunId, trainRunId = runId + 1, upgradeRunId + 1, trainRunId + 1
end)
