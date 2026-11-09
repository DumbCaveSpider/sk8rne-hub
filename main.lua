-- Sk8rne Hub

local HUB = {
	Name = "Sk8rne Hub",
	Version = "1.0.0",
	LibraryUrl = "https://raw.githubusercontent.com/Skinny-yz/VVind-UI/refs/heads/main/src.lua",
	RepoUrl = "https://raw.githubusercontent.com/DumbCaveSpider/sk8rne-hub/refs/heads/main",
	WebsiteUrl = "https://arcticwoof.xyz/",
}

local genv = (getgenv and getgenv()) or _G

local function import(fileName)
	local url = HUB.RepoUrl .. "/" .. fileName
	local ok, source = pcall(function()
		return game:HttpGet(url)
	end)
	if not ok then
		return nil, "could not download " .. url .. ": " .. tostring(source)
	end
	if type(source) ~= "string" or source == "" or string.sub(source, 1, 1) == "<" then
		return nil, "no script found at " .. url
	end

	local chunk, compileError = loadstring(source, "=Sk8rne/" .. fileName)
	if not chunk then
		return nil, compileError
	end
	return chunk
end

local function requireCore(fileName)
	local chunk, err = import(fileName)
	if not chunk then
		error(err, 0)
	end
	return chunk()
end

-- 1. Clear out the previous session first: toggles off, loops, connections, hooks, attributes, window.
local runToken = {}
genv.__Sk8rneHubRun = runToken

do
	local previous = genv.__Sk8rneHub
	genv.__Sk8rneHub = nil
	if type(previous) == "table" and type(previous.Destroy) == "function" then
		pcall(previous.Destroy, previous)
	end
end

-- 2. Wait for the game, then download the hub's core files and the UI library.
if not game:IsLoaded() then
	game.Loaded:Wait()
end

local Players = game:GetService("Players")
while not Players.LocalPlayer do
	Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
end

local okCore, Games, Session, buildHubTabs = pcall(function()
	return requireCore("Games.luau"), requireCore("Session.luau"), requireCore("HubTabs.luau")
end)
if not okCore then
	warn("[Sk8rne Hub] " .. tostring(Games))
	return
end

local okLibrary, VindUI = pcall(function()
	return loadstring(game:HttpGet(HUB.LibraryUrl))()
end)
if not okLibrary or type(VindUI) ~= "table" then
	warn("[Sk8rne Hub] Could not load the UI library: " .. tostring(VindUI))
	return
end

-- A newer run started during the downloads; let that one win.
if genv.__Sk8rneHubRun ~= runToken then
	return
end

-- Also stop any panel started from the old standalone scripts.
for _, globalName in ipairs(Games.LegacyStops) do
	local stop = genv[globalName]
	genv[globalName] = nil
	if type(stop) == "function" then
		pcall(stop)
	end
end

-- 3. Build the window: the detected game's tab, then the two tabs every session has.
local gameDef = Games.Detect(game.PlaceId, game.GameId)
local GAME_TAB_NAME = "Main"

local Window = VindUI:CreateWindow({
	Title = HUB.Name,
	Subtitle = gameDef and gameDef.Name or "Unsupported Game",
	Icon = "Lucide:zap",
	Size = UDim2.fromOffset(680, 480),
	MinSize = Vector2.new(520, 380),
	Draggable = true,
	Resizable = true,
	UseBlur = true,
	DefaultTab = gameDef and GAME_TAB_NAME or "Hub Settings",
	ToggleKeybind = false, -- Handled by the rebindable key in Hub Settings
})

-- The About tab shows the exact build, so replace the version with the newest commit SHA.
local function fetchCommit()
	local endpoints = {
		"https://api.github.com/repos/DumbCaveSpider/sk8rne-hub/commits?per_page=1",
		"https://api.github.com/repos/DumbCaveSpider/sk8rne-hub/git/refs/heads/main",
	}
	for _, url in ipairs(endpoints) do
		local ok, body = pcall(function()
			return game:HttpGet(url)
		end)
		if ok and type(body) == "string" then
			local sha = body:match('"sha"%s*:%s*"([0-9a-f]+)"')
			if sha then
				return sha
			end
		end
	end
	return nil
end

do
	local commit = fetchCommit()
	HUB.Commit = commit or "unknown"
	HUB.Version = commit and string.sub(commit, 1, 7) or "unknown"
end

local session = Session.new(HUB, VindUI, Window, gameDef)
genv.__Sk8rneHub = session

if gameDef then
	session:AttachGameTab(Window:AddTab({ Name = GAME_TAB_NAME, Icon = gameDef.Icon }))
	Window:AddTabLine()
end

buildHubTabs(session, Games)
session:LoadHubConfig()

-- 4. Build the game module off the main thread: a module may wait on game instances, and the
-- console and settings tabs must stay usable while it does. Saved values are applied afterwards.
if gameDef then
	session.Log("Detected " .. gameDef.Name .. " (place " .. game.PlaceId .. ")")

	session:SetBuildThread(task.spawn(function()
		local finished = false
		task.delay(15, function()
			if not finished and not session.Destroyed then
				session.Log(gameDef.Name .. " is still waiting on game instances...", "warn")
			end
		end)

		local chunk, loadError = import(gameDef.Key .. ".luau")
		local ok, runError = false, loadError
		if chunk then
			ok, runError = xpcall(chunk, debug.traceback, session)
		end
		finished = true

		if session.Destroyed then
			return
		end

		if not ok then
			session.Log(gameDef.Name .. " failed to load:\n" .. tostring(runError), "error")
			session.Notify("Failed to load this game's features. See the Debug tab.", "error")
			session:ShowGameError(tostring(runError))
			Window:SelectTab("Debug")
			return
		end

		session:FinishGameTab()
		local restored = session:LoadGameConfig()
		Window:SelectTab(GAME_TAB_NAME)
		session.Notify(
			restored and "Loaded with your saved config." or "Loaded. No saved config yet.",
			"success"
		)
	end))
else
	session.Log("Place " .. game.PlaceId .. " is not a supported game", "warn")
	session.Notify("This game isn't supported. Hub settings are still available.", "warning")
	Window:SelectTab("Hub Settings")
end
