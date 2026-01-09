 --!strict
--FIXED suggestions from EssentialBlue (only comments added and changed the waitforchild)
-- AbilitySystem.server.lua
-- Server ability system demo:
--Functionality summarized:
--[[ 
	This script functions as a server ability system.
I don't want clients to cheat by enforcing per player cooldowns and executing the ability logic clients only request an ability name by a remoteEvent. 
The server then verifies the request.
How it functions and how the parts fit together:
Every player receives an instance of the AbilityController
which holds the cooldown state for each ability name
When AbilityRequest is triggered, the server executes tryCast after rejecting bad data and grabbing or creating the player's controller
One of three abilities can be accessed using tryCast: 
DashStrike- use a brief forward dash (LinearVelocity) and a delayed box hit check in front to cause damage or knockback
Shockwave- close humanoids are harmed or knocked back by rubble vfx that is sampled from the ground and box query surrounding the caster
ThrowRock- an anchored projectile that travels along a quadratic Bezier arc. Raycasts between frames stop it from tunneling until it strikes, causing damage and knockback-- (math and RunService)
	- All hits/damage are decided on the server (Overlap queries and raycasts).
]]
--How to play, Q to dashstrike // E to shockwave // R to throw
 
-- Services
local Players = game:GetService("Players") -- a service that gets all the player in the game

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RunService = game:GetService("RunService")-- i need RunService for Heartbeat, which lets the server update the rock projectile every frame (time based movement)

local Debris = game:GetService("Debris")-- We need Debris to automatically remove temporary vfx parts 
-- Remotes
local remotesFolder = ReplicatedStorage.Remotes
local abilityRequest =  remotesFolder.AbilityRequest:: RemoteEvent

-- Ability definitions with their cooldowns
local ABILITIES = {-- ability table that holds three tables with their own variable that has a cooldown
	DashStrike = {
		cooldown = 1.5,
	},

	Shockwave= {
		cooldown = 4,
	},

	ThrowRock = {
		cooldown = 0.25,
	},
}

-- DashStrike config
-- A short forward dash followed by a single hitbox check in front of the player

local DASH_DISTANCE = 12
local DASH_TIME = 0.12 -- How long the dash lasts , Smaller time = faster dash because speed = distance divided time
local HITBOX_SIZE = Vector3.new(15, 15, 15)-- Size of the damage box, uses vector3 instead of vector 2 because we are editing a 3d space
local HITBOX_FORWARD_OFFSET = 5
local DAMAGE = 20
local KNOCKBACK = 250 
-- Shockwave config
-- A shockwave effect that damages nearby humanoids and spawns outward moving debris for visual impact
local SHOCKWAVE_RADIUS = 14
local SHOCKWAVE_HEIGHT = 6
local SHOCKWAVE_DAMAGE = 30
local SHOCKWAVE_KNOCKBACK = 180
local DEBRIS_COUNT = 22
local DEBRIS_RADIUS = 3
local DEBRIS_SPREAD = 12
local DEBRIS_LIFETIME = 1.2
local DEBRIS_MIN_SIZE = 0.6
local DEBRIS_MAX_SIZE = 1.6
local DEBRIS_OUT_SPEED = 55
local DEBRIS_UP_SPEED = 30

--  ThrowRock (Bezier Curve) config
-- Projectile with a quadratic Bezier curve
local ROCK_RANGE = 30
local ROCK_FLIGHT_TIME = 0.45
local ROCK_ARC_HEIGHT = 10
local ROCK_DAMAGE = 50
local ROCK_KNOCKBACK = 90
local ROCK_SIZE = Vector3.new(3,3,3)
local ROCK_SPAWN_FORWARD_OFFSET = 1
local ROCK_SPAWN_UP_OFFSET = 1

--  AbilityController (per player state)
-- Each player gets their own controller instance (metatable/OOP) so cooldown tracking stays single
-- Each player gets their own controller instance so cooldowns are tracked per-player instead of globally
-- Because if cooldown state was shared one player's cast could accidentally put the ability on cooldown for everyone
-- and you'd have to constantly key everything by player anyway
-- A per player controller keeps the state isolated makes cleanup easy on PlayerRemoving and keeps tryCast logic focused on the player rather than global tables everywhere

local AbilityController = {} -- class table (stores methods)
AbilityController.__index = AbilityController -- enables OOP method lookups with metatable

type AbilityControllerData = { -- internal data shape
	player: Player, -- owner of this controller
	onCooldown: {[string]: boolean}, -- abilityName , cooldown flag
}

export type AbilityControllerT = AbilityControllerData & { -- full public type, data and methods
	isOnCooldown: (self: AbilityControllerT, abilityName: string) -> boolean, -- check cooldown state
	startCooldown: (self: AbilityControllerT, abilityName: string, cooldownSeconds: number) -> (), -- start cooldown timer
	tryCast: (self: AbilityControllerT, abilityName: string) -> (), -- make sure its correct and execute
}

function AbilityController.new(player: Player): AbilityControllerT -- constructor for a player controller
	local self: AbilityControllerData = { 
		player = player,
		onCooldown = {},
	}

	return setmetatable(self:: any, AbilityController) :: any -- attach methods with metatable and return
end

function AbilityController.isOnCooldown(self: AbilityControllerT, abilityName: string): boolean -- cooldown query helper
	return self.onCooldown[abilityName] == true -- true only while cooling down
end

function AbilityController.startCooldown(self: AbilityControllerT, abilityName: string, cooldownSeconds: number) -- begin cooldown window

	-- Boolean cooldowns keep the system simple and prevent spamming
	-- the question is basically is the ability currently allowed (true/false).
-- That keeps the logic super clear set true on cast and flips back to false after an amount of seconds
-- It also prevents spamming because repeated remote requests during the cooldown window are ignored by the server
-- so the client can't force extra casts even if they fire the RemoteEvent rapidly (no spam)
	self.onCooldown[abilityName] = true

	task.spawn(function() -- task.spawn is a thing in roblox that doesnt obey the roblox order of what code goes first
		task.wait(cooldownSeconds)
		self.onCooldown[abilityName] = false
	end)
end

-- Character helpers
-- I wrap common character lookups into helpers because:
--  the ability code stays focused on what the ability is doing then repeated checks
-- characters can be nil missing parts during respawn, death etc
--   every ability confirms the same required pieces (alive humanoid and root) before doing movement/damage.
--  Less repeated work you only DO FindFirstChild/FindFirstChildOfClass calls once per cast,
--    instead of PUTTING them everywhere in each ability section.

local function getCharacter(player: Player): Model -- grabs the player's character model
	return player.Character -- might be nil during respawn
end

local function getHumanoid(character: Model): Humanoid -- finds the humanoid for health/damage checks
	return character:FindFirstChildOfClass("Humanoid") 
end

local function getRoot(character: Model): BasePart -- gets hrp for position, facing/movement
	local root = character:FindFirstChild("HumanoidRootPart") -- main root part reference
	if root and root:IsA("BasePart") then
		return root -- return the root part
	end
	return nil -- missing or invalid root
end


-- Hit detection helper
-- Uses OverlapParams and GetPartBoundsInBox to collect unique humanoids in a box region.
-- Why:
--  Clients cant fake hits so the hitboxes have to be on the server
--  Simple aoe thing shapes a box is easy to size/offset for dashes and shockwaves
-- Filtering, OverlapParams lets us not include the caster’s character so you don’t hit yourself.
--  Unique humanoids-- characters have multiple parts, avoid dealing damage multiple times.

local function getTargetsInBox(boxCFrame: CFrame, boxSize: Vector3, ignoreInstances: {Instance}): {Humanoid} -- finds humanoids inside a box region
	local params = OverlapParams.new() -- Create overlay config using overlapparams
	params.FilterType = Enum.RaycastFilterType.Exclude -- ignore listed instances using .Exclude in raycastfiltertypes
	params.FilterDescendantsInstances = ignoreInstances

	local parts = workspace:GetPartBoundsInBox(boxCFrame, boxSize, params) -- all parts overlapping the box, getpartsboundinbox using position size and the parameters

	local seen: {[Humanoid]: boolean} = {} -- dont dupe humanoids because its a multi rig parts so set it equal to a table with nothing (nil
	local targets: {Humanoid} = {} -- Output list of unique humanoids

	for _, part in ipairs(parts) do 
		local model = part:FindFirstAncestorOfClass("Model") -- loops through what it hit then finds the parent basically
		if model then -- checks if it was a model
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health > 0 and not seen[humanoid] then -- Alive and not already counted
				seen[humanoid] = true 
				table.insert(targets, humanoid) -- add to results
			end
		end
	end

	return targets -- return unique humanoids in the box
end


-- Combat helper
-- Knockback is applied by setting target root velocity away from the impact origin.
-- I apply knockback by setting the target’s HumanoidRootPart velocity away from the impact origin because
-- It’s immediate and server controlled so the client can’t cancel 
--  no extra constraints to cleanup for every target (just one velocity set)

local function applyKnockbackToHumanoid(humanoid: Humanoid, fromPosition: Vector3, strength: number) -- pushes a target away from an origin point
	local character = humanoid.Parent 
	if not character or not character:IsA("Model") then -- make sure model exists
		return -- can't apply knockback safely so it ends the function with return statment
	end

	local root = getRoot(character) -- get hrp
	if not root then -- Must have a root to push
		return -- no valid root found
	end

	local delta = root.Position - fromPosition -- vector away from the hit origin
	local horizontal = Vector3.new(delta.X, 0, delta.Z) -- remove vertical so push is mostly sideways

	if horizontal.Magnitude < 0.001 then -- Avoid zero length direction. Magnitude is like the whole quantity of the thing
		horizontal = Vector3.new(0, 0, -1) -- fallback direction
	end

	root.AssemblyLinearVelocity = Vector3.new( -- set velocity instantly 
		horizontal.Unit.X * strength,
		root.AssemblyLinearVelocity.Y + 12, -- keep current Y and small lift
		horizontal.Unit.Z * strength 
	)
end


-- Movement helper (DashStrike)
-- Uses LinearVelocity
-- I use the LinearVelocity for the dash because it gives a consistent bursts of movement
-- Predictable because you set an exact VectorVelocity so the dash distance/time feels the same each cast
-- Easy cleanup because I destroy the LinearVelocity after a short duration so it doesn’t keep pushing the player


local function dashWithLinearVelocity(root: BasePart, direction: Vector3, speed: number, duration: number) -- applies a short dash burst
	if direction.Magnitude < 0.001 then -- prevent invalid or zero direction
		return -- no dash if we can't normalize direction
	end

	local att = root:FindFirstChild("DashAttachment") -- reuse an attachment if it already exists
	if not att then -- Create if missing
		att = Instance.new("Attachment")
		att.Name = "DashAttachment" 
		att.Parent = root 
	end

	local lv = Instance.new("LinearVelocity") -- constraint that drives constant velocity
	lv.Name = "DashLinearVelocity"
	lv.Attachment0 = att 
	lv.RelativeTo = Enum.ActuatorRelativeTo.World -- velocity in world space
	lv.MaxForce = math.huge -- Ensure it overcomes character mass/forces
	lv.VectorVelocity = direction.Unit * speed 
	lv.Parent = root 

	task.spawn(function() 
		task.wait(duration) 
		if lv.Parent then 
			lv:Destroy() 
		end
	end)
end

-- ThrowRock helpers (Bezier + anti-tunneling raycasts)
-- Quadratic Bezier gives a clean arc using only Vector3 math (no physics simulation NEEDED)
-- Clean arc control because you can adjust range and arc height without using gravity tuning because of the start/control/end points.
--  Raycasts stop tunneling by confirming the lastPos to newPos every frame which makes sure quick motion while still registering hits

local function bezierQuadratic(p0: Vector3, p1: Vector3, p2: Vector3, t: number): Vector3 -- making a point on a quadratic Bezier curve
	local a = p0:Lerp(p1, t) -- first lerp between start and control
	local b = p1:Lerp(p2, t) -- second lerp between control and end
	return a:Lerp(b, t) -- result is the the curve
	--lerp from my knowledge is similar to tweenservice but using lerp to constantly animate is better
end


local function spawnRockBezier(ownerCharacter: Model, startPos: Vector3, direction: Vector3)
	local rock = Instance.new("Part")-- creates a new instance in workspace
	rock.Name = "RockProjectile" 
	rock.Shape = Enum.PartType.Ball
	rock.Size = ROCK_SIZE
	rock.CanCollide = false
	rock.Anchored = true
	rock.CanQuery = true
	rock.CanTouch = false
	rock.Material = Enum.Material.Slate
	rock.Position = startPos
	rock.Parent = workspace

	local dir = direction.Unit -- this is how you get the unit vector
	local endPos = startPos + (dir * ROCK_RANGE)
	local control = (startPos + endPos) * 0.5 + Vector3.new(0, ROCK_ARC_HEIGHT, 0)

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = {ownerCharacter, rock }

local t = 0 -- progress value 
local lastPos = startPos -- previous position used to raycast between frames
local hit = false -- Flag to stop processing after a hit
local conn -- holds the Heartbeat connection so we can disconnect it

conn = RunService.Heartbeat:Connect(function(dt: number) 
	if hit then -- already hit something
		return -- stop moving
	end

	t += dt / ROCK_FLIGHT_TIME -- advance progress based on total flight time
	if t >= 2 then -- Clamp progress so it doesn't run forever
		t = 2 -- cap value
	end

	local pos = bezierQuadratic(startPos, control, endPos, t)
	local step = pos - lastPos -- movement delta since last frame

	-- Raycast between frames so fast projectiles still register hits
	if step.Magnitude > 0 then -- only raycast if we actually moved
		local result = game.Workspace:Raycast(lastPos, step, rayParams)
		if result then -- something was hit
			local model = result.Instance:FindFirstAncestorOfClass("Model") 
			if model then -- correct model found
				local humanoid = model:FindFirstChildOfClass("Humanoid") 
				if humanoid and humanoid.Health > 0 then 
					hit = true 
					humanoid:TakeDamage(ROCK_DAMAGE) -- applying damage
					applyKnockbackToHumanoid(humanoid, rock.Position, ROCK_KNOCKBACK)
				end
			end

			if conn then conn:Disconnect() end -- stop heartbeat updates prevents connection from leaking. :Disconnect() only applies to event connections
			if rock.Parent then rock:Destroy() end -- remove projectile part
			return -- exit after handling the collision
		end
	end


		rock.Position = pos

		-- You can easily change this it orentates based on where your facing.
		if step.Magnitude > 0.001 then
			rock.CFrame = CFrame.lookAt(pos, pos + step.Unit)
		end

		lastPos = pos

		if t >= 2 then
			if conn then conn:Disconnect() end
			if rock.Parent then rock:Destroy() end
		end
	end)
end

-- Shockwave Vfx helper
-- Spawns small debris chunks sampled from the ground material/color and pushes them outward.
-- Shockwave debris is looks only
-- Sampling the ground’s material/color makes the effect blend with whatever surface you’re on (stone, grass, sand, etc)
-- Pushing the chunks outward/upward visually matches the shockwave expanding idea and Debris cleanup prevents leaks

local function spawnShockwaveDebris(origin: Vector3, ignore: {Instance}) -- spawns visual debris around the shockwave center
	local params = RaycastParams.new() -- raycast settings for sampling the ground
	params.FilterType = Enum.RaycastFilterType.Exclude -- ignore listed instances
	params.FilterDescendantsInstances = ignore -- usually the caster so we don't sample their parts

	for i = 1, DEBRIS_COUNT do -- spawn multiple chunks for the ring effect
		local angle = (i / DEBRIS_COUNT) * math.pi * 2 -- evenly distribute angles around a circle using pi 
		local ringOffset = Vector3.new(math.cos(angle), 0, math.sin(angle)) * DEBRIS_RADIUS
		local randomOffset = Vector3.new( -- small randomness 
			(math.random() - 0.5) * 2, -- random X offset
			0, -- keep flat 
			(math.random() - 0.5) * 2 -- random Z offset
		) * (DEBRIS_SPREAD * 0.15) -- scale randomness by spread

		local start = origin + ringOffset + randomOffset + Vector3.new(0, 8, 0) -- cast from above the ground
		local result = game.Workspace:Raycast(start, Vector3.new(0, -40, 0), params) 
		if not result then 
			continue -- skip this chunk
		end

		local hitPos = result.Position
		local hitNormal = result.Normal
		local hitPart = result.Instance

		local size = math.random() * (DEBRIS_MAX_SIZE - DEBRIS_MIN_SIZE) + DEBRIS_MIN_SIZE

		local rock = Instance.new("Part")
		rock.Name = "ShockwaveDebris"
		rock.Size = Vector3.new(size, size, size)
		rock.CanCollide = false
		rock.CanQuery = false
		rock.CanTouch = false
		rock.Anchored = false
		
		if hitPart:IsA("BasePart") then
			rock.Material = hitPart.Material
			rock.Color = hitPart.Color
		else
			rock.Material = Enum.Material.Slate
			rock.Color = Color3.fromRGB(120, 120, 120)
		end
		
rock.CFrame = CFrame.lookAt(hitPos + hitNormal * (size * 0.5), hitPos + hitNormal) * CFrame.Angles( -- place chunk on surface and face along the surface normal, then add random rotation
			
math.rad(math.random(0, 360)), -- Random X rotation 
math.rad(math.random(0, 360)), -- random Y rotation 
math.rad(math.random(0, 360)) -- Random Z rotation 
)
rock.Parent = workspace -- Parent so it appears in the world

local outward = (Vector3.new(rock.Position.X, origin.Y, rock.Position.Z) - Vector3.new(origin.X, origin.Y, origin.Z)) -- horizontal direction away from the shockwave center
if outward.Magnitude < 0.001 then -- avoid zero length vector
	outward = Vector3.new(1, 0, 0) -- Fallback direction
end

local att = Instance.new("Attachment") -- attachment needed to drive LinearVelocity
att.Parent = rock -- attach to debris part

local lv = Instance.new("LinearVelocity") 
lv.Attachment0 = att -- where velocity is applied
lv.RelativeTo = Enum.ActuatorRelativeTo.World -- move in world space
lv.MaxForce = math.huge -- Ensure it actually moves the chunk
lv.VectorVelocity = outward.Unit * DEBRIS_OUT_SPEED + Vector3.new(0, DEBRIS_UP_SPEED, 0) -- outward blast and upward lift
lv.Parent = rock -- enable the constraint

task.spawn(function() -- timed cleanup for the velocity controller
	task.wait(0.15)
	if lv.Parent then -- checking if it still exists
		lv:Destroy() -- remove controller so physics can settle anmd avoid constant pushing
	end
end)

-- Debris service cleans up temporary vfx parts automatically
Debris:AddItem(rock, DEBRIS_LIFETIME) -- remove the debris chunk after its lifetime
	end
end


function AbilityController.tryCast(self: AbilityControllerT, abilityName: string)
	local def = ABILITIES[abilityName]
	if def == nil then
		warn(("Unknown '%s' from %s"):format(abilityName, self.player.Name))
		return
	end

	-- Cooldown check is always serverside, client requests are treated as not trusted
	if AbilityController.isOnCooldown(self, abilityName) then
		return
	end

	if abilityName == "DashStrike" then -- dash ability branch
	local character = getCharacter(self.player) -- get caster character
	if not character then 
		return
	end

	local humanoid = getHumanoid(character) -- get humanoid for alive check
	local root = getRoot(character) -- get HRP for direction or movement
	if not humanoid or not root then -- missing required parts
		return -- can't cast safely
	end

	if humanoid.Health <= 0 then
		return 
	end

	local forward = root.CFrame.LookVector -- dash direction is where player faces
	dashWithLinearVelocity(root, forward, DASH_DISTANCE / DASH_TIME, DASH_TIME) -- move forward with controlled speed/time

	task.spawn(function() 
		task.wait(0.05) 

		local hitboxCFrame = root.CFrame + (root.CFrame.LookVector * HITBOX_FORWARD_OFFSET) -- place hitbox in front of player
		local targets = getTargetsInBox(hitboxCFrame, HITBOX_SIZE, { character }) -- get valid humanoid targets in hitbox

		for _, targetHumanoid in ipairs(targets) do -- apply effects to each target
			targetHumanoid:TakeDamage(DAMAGE) -- deal DashStrike damage
			applyKnockbackToHumanoid(targetHumanoid, root.Position, KNOCKBACK) -- push away from caster
		end
	end)
end

if abilityName == "Shockwave" then -- shockwave ability branch
	local character = getCharacter(self.player) -- get caster character
	if not character then 
		return 
	end

	local humanoid = getHumanoid(character) 
	local root = getRoot(character) 
	if not humanoid or not root then 
		return 
	end

	if humanoid.Health <= 0 then 
		return 
	end

	local boxSize = Vector3.new(SHOCKWAVE_RADIUS * 2, SHOCKWAVE_HEIGHT, SHOCKWAVE_RADIUS * 2) -- box that approximates a radius and height
	local boxCFrame = CFrame.new(root.Position) -- center the box on the caster

	local targets = getTargetsInBox(boxCFrame, boxSize, { character }) -- find humanoids in the shockwave area

	for _, targetHumanoid in ipairs(targets) do -- apply effects to each target
		targetHumanoid:TakeDamage(SHOCKWAVE_DAMAGE) -- deal shockwave damage
		applyKnockbackToHumanoid(targetHumanoid, root.Position, SHOCKWAVE_KNOCKBACK) -- push away from caster
	end

	spawnShockwaveDebris(root.Position, { character }) -- spawn VFX debris ring at caster position
end

if abilityName == "ThrowRock" then -- projectile ability branch
	local character = getCharacter(self.player) -- get caster character
	if not character then -- no character loaded
		return -- can't cast
	end

	local humanoid = getHumanoid(character)
	local root = getRoot(character) 
	if not humanoid or not root then 
	end

	if humanoid.Health <= 0 then 
		return 
	end

	local dir = root.CFrame.LookVector -- throw direction is where player faces
	local spawnPos = -- compute projectile spawn position
		root.Position
		+ (dir * ROCK_SPAWN_FORWARD_OFFSET) -- move forward so it spawns in front
		+ Vector3.new(0, ROCK_SPAWN_UP_OFFSET, 0) -- move up so it doesn't clip the ground

	spawnRockBezier(character, spawnPos, dir) -- launch the projectile along its arc
end

AbilityController.startCooldown(self, abilityName, def.cooldown) -- start cooldown after a successful cast attempt
end -- end of tryCast


-- Controllers storage
-- Stored by Player so I can keep per player state without putting state on Instances.
-- I store controllers in a table keyed by Player because it keeps per player state (cooldowns) in easy Lua
-- instead of attaching values or attributes to Instances.
-- That avoids extra Instance objects, and makes the cleanup simple easy
-- when the Player leaves, I just nil the entry and the controller can be garbage collected

local controllers: {[Player]: AbilityControllerT} = {} -- table storing one controller per player

local function getController(player: Player): AbilityControllerT 
	local controller = controllers[player]
	if controller == nil then 
		controller = AbilityController.new(player) -- create a new controller for them
		controllers[player] = controller -- cache it for future requests
	end
	return controller 
end

Players.PlayerRemoving:Connect(function(player: Player) -- fires when a player leaves the server
	-- I use the event to clean up memory leaks
	controllers[player] = nil 
end)

abilityRequest.OnServerEvent:Connect(function(player: Player, abilityName: any) -- remote handler, client requests an ability
	if typeof(abilityName) ~= "string" then 
		return -- ignore bad data
	end

	local controller = getController(player) -- get that player's state manager for cooldown
	controller:tryCast(abilityName) -- attempt to cast on the server cooldowns and damage handled here
end)


