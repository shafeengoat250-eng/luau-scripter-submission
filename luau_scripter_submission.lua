local Pet = {} 
local DataStoreService = game:GetService("DataStoreService")
local StatsDataStore = DataStoreService:GetDataStore("NewPets22")
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

local remotevent= game.ReplicatedStorage.Remotes.RemoteEvent
local whendeleted= game.ReplicatedStorage.Remotes.WhenDeleted
local loaddata= game.ReplicatedStorage.Remotes.WhenJoined


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
		print("Inventory:", dataOrErr)
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

--Table:

local function normalize(old)
	if type(old) ~= "table" then
		return {}
	end
	return old
end


--AN EVENT THAT IS CAUGHT WHEN THE PLAYER ROLLS FOR A PET 
remotevent.OnServerEvent:Connect(function(player, petData)
	--Important it gives us a counter that is stored. Since you only can have 4 pets it will use this counter
	local ok2, updated2 = pcall(function()
		return StatsDataStore:IncrementAsync("Check", 1)
	end)
	seeinventory(ok2, updated2)
	
	
	local ok, updated = pcall(function()
		return StatsDataStore:UpdateAsync(player.UserId, function(old)
			if updated2 >= 5 then return end --5 justs works because 4 events gives only 3 pets idk why
			old = normalize(old)
			table.insert(old, petData)
		
			return old
		end)
	end)

	seeinventory(ok, updated)
	
end)

--Simple event that catches when a player deletes a pet
whendeleted.OnServerEvent:Connect(function(player, petDataToRemove)
	local ok3, updated3 = pcall(function()
		return StatsDataStore:IncrementAsync("Check", - 1)
	end)
	--Back to our check it will minus one from the counter so if it was 4/4 then 3/4.. etc
	local ok, updated = pcall(function()
		return StatsDataStore:UpdateAsync(player.UserId, function(old)
			old = normalize(old)
		
		--This is the most crucial part maybe
		--It loops through our table of tables and it checks if the thing they deleted was a certain name
		--So it knows what to delete from the table that was saved
			for _, v in ipairs(old) do
				if v.Nickname== petDataToRemove.Nickname then
					local index = table.find(old, v)
					table.remove(old, index)
					break
				end
			end
			return old
		end)
	end)

	seeinventory(ok, updated)
	
end)


return Pet
