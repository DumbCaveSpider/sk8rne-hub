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

local function hasScripts(instance)
	if instance:IsA("LuaSourceContainer") then
		return true
	end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("LuaSourceContainer") then
			return true
		end
	end
	return false
end

-- Plans the whole tree first so progress can be shown. Instances that hold no scripts are skipped,
-- and names that would collide on a case-insensitive disk get a number.
local function collectDumpEntries(parent, path, folders, scripts)
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
		if hasScripts(child) then
			local name = uniqueName(child.Name)
			if child:IsA("LuaSourceContainer") then
				table.insert(scripts, { Instance = child, Path = path .. "/" .. name .. ".luau" })
			end
			if #child:GetChildren() > 0 then
				local folder = path .. "/" .. name
				local before = #folders + #scripts
				table.insert(folders, folder)
				collectDumpEntries(child, folder, folders, scripts)
				if #folders + #scripts == before + 1 then
					table.remove(folders) -- A script whose children hold no other scripts needs no folder.
				end
			end
		end
	end
end

local DUMP_IDLE_TEXT = "Dump Scripts"

-- Each source is { Instance, Folder }: an instance to dump, saved under that path inside the root.
local function dumpSources(session, statusLine, sources)
	local root = getDumpFolderName(session)
	local folders, scripts = { root }, {}
	for _, source in ipairs(sources) do
		local path = root
		for segment in source.Folder:gmatch("[^/]+") do
			path = path .. "/" .. segment
			if not table.find(folders, path) then
				table.insert(folders, path)
			end
		end
		collectDumpEntries(source.Instance, path, folders, scripts)
	end

	if #scripts == 0 then
		session.Log("No scripts found to dump", "warn")
		session.Notify("No scripts found to dump.", "warning")
		return
	end

	for _, folder in ipairs(folders) do
		if not isfolder(folder) then
			makefolder(folder)
		end
	end

	local failed = 0
	for index, entry in ipairs(scripts) do
		local ok, source = pcall(decompile, entry.Instance)
		if ok and type(source) == "string" then
			writefile(entry.Path, source)
		else
			failed += 1
			session.Log("Could not decompile " .. entry.Instance:GetFullName() .. ": " .. tostring(source), "warn")
		end
		statusLine:Set(string.format("Dumping %d/%d", index, #scripts))
		if index % 5 == 0 then
			session.task.wait()
		end
	end

	local summary = string.format("Saved %d of %d scripts to workspace/%s", #scripts - failed, #scripts, root)
	session.Log(summary, failed > 0 and "warn" or "info")
	session.Notify(summary, failed > 0 and "warning" or "success", 6)
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
local function writeInstanceTree(session, root, path, skip)
	local keep = {}
	for index, descendant in ipairs(root:GetDescendants()) do
		local ok, interesting = pcall(isTreeInteresting, descendant)
		if ok and interesting and not (skip and skip(descendant)) then
			local current = descendant
			while current and current ~= root and not keep[current] do
				keep[current] = true
				current = current.Parent
			end
		end
		if index % 5000 == 0 then
			session.task.wait()
		end
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
				if #lines % 5000 == 0 then
					session.task.wait()
				end
				visit(child, depth + 1)
			end
		end
	end
	visit(root, 1)

	writefile(path, table.concat(lines, "\n"))
	return #lines, truncated
end

local function dumpInstanceTrees(session, statusLine)
	local Players = game:GetService("Players")
	local localPlayer = Players.LocalPlayer
	local root = getDumpFolderName(session)
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
		{ Name = "LocalPlayer", Instance = localPlayer },
	}

	local total = 0
	for _, tree in ipairs(trees) do
		statusLine:Set("Listing " .. tree.Name)
		local count, truncated = writeInstanceTree(session, tree.Instance, folder .. "/" .. tree.Name .. ".txt", tree.Skip)
		total += count
		session.Log(
			string.format("%s: %d lines%s", tree.Name, count, truncated and " (stopped at the line limit)" or ""),
			truncated and "warn" or "info"
		)
	end

	local summary = string.format("Saved %d lines to workspace/%s", total, folder)
	session.Log(summary)
	session.Notify(summary, "success", 6)
end

local function buildDebugConsole(session)
	local Window = session.Window
	local tab = Window:AddTab({ Name = "Debug", Icon = "Lucide:terminal" })

	local Console = session:WrapTab(tab:AddSubTab({ Name = "Console", Icon = "Lucide:terminal" }), "Debug")

	local console = Console:AddConsole({
		Title = "Output",
		Height = 300,
		MaxLogs = 300,
		AutoCapture = true, -- Also shows everything printed to the Roblox output
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

	local function runDump(getSources)
		if not decompile then
			session.Notify("Your executor can't decompile scripts.", "error")
			return
		end
		startDumpTask(function()
			dumpSources(session, dumpStatus, getSources())
		end)
	end

	Console:AddButton({
		Text = "Dump Instance Tree",
		Description = "Lists buttons, prompts, values and labels in workspace/" .. dumpFolder .. "/InstanceTree",
		Icon = "Lucide:list-tree",
		Callback = function()
			startDumpTask(function()
				dumpInstanceTrees(session, dumpStatus)
			end)
		end,
	})
	Console:AddButton({
		Text = "Dump ReplicatedStorage",
		Description = "Saves ReplicatedStorage's folders and scripts to workspace/" .. dumpFolder,
		Icon = "Lucide:folder-down",
		Callback = function()
			runDump(function()
				return { { Instance = game:GetService("ReplicatedStorage"), Folder = "" } }
			end)
		end,
	})
	Console:AddButton({
		Text = "Dump StarterPlayer",
		Description = "Saves the character and player scripts to workspace/" .. dumpFolder .. "/StarterPlayer",
		Icon = "Lucide:folder-down",
		Callback = function()
			runDump(function()
				local StarterPlayer = game:GetService("StarterPlayer")
				return {
					{
						Instance = StarterPlayer:WaitForChild("StarterCharacterScripts"),
						Folder = "StarterPlayer/StarterCharacterScripts",
					},
					{
						Instance = StarterPlayer:WaitForChild("StarterPlayerScripts"),
						Folder = "StarterPlayer/StarterPlayerScripts",
					},
				}
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

	About:AddSection("Changelog", "Lucide:history")
	About:AddChangelogEntry({
		Version = session.Hub.Name .. " " .. session.Hub.Version,
		Date = "Nov 5, 2026",
		Changes = {
			{ Type = "Added", Text = "17 games in one script, detected automatically" },
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
