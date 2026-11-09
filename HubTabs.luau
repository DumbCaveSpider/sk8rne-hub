-- The two tabs every session has: Debug and Hub Settings.

local DEFAULT_TOGGLE_KEY = Enum.KeyCode.RightShift

-- Windows rejects these characters and trailing dots or spaces in file names.
local function safeFileName(name)
	local cleaned = name:gsub('[<>:"/\\|%?%*%c]', "_"):gsub("[%. ]+$", "")
	return cleaned ~= "" and cleaned or "_"
end

local function getDumpFolderName(session)
	local name = session.Game and session.Game.Name
	if not name then
		local ok, info = pcall(function()
			return game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId)
		end)
		name = ok and info and info.Name or tostring(game.PlaceId)
	end
	return safeFileName(name) .. "_dump"
end

-- Every dump loop calls the step function this returns. It yields for a frame once the current
-- frame has used FRAME_BUDGET seconds, so even a very large game keeps rendering while it dumps.
local FRAME_BUDGET = 0.008

local function newFrameBudget(session)
	local started = os.clock()
	return function()
		if os.clock() - started >= FRAME_BUDGET then
			session.task.wait()
			started = os.clock()
		end
	end
end

-- Marks each script and everything between it and the root, in one pass over the tree.
local function markScriptHolders(root, holders, step)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("LuaSourceContainer") then
			local current = descendant
			while current and current ~= root and not holders[current] do
				holders[current] = true
				current = current.Parent
			end
		end
		step()
	end
end

-- Plans the whole tree first so progress can be shown. Instances that hold no scripts are skipped,
-- and names that would collide on a case-insensitive disk get a number.
local function collectDumpEntries(parent, path, folders, scripts, holders, step)
	local used = {}
	local function uniqueName(name)
		local base = safeFileName(name)
		local candidate, count = base, 1
		while used[candidate:lower()] do
			count += 1
			candidate = base .. "_" .. count
		end
		used[candidate:lower()] = true
		return candidate
	end

	for _, child in ipairs(parent:GetChildren()) do
		if holders[child] then
			local name = uniqueName(child.Name)
			if child:IsA("LuaSourceContainer") then
				table.insert(scripts, { Instance = child, Path = path .. "/" .. name .. ".luau" })
			end
			local before = #folders + #scripts
			table.insert(folders, path .. "/" .. name)
			collectDumpEntries(child, path .. "/" .. name, folders, scripts, holders, step)
			if #folders + #scripts == before + 1 then
				table.remove(folders) -- A script whose children hold no other scripts needs no folder.
			end
		end
		step()
	end
end

local DUMP_IDLE_TEXT = "Dump Everything"
local MAX_FAILURE_LOGS = 20

-- A crash inside the executor's decompiler closes the game before anything can be logged. So the
-- dump writes what it is about to do to a progress file first. If that file is still there on the
-- next run, the step it names crashed, and that script goes on a skip list kept in the dump folder.
local PROGRESS_FILE = "_dump_progress.txt"
local CRASH_LIST_FILE = "_dump_skipped.txt"

local function readLines(path)
	local lines = {}
	if isfile and readfile and isfile(path) then
		for line in readfile(path):gmatch("[^\n]+") do
			table.insert(lines, line)
		end
	end
	return lines
end

local function setProgress(root, text)
	writefile(root .. "/" .. PROGRESS_FILE, text)
end

local function clearProgress(root)
	local path = root .. "/" .. PROGRESS_FILE
	if delfile and isfile and isfile(path) then
		delfile(path)
	else
		writefile(path, "")
	end
end

-- Returns the set of scripts to skip, adding the one the last run crashed on.
local function loadCrashList(session, root)
	local skipped = {}
	for _, name in ipairs(readLines(root .. "/" .. CRASH_LIST_FILE)) do
		skipped[name] = true
	end

	local progress = readLines(root .. "/" .. PROGRESS_FILE)[1]
	if progress then
		local crashedScript = progress:match("^decompiling (.+)$")
		if crashedScript and not skipped[crashedScript] then
			skipped[crashedScript] = true
			local names = {}
			for name in pairs(skipped) do
				table.insert(names, name)
			end
			table.sort(names)
			writefile(root .. "/" .. CRASH_LIST_FILE, table.concat(names, "\n"))
			session.Log("The last dump crashed while decompiling " .. crashedScript .. ". It will be skipped.", "warn")
		elseif not crashedScript then
			session.Log("The last dump crashed during: " .. progress, "warn")
		end
	end

	local count = 0
	for _ in pairs(skipped) do
		count += 1
	end
	if count > 0 then
		session.Log(string.format("Skipping %d script(s) listed in %s", count, CRASH_LIST_FILE), "warn")
	end
	return skipped
end

-- Each source is { Instance, Folder }: an instance to dump, saved under that path inside root.
-- Returns how many scripts were saved and how many were found.
local function dumpScripts(session, statusLine, root, sources, step, skipped)
	local folders, scripts = { root }, {}
	for _, source in ipairs(sources) do
		statusLine:Set("Scanning " .. source.Folder)
		setProgress(root, "scanning " .. source.Folder)
		local path = root
		for segment in source.Folder:gmatch("[^/]+") do
			path = path .. "/" .. segment
			if not table.find(folders, path) then
				table.insert(folders, path)
			end
		end
		local holders = {}
		markScriptHolders(source.Instance, holders, step)
		collectDumpEntries(source.Instance, path, folders, scripts, holders, step)
	end

	for _, folder in ipairs(folders) do
		if not isfolder(folder) then
			makefolder(folder)
		end
		step()
	end

	local failed = 0
	for index, entry in ipairs(scripts) do
		local fullName = entry.Instance:GetFullName()
		local ok, source
		if skipped[fullName] then
			ok, source = false, "skipped because it crashed an earlier dump"
		else
			-- One decompile per frame: a single large script can use a whole frame by itself.
			session.task.wait()
			setProgress(root, "decompiling " .. fullName)
			ok, source = pcall(decompile, entry.Instance)
		end
		if ok and type(source) == "string" then
			writefile(entry.Path, source)
		else
			failed += 1
			if failed <= MAX_FAILURE_LOGS then
				session.Log("Could not decompile " .. entry.Instance:GetFullName() .. ": " .. tostring(source), "warn")
			elseif failed == MAX_FAILURE_LOGS + 1 then
				session.Log("More scripts failed to decompile. Further failures won't be listed.", "warn")
			end
		end
		statusLine:Set(string.format("Dumping scripts %d/%d", index, #scripts))
		step()
	end

	return #scripts - failed, #scripts
end

-- Instance tree dump: lists what a script dump can't show, such as buttons, prompts and values.
local TREE_MAX_LINES = 100000
local TREE_MAX_VALUE_LENGTH = 200
local TREE_INTERESTING_CLASSES = {
	"ValueBase",
	"ClickDetector",
	"ProximityPrompt",
	"TouchTransmitter",
	"RemoteEvent",
	"RemoteFunction",
	"UnreliableRemoteEvent",
	"BindableEvent",
	"BindableFunction",
	"LuaSourceContainer",
	"TextLabel",
	"TextButton",
	"TextBox",
}

local function treeValueText(value)
	local text
	if typeof(value) == "Instance" then
		text = value:GetFullName()
	else
		text = tostring(value)
	end
	text = text:gsub("[\r\n]+", " ")
	if #text > TREE_MAX_VALUE_LENGTH then
		text = text:sub(1, TREE_MAX_VALUE_LENGTH) .. "..."
	end
	return text
end

local function isTreeInteresting(instance)
	for _, className in ipairs(TREE_INTERESTING_CLASSES) do
		if instance:IsA(className) then
			return true
		end
	end
	return next(instance:GetAttributes()) ~= nil
end

local function describeTreeInstance(instance)
	local line = string.format("%s [%s]", instance.Name, instance.ClassName)
	if instance:IsA("ValueBase") then
		line ..= " = " .. treeValueText(instance.Value)
	elseif instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
		line ..= ' text="' .. treeValueText(instance.Text) .. '"'
	elseif instance:IsA("ProximityPrompt") then
		line ..= string.format(
			' action="%s" object="%s" hold=%s range=%s',
			treeValueText(instance.ActionText),
			treeValueText(instance.ObjectText),
			tostring(instance.HoldDuration),
			tostring(instance.MaxActivationDistance)
		)
	elseif instance:IsA("ClickDetector") then
		line ..= " range=" .. tostring(instance.MaxActivationDistance)
	end

	local attributes = {}
	for name, value in pairs(instance:GetAttributes()) do
		table.insert(attributes, name .. "=" .. treeValueText(value))
	end
	if #attributes > 0 then
		table.sort(attributes)
		line ..= " {" .. table.concat(attributes, ", ") .. "}"
	end
	return line
end

-- Keeps files readable: an instance is listed only if it, or something inside it, is interesting.
-- Returns the number of lines saved and whether the file hit the line limit.
local function writeInstanceTree(root, path, skip, step)
	local keep = {}
	for _, descendant in ipairs(root:GetDescendants()) do
		local ok, interesting = pcall(isTreeInteresting, descendant)
		if ok and interesting and not (skip and skip(descendant)) then
			local current = descendant
			while current and current ~= root and not keep[current] do
				keep[current] = true
				current = current.Parent
			end
		end
		step()
	end

	local lines = { root:GetFullName() }
	local truncated = false

	local function visit(parent, depth)
		for _, child in ipairs(parent:GetChildren()) do
			if truncated then
				return
			end
			if keep[child] then
				local ok, line = pcall(describeTreeInstance, child)
				table.insert(lines, string.rep("  ", depth) .. (ok and line or child.Name .. " [unreadable]"))
				if #lines >= TREE_MAX_LINES then
					truncated = true
					table.insert(lines, "... stopped at the line limit")
					return
				end
				step()
				visit(child, depth + 1)
			end
		end
	end
	visit(root, 1)

	writefile(path, table.concat(lines, "\n"))
	return #lines, truncated
end

-- Returns the number of tree lines saved.
local function dumpInstanceTrees(session, statusLine, root, step)
	local Players = game:GetService("Players")
	local folder = root .. "/InstanceTree"
	for _, path in ipairs({ root, folder }) do
		if not isfolder(path) then
			makefolder(path)
		end
	end

	local function isInPlayerCharacter(instance)
		for _, player in ipairs(Players:GetPlayers()) do
			if player.Character and instance:IsDescendantOf(player.Character) then
				return true
			end
		end
		return false
	end

	local trees = {
		{ Name = "Workspace", Instance = workspace, Skip = isInPlayerCharacter },
		{ Name = "ReplicatedStorage", Instance = game:GetService("ReplicatedStorage") },
		{ Name = "LocalPlayer", Instance = Players.LocalPlayer },
	}

	local total = 0
	for _, tree in ipairs(trees) do
		statusLine:Set("Listing " .. tree.Name)
		setProgress(root, "listing the " .. tree.Name .. " tree")
		local count, truncated = writeInstanceTree(tree.Instance, folder .. "/" .. tree.Name .. ".txt", tree.Skip, step)
		total += count
		session.Log(
			string.format("%s tree: %d lines%s", tree.Name, count, truncated and " (stopped at the line limit)" or ""),
			truncated and "warn" or "info"
		)
	end
	return total
end

-- The script containers both dumps read from.
local function scriptSources()
	local StarterPlayer = game:GetService("StarterPlayer")
	local sources = {}
	for _, name in ipairs({ "StarterCharacterScripts", "StarterPlayerScripts" }) do
		local container = StarterPlayer:WaitForChild(name, 5)
		if container then
			table.insert(sources, { Instance = container, Folder = "StarterPlayer/" .. name })
		end
	end
	table.insert(sources, { Instance = game:GetService("ReplicatedStorage"), Folder = "ReplicatedStorage" })
	return sources
end

-- StarterPlayer and ReplicatedStorage scripts, then the instance trees, all in one dump folder.
local function dumpEverything(session, statusLine)
	local step = newFrameBudget(session)
	local root = getDumpFolderName(session)
	if not isfolder(root) then
		makefolder(root)
	end

	local skipped = loadCrashList(session, root)

	local saved, found = 0, 0
	if decompile then
		saved, found = dumpScripts(session, statusLine, root, scriptSources(), step, skipped)
		session.Log(string.format("Scripts: saved %d of %d", saved, found), saved < found and "warn" or "info")
	else
		session.Log("Your executor can't decompile, so scripts were skipped", "warn")
	end

	local treeLines = dumpInstanceTrees(session, statusLine, root, step)
	clearProgress(root)

	local summary = string.format("Saved %d of %d scripts and %d tree lines to workspace/%s", saved, found, treeLines, root)
	session.Log(summary)
	session.Notify(summary, saved < found and "warning" or "success", 8)
end

-- Only the StarterPlayer and ReplicatedStorage scripts, without the instance trees.
local function dumpScriptsOnly(session, statusLine)
	local step = newFrameBudget(session)
	local root = getDumpFolderName(session)
	if not isfolder(root) then
		makefolder(root)
	end

	local skipped = loadCrashList(session, root)

	if not decompile then
		session.Log("Your executor can't decompile, so scripts were skipped", "warn")
		return
	end

	local saved, found = dumpScripts(session, statusLine, root, scriptSources(), step, skipped)
	clearProgress(root)

	local summary = string.format("Saved %d of %d scripts to workspace/%s", saved, found, root)
	session.Log(summary, saved < found and "warn" or "info")
	session.Notify(summary, saved < found and "warning" or "success", 8)
end

local function buildDebugConsole(session)
	local Window = session.Window
	local tab = Window:AddTab({ Name = "Debug", Icon = "Lucide:terminal" })

	local Console = session:WrapTab(tab:AddSubTab({ Name = "Console", Icon = "Lucide:terminal" }), "Debug")

	local console = Console:AddConsole({
		Title = "Output",
		Height = 300,
		MaxLogs = 300,
		AutoCapture = false, -- Hub logs only; the game's prints flood the console otherwise
	})
	session:AttachConsole(console)

	Console:AddSection("Actions", "Lucide:wrench")
	Console:AddButton({
		Text = "Copy Hub Log",
		Description = "Copies hub messages and errors to the clipboard",
		Icon = "Lucide:copy",
		Callback = function()
			if setclipboard then
				setclipboard(session:GetLogText())
				session.Notify("Hub log copied.", "success")
			else
				session.Notify("Your executor has no clipboard support.", "error")
			end
		end,
	})
	Console:AddButton({
		Text = "Clear Console",
		Description = "Removes every line from the console and the hub log",
		Icon = "Lucide:trash-2",
		Callback = function()
			session:ClearLogs()
		end,
	})

	local dumpStatus = Console:AddLineText(DUMP_IDLE_TEXT)
	local dumpFolder = getDumpFolderName(session)
	local dumping = false

	local function startDumpTask(work)
		if dumping then
			session.Notify("A dump is already running.", "warning")
			return
		end
		if not (writefile and makefolder and isfolder) then
			session.Notify("Your executor can't write files.", "error")
			return
		end
		dumping = true
		session.task.spawn(function()
			local ok, err = pcall(work)
			dumping = false
			dumpStatus:Set(DUMP_IDLE_TEXT)
			if not ok then
				session.Log("Dump failed: " .. tostring(err), "error")
				session.Notify("The dump failed. See the console.", "error")
			end
		end)
	end

	Console:AddButton({
		Text = "Dump Everything",
		Description = "Saves StarterPlayer and ReplicatedStorage scripts plus the instance trees to workspace/"
			.. dumpFolder,
		Icon = "Lucide:folder-down",
		Callback = function()
			startDumpTask(function()
				dumpEverything(session, dumpStatus)
			end)
		end,
	})

	Console:AddButton({
		Text = "Dump Scripts Only",
		Description = "Saves only the StarterPlayer and ReplicatedStorage scripts to workspace/" .. dumpFolder,
		Icon = "Lucide:code",
		Callback = function()
			startDumpTask(function()
				dumpScriptsOnly(session, dumpStatus)
			end)
		end,
	})

	local Session = session:WrapTab(tab:AddSubTab({ Name = "Session", Icon = "Lucide:info" }), "Debug")
	Session:AddSystemInfoGrid({
		Title = "System Info",
		Description = "Current session data",
		Columns = 2,
	})

	pcall(function()
		tab:SelectSubTab(1)
	end)
end

local function buildHubSettings(session, Games)
	local VindUI, Window = session.VindUI, session.Window
	local tab = Window:AddTab({ Name = "Hub Settings", Icon = "Lucide:settings" })

	local General = session:WrapTab(tab:AddSubTab({ Name = "General", Icon = "Lucide:settings" }), "Hub")

	General:AddSection("Interface", "Lucide:keyboard")
	local toggleKey
	toggleKey = General:AddKeybind({
		Text = "Toggle UI Key",
		Description = "Shows or hides this panel. Click, then press a key",
		Icon = "Lucide:keyboard",
		Default = DEFAULT_TOGGLE_KEY,
		Flag = "hub_toggle_key",
		Callback = function(_, event)
			if event == "press" then
				Window:Toggle()
			end
		end,
	})
	-- Backspace unbinds a keybind, which would leave no way to reopen a hidden panel on PC.
	toggleKey:OnChanged(function(key)
		if key == nil then
			toggleKey:Set(DEFAULT_TOGGLE_KEY, true)
			session.Notify("The toggle key can't be empty. Reset to " .. DEFAULT_TOGGLE_KEY.Name .. ".", "warning")
		end
		session:MarkDirty()
	end)

	General:AddSection("Config", "Lucide:save")
	General:AddToggle({
		Text = "Auto Save",
		Description = "Saves your settings a moment after any change",
		Icon = "Lucide:refresh-cw",
		Default = true,
		Flag = "hub_autosave",
		Callback = function(enabled)
			session:SetAutoSave(enabled)
		end,
	})
	session:SetAutoSave(true)

	General:AddButton({
		Text = "Save Config",
		Description = "Saves this game's settings and the hub settings now",
		Icon = "Lucide:save",
		Callback = function()
			local ok, err = session:SaveConfig()
			session.Notify(ok and "Config saved." or ("Save failed: " .. tostring(err)), ok and "success" or "error")
		end,
	})
	General:AddButton({
		Text = "Load Config",
		Description = "Re-applies the last saved settings for this game",
		Icon = "Lucide:folder-open",
		Callback = function()
			local ok = session:LoadGameConfig()
			session.Notify(ok and "Config loaded." or "No saved config for this game yet.", ok and "success" or "warning")
		end,
	})
	General:AddButton({
		Text = "Reset Config",
		Description = "Restores this game's defaults and deletes its saved file",
		Icon = "Lucide:rotate-ccw",
		Callback = function()
			VindUI:Confirm({
				Window = Window,
				Title = "Reset Config?",
				Text = "This game's settings go back to their defaults and its saved file is deleted.",
				ConfirmText = "Reset",
				CancelText = "Cancel",
				Danger = true,
				Callback = function(confirmed)
					if confirmed then
						session:ResetGameConfig()
						session.Notify("Config reset.", "success")
					end
				end,
			})
		end,
	})

	General:AddSection("Session", "Lucide:power")
	General:AddButton({
		Text = "Unload Hub",
		Description = "Turns everything off and closes the panel. Your saved config is kept",
		Icon = "Lucide:power",
		Callback = function()
			session:Destroy()
		end,
	})

	local About = session:WrapTab(tab:AddSubTab({ Name = "About", Icon = "Lucide:info" }), "Hub")
	About:AddParagraph({
		Title = session.Hub.Name .. " " .. session.Hub.Version,
		Icon = "Lucide:zap",
		Text = session.Game and ("Running in " .. session.Game.Name .. ".")
			or "This game isn't supported, so only the hub tabs are available.",
	})
	About:AddParagraph({
		Title = "Commit",
		Icon = "Lucide:git-commit-horizontal",
		Text = tostring(session.Hub.Commit or session.Hub.Version or "unknown"),
	})

	About:AddSection("Changelog", "Lucide:history")
	About:AddChangelogEntry({
		Version = session.Hub.Name .. " " .. session.Hub.Version,
		Date = "Nov 5, 2026",
		Changes = {
			{ Type = "Added", Text = "18 games in one script, detected automatically" },
			{ Type = "Added", Text = "Debug and Hub Settings tabs" },
			{ Type = "Added", Text = "Saved settings for each game" },
			{ Type = "Added", Text = "Website: " .. session.Hub.WebsiteUrl },
		},
	})
	About:AddButton({
		Text = "Copy Website Link",
		Description = "Copies " .. session.Hub.WebsiteUrl .. " to the clipboard",
		Icon = "Lucide:link",
		Callback = function()
			if setclipboard then
				setclipboard(session.Hub.WebsiteUrl)
				session.Notify("Website link copied.", "success")
			else
				session.Notify("Your executor has no clipboard support.", "error")
			end
		end,
	})

	About:AddSection("Supported Games", "Lucide:gamepad-2")
	for _, def in ipairs(Games.List) do
		About:AddLabel(def.Name)
	end

	pcall(function()
		tab:SelectSubTab(1)
	end)
end

return function(session, Games)
	buildDebugConsole(session)
	buildHubSettings(session, Games)
end
