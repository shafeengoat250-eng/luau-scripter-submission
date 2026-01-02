local Pet = {} 
local DataStoreService = game:GetService("DataStoreService")
local runservice= game:GetService("RunService")
local StatsDataStore = DataStoreService:GetDataStore("NewPets25")
local players= game:GetService("Players")
--datastore service in order to save our players pets in the inventory and load them when they join
Pet.__index = Pet
Pet.All_PlayerClasses = {}

--A pet data's values should be these:
export type PetData = {
	Nickname: string,
	Rarity: string,
	Power: number,
	Level: number,
	Chance: number
}


local pets:PetData = {
	{Nickname = "Cat",   Rarity = "Common",    Power = 10,   Level = 1, Chance = 70}, 
	{Nickname = "Bunny", Rarity = "Rare",      Power = 100,  Level = 1, Chance = 25},
	{Nickname = "Fox",   Rarity = "Legendary", Power = 1000, Level = 1, Chance = 5},
}
--Changing chance doesnt do nothing its just there to represent the ui chance label 
--These chances are from the method petroll btw
local MaxEquipped= 3

function Pet.new(player)
	local self = setmetatable({}, Pet) 
	self.Petone= pets[1]

	self.Petstwo= pets[2]
	
	self.Petsthree= pets[3]
	
	
	Pet.All_PlayerClasses[player.UserId]= self
	
	return self
end

--METHODS IN ORDER TO SET DIFFERENT CONFIGURATIONS TO THE TABLE:

function Pet:Rename(newName: string, classname)
	classname.Nickname = newName
end

function Pet:SetPower(newPower: number, classname)
	classname.Power = newPower
end

function Pet:SetRarity(newRarity: string, classname)
	classname.Rarity = newRarity
end

function Pet:SetLevel(newLevel: number, classname)
	classname.Level = newLevel
end
--DEFAULT STATS: YOU CAN CONFIGURE EACH USING THIS CONFIG METHOD
function Pet:Config(Rename, Power, Rarity, Level, Index)
	local configindex = {
		self.Petone,
		self.Petstwo,
		self.Petsthree
	}

	local function configstats(name, power, rarity, lvl, index)
		self:Rename(name, configindex[index])
		self:SetPower(power, configindex[index])
		self:SetRarity(rarity, configindex[index])
		self:SetLevel(lvl, configindex[index])
	end

	configstats(Rename, Power, Rarity, Level, Index)
end
--IF YOU WANT TO CHANGE STATS CALL THE CONFIG IN A SERVER SCRIPT, SUPER SIMPLE MAKE A NEW OBJECT AND CALL PET:CONFIG

--Simple way of managing the randomness between each pet
--Just uses simple checks with math.random
function Pet:Roll()
	local roll = math.random(1, 100)

	local t
	if roll <= 70 then -- 70%
		
		t = pets[1]
		
	elseif roll <= 95 then -- 25%
		
		t = pets[2]
	else
		
		t = pets[3] -- 5%
	end

	return t
end
--THIS IS THE START OF THE DATASTORES:
local remotes= game.ReplicatedStorage.Remotes
local remotevent= remotes.RemoteEvent
local whendeleted= remotes.WhenDeleted
local loaddata= remotes.WhenJoined
local spawnpet= remotes.SpawnPet
local unequip= remotes.Unequip
local maxEquippedmsg= remotes.MaxEquippedmsg

local function normalize(old)
	if type(old) ~= "table" then
		return {}
	end
	return old
end

players.PlayerAdded:Connect(function(player)
	local InventoryGui= player.PlayerGui:WaitForChild("UI"):WaitForChild("InventoryGui")
	local connection
	connection= InventoryGui.TextButton.MouseButton1Click:Connect(function()

		--Gives a random pet
		remotevent:FireClient(player, Pet:Roll())

	end)

	--LOADS IN YOUR PET DATA FROM LOOPING THROUGH A TABLE THAT HOLDS TABLES LABELED "v":
	local ok, dataOrErr = pcall(function()
		return StatsDataStore:GetAsync(player.UserId)
	end)

	if ok then
		dataOrErr = normalize(dataOrErr) -- turn nil into {} cuz a new player needs info at first
		for _, v in ipairs(dataOrErr) do
			loaddata:FireClient(player, v)
		end

	else
		warn("No inventory table to load:", dataOrErr)
	end
end)

--Returns feedback when deleting or updating your inventory
local function seeinventory(ok, newValueOrErr)
	if ok then
		local newValue = newValueOrErr
		print("New inventory:", newValue)
	else
		warn("Save failed:", newValueOrErr)
	end
end

--AN EVENT THAT IS CAUGHT WHEN THE PLAYER ROLLS FOR A PET 
remotevent.OnServerEvent:Connect(function(player, petData)
	local ok, updated = pcall(function()
		return StatsDataStore:UpdateAsync(player.UserId, function(old)
			old = normalize(old)
			if #old >= 4 then return old end
			table.insert(old, petData)
			return old
		end)
	end)

	seeinventory(ok, updated)
end)

--Simple event that catches when a player deletes a pet
whendeleted.OnServerEvent:Connect(function(player, petDataToRemove)
	local ok, updated = pcall(function()
		return StatsDataStore:UpdateAsync(player.UserId, function(old)
			old = normalize(old)

			--This is the most crucial part maybe
			--It loops through our table of tables and it checks if the thing they deleted was a certain name
			--So it knows what to delete from the table that was saved
			for i = #old, 1, -1 do
				local v = old[i]
				if v.Nickname == petDataToRemove.Nickname then
					table.remove(old, i)
					break
				end
			end
			return old
		end)
	end)

	seeinventory(ok, updated)
end)

-- holds per-player follow data 
local follow = {}

-- how far behind the pet is from the player
local followdistance = 6

-- GAP between pets
local spacing = 6

--self explantory
local maxpetlimit = 2

-- DOES ONLY WANT FOLLOW LOOP PER PLAYER SO THAT WE DONT USE MULTIPLE STEPPED CONNECTIONS
local function ensureFollowLoop(player)
	-- EASY CHECK THATS STOP THE FUNCTION IF THEY MADE A LOOP FOR A PLAYER ALREADY
	if follow[player] and follow[player].conn then return end

	-- Create the player entry if it doesn’t exist yet
	follow[player] = follow[player] or {pets = {}}


	follow[player].conn = runservice.Stepped:Connect(function()
		local char = player.Character
		local hrp = char:WaitForChild("HumanoidRootPart") 

		local pets = follow[player].pets
		local total = #pets
		if total == 0 then return end -- nothing to update

		-- center index used to make spacing symmetrical (ex: 2 pets left and right)
		local center = (total + 1) / 2

		-- loops backwards so it safely remove wrong pets while iterating
		for i = total, 1, -1 do
			local pet = pets[i]

			-- If the pet got deleted or unparented, remove it from the list
			if not pet.Parent then
				table.remove(pets, i)
				continue
			end

			-- AlignPosition/AlignOrientation are what actually “follow” the player
			local alignPos = pet:FindFirstChild("AlignPosition", true)
			local alignOri = pet:FindFirstChild("AlignOrientation", true)

			-- this is the most tuff equation for offset omg
			local sideOffset = (i - center) * spacing

			-- behind the player and the sideways offset thing
			alignPos.Position =
				hrp.Position
				+ (hrp.CFrame.LookVector * -followdistance)
				+ (hrp.CFrame.RightVector * sideOffset)

			-- Rotation: match player facing direction
			alignOri.CFrame = hrp.CFrame
		end
	end)
end

-- Adds a pet to the follow system (equips it)
local function addPet(player, petInstance)
	follow[player] = follow[player] or { pets = {} }
	local pets = follow[player].pets

	
	if #pets >= maxpetlimit then
		maxEquippedmsg:FireClient(player) -- tell client they hit the cap
		petInstance:Destroy()             -- delete the new pet that tried to equip
		return false
	end

	-- Store pet so it gets updated each frame
	table.insert(pets, petInstance)

	-- Ensure the follow loop is running for this player
	ensureFollowLoop(player)
	return true
end

-- Removes a pet from the follow system (unequips it)
local function removePet(player, petInstance)
	local t = follow[player]
	local pets = t.pets

	-- Remove from list so it stops being updated
	local i = table.find(pets, petInstance)
	table.remove(pets, i)

	-- Destroy the pet in the world
	if petInstance and petInstance.Parent then
		petInstance:Destroy()
	end

	-- If no pets left, disconnects and makes it nil
	-- i remeber learning online that making it nil saves memory so thats that
	if #pets == 0 and t.conn then
		t.conn:Disconnect()
		t.conn = nil
	end
end


spawnpet.OnServerEvent:Connect(function(player, petdata)
	local template = game.ReplicatedStorage.Pets.Part
	local pet = template:Clone()
	pet.Parent = player.Character

	pet.SurfaceGui.TextLabel.Text = petdata.Nickname
	pet:SetAttribute("Nickname", petdata.Nickname)

	addPet(player, pet)
end)

unequip.OnServerEvent:Connect(function(player, petdata)
	local t = follow[player]

	-- The equipped pet that matches the nickname then remove it
	for _, pet in ipairs(t.pets) do
		if pet:GetAttribute("Nickname") == petdata.Nickname then
			removePet(player, pet)
			break
		end
	end
end)



return Pet
