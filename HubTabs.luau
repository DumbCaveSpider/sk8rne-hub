-- The two tabs every session has: Debug Console and Hub Settings.

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

local function dumpReplicatedStorage(session, statusLine)
	local root = getDumpFolderName(session)
	local folders, scripts = { root }, {}
	collectDumpEntries(game:GetService("ReplicatedStorage"), root, folders, scripts)

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
	statusLine:Set("Dump ReplicatedStorage")
end

local function buildDebugConsole(session)
	local Window = session.Window
	local tab = Window:AddTab({ Name = "Debug Console", Icon = "Lucide:terminal" })

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

	local dumpStatus = Console:AddLineText("Dump ReplicatedStorage")
	local dumping = false
	Console:AddButton({
		Text = "Dump Scripts",
		Description = "Saves ReplicatedStorage's folders and scripts to workspace/" .. getDumpFolderName(session),
		Icon = "Lucide:folder-down",
		Callback = function()
			if dumping then
				session.Notify("A dump is already running.", "warning")
				return
			end
			if not (decompile and writefile and makefolder and isfolder) then
				session.Notify("Your executor can't decompile or write files.", "error")
				return
			end
			dumping = true
			session.task.spawn(function()
				local ok, err = pcall(dumpReplicatedStorage, session, dumpStatus)
				dumping = false
				if not ok then
					dumpStatus:Set("Dump ReplicatedStorage")
					session.Log("Dump failed: " .. tostring(err), "error")
					session.Notify("The dump failed. See the console.", "error")
				end
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
			{ Type = "Added", Text = "Debug Console and Hub Settings tabs" },
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
