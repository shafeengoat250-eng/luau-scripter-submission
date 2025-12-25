-- luau scripter skill submission
--
-- this file has TWO related scripts that work as a system



-- module script (zoneentermod)--
 
--   uses the open-source zone module to detect when players enter/exit the ffa zone.
--   when a player enters:
--     - gives them a sword if they don't already have it
--     - starts shrinking/animating zone parts using tweenservice (gameplay pressure)
--   when a player exits:
--     - removes the sword from backpack/character
--     - enables spectate ui and fires an event to update attributes/state
--   also contains a win-check loop:
--     - if only 1 player remains in zone, awards a win and announces winner
 -- ================================
-- script 1: zoneentermod
-- ================================

 
local module = {}
function module.ZoneEnterMod(timtildeath)
 
	local RR = game:GetService('ReplicatedStorage')
 
 
	-- a :getplayers() method to track players inside a region/part
	local Zone = require(RR.Zone)
 
	-- this defines the actual fight zone region
	local fightzone = Zone.new(game.Workspace.FFA.FFAZone)
 
 
	-- these are zone parts that get resized over time (like storm pressure)
	local dmgzone= game.Workspace.FFA.DmgZone
	local seezone= game.Workspace.FFA.SeeZone
 
	-- runs when someone enters the zone region
	fightzone.playerEntered:Connect(function(player)
 
		-- small delay 
		--player.Character.Humanoid.WalkSpeed= 32
		task.wait(3)
		print(("%s entered the zone!"):format(player.Name))
 
		-- give player a linkedsword if they don't have one in backpack or character
		-- this prevents duplication (spamming swords)
		if not player.Backpack:FindFirstChild('LinkedSword') and not player.Character:FindFirstChild('LinkedSword') then
			local sword = RR.LinkedSword:Clone()
			sword.Parent = player.Backpack
 
			-- try to auto-equip the sword if possible
			-- only equips if player is alive and not already holding the sword
			if player.Character and player.Character:FindFirstChild("Humanoid") and player.Character.Humanoid.Health > 0 then
				-- only equip if not already equipped
				if not player.Character:FindFirstChild("LinkedSword") then
					sword.Parent = player.Character
				end
			end
		end
 
 
		local tweenservice= game:GetService("TweenService")
 
		-- shrinks/changes the damage zone over 60 seconds 
		local newtween= tweenservice:Create(dmgzone, TweenInfo.new(60, Enum.EasingStyle.Linear), --105.625, 5.075, 5.075
			{Size= Vector3.new(50.55, 332.5, 4.475)}
 
		)
 
		-- shrinks/changes 
		local newtween2= tweenservice:Create(seezone, TweenInfo.new(60, Enum.EasingStyle.Linear), --105.625, 5.075, 5.075
			{Size= Vector3.new(105.625, 5.075, 5.075)}
 
		)
 
		newtween:Play() 
		newtween2:Play()
 
	end)
 
	-- runs when someone exits the zone region
	fightzone.playerExited:Connect(function(player)
		print(("%s exited the zone!"):format(player.Name))
 
		-- remove the linkedsword from backpack (cleanup + prevents keeping it outside zone)
		for _, tool in pairs(player.Backpack:GetChildren()) do
			if tool:IsA('Tool') and tool.Name == 'LinkedSword' then
				tool:Destroy()
			end
		end
 
		-- remove the linkedsword from character as well
		for _, tool in pairs(player.Character:GetChildren()) do
			if tool:IsA('Tool') and tool.Name == 'LinkedSword' then
				tool:Destroy()
			end
		end
 
		-- enable spectate gui after leaving 
		local spectategui= player.PlayerGui:WaitForChild("SpectateGui")
 
		-- fires an event to update player attributes/state elsewhere
		local binableevent= game.ReplicatedStorage.NewEvents.BinableaAttribute
		spectategui.Enabled= true
		binableevent:Fire(player)
 
	end)
 
	-- event used to announce who won (client displays winner name)
	local wontitleevent= game.ReplicatedStorage.NewEvents.Win
 
	-- loop continuously checks win condition
	-- this is a simple "game loop" pattern:
	-- if only 1 player remains in the zone, that player is the winner.
	while true do
	task.wait(1)
 
		-- :getplayers() returns a list of players currently inside the zone
		if #fightzone:getPlayers() == 1 then
 
			-- reset the zone sizes quickly after round ends (visual reset)
			local tweenservice= game:GetService("TweenService")
			local newtween= tweenservice:Create(dmgzone, TweenInfo.new(2, Enum.EasingStyle.Linear), 
				{Size= Vector3.new(50.55, 332.5, 297.05)}
 
			)
			local newtween2= tweenservice:Create(seezone, TweenInfo.new(2, Enum.EasingStyle.Linear), --105.625, 5.075, 5.075
				{Size= Vector3.new(105.625, 297.05, 297.05)}
 
			)
			newtween:Play() 
			newtween2:Play()
 
			-- award win to the last remaining player(s)
			for _,v in pairs(fightzone:getPlayers()) do
				-- adds +1 win in leaderstats (server-side authority)
				v.leaderstats.Wins.Value += 1
 
				-- broadcast winner name to all clients
				wontitleevent:FireAllClients(v.Name)
 
				-- small delay to let winner ui display before teleport
				task.wait(3)
 
				-- teleports winner out of the arena
				v.Character.HumanoidRootPart.CFrame= game.Workspace.SpawnLocation.CFrame
			end
		end
	end
	end
return module

-- ================================
-- script 2: leaderboard
-- ================================

-- 2)
--leaderboard script (not a module script) (total kills)--
 
--   - saves each player's totalkills into an ordereddatastore
--   - every 25 seconds, pulls top 10 entries using getsortedasync
--   - rebuilds a leaderboard ui in the world (scrollingframe)
--   - shows each player's username + headshot thumbnail + rank + total kills
 
 
local DataStoreService = game:GetService("DataStoreService")
 
-- ordereddatastore lets you sort by value (leaderboards)
local PlayerMoney = DataStoreService:GetOrderedDataStore("Totalkills5")
 
-- ui template stored in replicatedstorage (cloned per entry)
local item = game.ReplicatedStorage:WaitForChild("Bar")
 
-- this is the target scrollingframe container in workspace (3d leaderboard ui)
local frame = game.Workspace:WaitForChild("Leaderboard")
	:WaitForChild("Part")
	:WaitForChild("ScrollingGui")
	:WaitForChild("ScrollingFrame")
	:WaitForChild("Frame")
 
-- when a player joins, start a repeating save loop for their totalkills
-- this keeps the ordereddatastore updated so the leaderboard is accurate
game.Players.PlayerAdded:Connect(function(plr)
	local kills = plr:WaitForChild("leaderstats"):WaitForChild("TotalKills")
 
	task.spawn(function()
		-- repeat every 30 seconds
		while task.wait(30) do 
			-- pcall prevents runtime errors from breaking the loop if datastore throttles
			local success, errorMsg = pcall(function()
				PlayerMoney:SetAsync(plr.UserId, kills.Value)
			end)
			if not success then
				warn("Save failed:", errorMsg)
			end
		end
	end)
end)
 
-- this loop rebuilds the leaderboard ui periodically (every 25 seconds)
task.spawn(function()
	while task.wait(25) do
 
		-- outer pcall protects the whole refresh cycle
		local ok, err = pcall(function()
 
			-- clear old leaderboard ui entries before rebuilding
			-- (prevents duplicates stacking up)
			for _, frame in pairs(frame:GetChildren()) do
				if frame:IsA("ImageLabel") or frame:IsA("TextLabel") or frame.Name == "Bar" then
					frame:Destroy()
				end
			end
 
			-- getsortedasync returns the top entries from the ordereddatastore
			-- false = descending (highest first), 10 = top 10 players
			local success, pages = pcall(function()
				return PlayerMoney:GetSortedAsync(false, 10)
			end)
 
			-- if request fails or pages is nil, skip this refresh
			if not success or not pages then
				warn("Failed to get leaderboard data.")
				return
			end
 
			-- current page contains the actual entries list
			local entries = pages:GetCurrentPage()
 
			-- build one ui entry per leaderboard rank
			for rank, entry in pairs(entries) do
				local clonedItem = item:Clone()
 
				-- resolve userid username (can error, so wrapped in pcall)
				local username = "Unknown"
				pcall(function()
					username = game.Players:GetNameFromUserIdAsync(entry.key)
				end)
 
				clonedItem.PlayerText.Text = username
 
				-- resolve userid  thumbnail
				local thumbnail = "rbxassetid://0"
				pcall(function()
					local thumb, _ = game.Players:GetUserThumbnailAsync(
						entry.key,
						Enum.ThumbnailType.HeadShot,
						Enum.ThumbnailSize.Size180x180
					)
					thumbnail = thumb
				end)
 
				-- apply leaderboard data to ui fields
				clonedItem.ImageForPlayer.Image = thumbnail
				clonedItem.KillsText.Text = entry.value
				clonedItem.Rank.Text = "#" .. rank
				clonedItem.WinsText.Text = " Total Kills"
 
				-- styling for top 3 ranks (gold/silver/bronze)
				if rank == 1 then
					clonedItem.Rank.TextColor3 = Color3.fromRGB(255, 215, 0) -- gold
					clonedItem.PlayerText.TextColor3 = Color3.fromRGB(255, 215, 0)
					clonedItem.KillsText.TextColor3 = Color3.fromRGB(255, 215, 0)
					clonedItem.WinsText.TextColor3= Color3.fromRGB(255, 215, 0)
				elseif rank == 2 then
					clonedItem.Rank.TextColor3 = Color3.fromRGB(193, 193, 193) -- silver
					clonedItem.PlayerText.TextColor3 = Color3.fromRGB(193, 193, 193)
					clonedItem.KillsText.TextColor3 = Color3.fromRGB(193, 193, 193)
					clonedItem.WinsText.TextColor3= Color3.fromRGB(193, 193, 193)
				elseif rank == 3 then
					clonedItem.Rank.TextColor3 = Color3.fromRGB(243, 148, 59) -- bronze
					clonedItem.PlayerText.TextColor3 = Color3.fromRGB(243, 148, 59)
					clonedItem.KillsText.TextColor3 = Color3.fromRGB(243, 148, 59)
					clonedItem.WinsText.TextColor3=Color3.fromRGB(243, 148, 59)
				else
					-- default styling for ranks 4+
					clonedItem.Rank.TextColor3 = Color3.fromRGB(255, 255, 255)
					clonedItem.PlayerText.TextColor3 = Color3.fromRGB(255, 255, 255)
					clonedItem.KillsText.TextColor3 = Color3.fromRGB(255, 255, 255)
					clonedItem.WinsText.TextColor3=Color3.fromRGB(255,255,255)
				end
 
				-- insert into the ui container and make it visible
				clonedItem.Parent = frame
				clonedItem.Visible = true
			end
		end)
 
		-- if the refresh crashed, log why (keeps script alive)
		if not ok then
			warn("Leaderboard loop crashed:", err)
		end
	end
end)
