-- AbilitySystem.server.lua
-- Server ability system demo (server-authoritative).
--
-- Why server-authoritative:
-- The client is treated as untrusted because exploiters can edit client code. The client only requests an
-- ability name; the server decides whether it can run (cooldowns/valid state) and is the only place that
-- applies movement, damage, knockback, and VFX.
--
-- High-level execution flow:
-- 1) Client detects input (Q/E/R) and fires AbilityRequest(abilityName)
-- 2) Server receives the RemoteEvent, validates the argument type, then fetches/creates a controller for that player
-- 3) AbilityController.tryCast routes to the correct ability implementation
-- 4) Ability logic uses shared helpers (targeting/knockback/projectile/VFX) so behavior is consistent across abilities
-- 5) A server-side cooldown flag is set so repeated requests are ignored until the cooldown ends
--
-- Demonstrates Roblox APIs: RemoteEvents, RunService.Heartbeat, Raycasting, OverlapParams/GetPartBoundsInBox,
-- physics constraints (LinearVelocity), Debris cleanup, and CFrame/Vector3 math (including a Bezier projectile).

--How to play, Q to dashstrike // E to shockwave // R to throw

--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

--// Remotes
-- The remote is intentionally simple (string only) so the server never relies on client-provided positions/targets.
local remotesFolder = ReplicatedStorage.Remotes
local abilityRequest =  remotesFolder.AbilityRequest:: RemoteEvent

--// Ability definitions with their cooldowns
-- Cooldowns are stored here so balance changes don’t require touching the core logic.
-- tryCast reads this table first, which also prevents unknown ability names from being executed.
local ABILITIES = {
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

--// DashStrike config
-- DashStrike is designed as "movement first, hit second":
-- we dash using physics constraints, then check a hitbox slightly after so hits line up with the new position.
local DASH_DISTANCE = 12
local DASH_TIME = 0.12
local HITBOX_SIZE = Vector3.new(15, 15, 15)
local HITBOX_FORWARD_OFFSET = 5
local DAMAGE = 20
local KNOCKBACK = 250

--// Shockwave config
-- Shockwave approximates a circular AOE using a short box:
-- this is fast, deterministic, and easy to tune compared to per-target distance loops.
-- Debris settings are purely cosmetic and get cleaned up automatically to avoid leaving temporary parts behind.
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

--// ThrowRock (Bezier Curve) config
-- ThrowRock uses a quadratic Bezier so the arc is consistent and not dependent on physics simulation/network ownership.
-- We still raycast along each frame step so the projectile can’t "tunnel" through thin targets at high speed.
local ROCK_RANGE = 30
local ROCK_FLIGHT_TIME = 0.45
local ROCK_ARC_HEIGHT = 10
local ROCK_DAMAGE = 50
local ROCK_KNOCKBACK = 90
local ROCK_SIZE = Vector3.new(3,3,3)
local ROCK_SPAWN_FORWARD_OFFSET = 1
local ROCK_SPAWN_UP_OFFSET = 1

--// AbilityController (per-player state)
-- One controller per player keeps state isolated and makes cleanup easy when players leave.
-- This also avoids storing gameplay state on Instances, which keeps the system easier to reason about and test.
local AbilityController = {}
AbilityController.__index = AbilityController

type AbilityControllerData = {
	player: Player,
	onCooldown: {[string]: boolean},
}

export type AbilityControllerT = AbilityControllerData & {
	isOnCooldown: (self: AbilityControllerT, abilityName: string) -> boolean,
	startCooldown: (self: AbilityControllerT, abilityName: string, cooldownSeconds: number) -> (),
	tryCast: (self: AbilityControllerT, abilityName: string) -> (),
}

function AbilityController.new(player: Player): AbilityControllerT
	-- Metatable-based "class" pattern: plain table for data + methods through __index.
	local self: AbilityControllerData = {
		player = player,
		onCooldown = {},
	}

	return setmetatable(self:: any, AbilityController) :: any
end

function AbilityController.isOnCooldown(self: AbilityControllerT, abilityName: string): boolean
	return self.onCooldown[abilityName] == true
end

function AbilityController.startCooldown(self: AbilityControllerT, abilityName: string, cooldownSeconds: number)
	-- Cooldowns are enforced server-side so a client can’t spam RemoteEvent calls to bypass limits.
	-- Using a boolean map keeps lookups O(1) and avoids tracking timestamps.
	self.onCooldown[abilityName] = true

	task.spawn(function()
		task.wait(cooldownSeconds)
		self.onCooldown[abilityName] = false
	end)
end

--// Character helpers
-- These wrappers keep ability code focused on gameplay logic instead of repetitive instance traversal.
-- All abilities require: character exists, humanoid exists (alive), and a root part for positioning/facing direction.
local function getCharacter(player: Player): Model
	return player.Character
end

local function getHumanoid(character: Model): Humanoid
	return character:FindFirstChildOfClass("Humanoid")
end

local function getRoot(character: Model): BasePart
	-- HumanoidRootPart is used as the shared reference for hitboxes, direction (LookVector), and knockback.
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

--// Hit detection helper
-- Uses overlap queries instead of Touched events:
-- - deterministic (no reliance on physics contact callbacks)
-- - easy to exclude the caster’s character
-- - shared by DashStrike and Shockwave to keep targeting consistent
-- We dedupe humanoids because GetPartBoundsInBox returns many parts per character rig.
local function getTargetsInBox(boxCFrame: CFrame, boxSize: Vector3, ignoreInstances: {Instance}): {Humanoid}
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignoreInstances

	local parts = workspace:GetPartBoundsInBox(boxCFrame, boxSize, params)

	local seen: {[Humanoid]: boolean} = {}
	local targets: {Humanoid} = {}

	for _, part in ipairs(parts) do
		local model = part:FindFirstAncestorOfClass("Model")
		if model then
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health > 0 and not seen[humanoid] then
				seen[humanoid] = true
				table.insert(targets, humanoid)
			end
		end
	end

	return targets
end

--// Combat helper
-- Centralizing knockback avoids each ability implementing it differently, which keeps the "feel" consistent.
-- We compute a horizontal direction away from the impact origin so hits push targets outward, then add a small lift.
local function applyKnockbackToHumanoid(humanoid: Humanoid, fromPosition: Vector3, strength: number)
	local character = humanoid.Parent
	if not character or not character:IsA("Model") then
		return
	end

	local root = getRoot(character)
	if not root then
		return
	end

	local delta = root.Position - fromPosition
	local horizontal = Vector3.new(delta.X, 0, delta.Z)

	if horizontal.Magnitude < 0.001 then
		horizontal = Vector3.new(0, 0, -1)
	end

	root.AssemblyLinearVelocity = Vector3.new(
		horizontal.Unit.X * strength,
		root.AssemblyLinearVelocity.Y + 12,
		horizontal.Unit.Z * strength
	)
end

--// Movement helper (DashStrike)
-- LinearVelocity is used because Humanoid movement often fights direct velocity assignment.
-- The Attachment is reused so repeated dashes don’t create extra attachments on the character.
local function dashWithLinearVelocity(root: BasePart, direction: Vector3, speed: number, duration: number)
	if direction.Magnitude < 0.001 then
		return
	end

	local att = root:FindFirstChild("DashAttachment")
	if not att then
		att = Instance.new("Attachment")
		att.Name = "DashAttachment"
		att.Parent = root
	end

	local lv = Instance.new("LinearVelocity")
	lv.Name = "DashLinearVelocity"
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.MaxForce = math.huge
	lv.VectorVelocity = direction.Unit * speed
	lv.Parent = root

	task.spawn(function()
		task.wait(duration)
		if lv.Parent then
			lv:Destroy()
		end
	end)
end

--// ThrowRock helpers (Bezier + anti-tunneling raycasts)
-- Bezier math gives a predictable arc (start -> control -> end). RunService.Heartbeat drives the animation
-- so movement scales with real frame delta time. Raycasting each step prevents missing collisions at high speed.
local function bezierQuadratic(p0: Vector3, p1: Vector3, p2: Vector3, t: number): Vector3
	local a = p0:Lerp(p1, t)
	local b = p1:Lerp(p2, t)
	return a:Lerp(b, t)
end

local function spawnRockBezier(ownerCharacter: Model, startPos: Vector3, direction: Vector3)
	-- The rock is anchored so its path is fully controlled by our math; this avoids physics/network ownership differences.
	local rock = Instance.new("Part")
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

	local dir = direction.Unit
	local endPos = startPos + (dir * ROCK_RANGE)
	local control = (startPos + endPos) * 0.5 + Vector3.new(0, ROCK_ARC_HEIGHT, 0)

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = {ownerCharacter, rock }

	local t = 0
	local lastPos = startPos
	local hit = false
	local conn

	conn = RunService.Heartbeat:Connect(function(dt: number)
		-- Once a hit happens we immediately stop updating to avoid double-hits and wasted work.
		if hit then
			return
		end

		t += dt / ROCK_FLIGHT_TIME
		if t >= 2 then
			t = 2
		end

		local pos = bezierQuadratic(startPos, control, endPos, t)
		local step = pos - lastPos

		if step.Magnitude > 0 then
			local result = game.Workspace:Raycast(lastPos, step, rayParams)
			if result then
				local model = result.Instance:FindFirstAncestorOfClass("Model")
				if model then
					local humanoid = model:FindFirstChildOfClass("Humanoid")
					if humanoid and humanoid.Health > 0 then
						hit = true
						humanoid:TakeDamage(ROCK_DAMAGE)
						applyKnockbackToHumanoid(humanoid, rock.Position, ROCK_KNOCKBACK)
					end
				end

				if conn then conn:Disconnect() end
				if rock.Parent then rock:Destroy() end
				return
			end
		end

		rock.Position = pos

		-- Cosmetic orientation: makes the projectile face its travel direction for readability in the demo.
		if step.Magnitude > 0.001 then
			rock.CFrame = CFrame.lookAt(pos, pos + step.Unit)
		end

		lastPos = pos

		-- When the curve finishes, disconnect + destroy so we don’t keep a Heartbeat connection alive.
		if t >= 2 then
			if conn then conn:Disconnect() end
			if rock.Parent then rock:Destroy() end
		end
	end)
end

--// Shockwave VFX helper
-- Debris is intentionally "one-shot" VFX: it doesn’t affect damage. This separation keeps gameplay consistent
-- even if VFX is tuned later. Raycasting down finds the ground so debris matches the surface material/color.
local function spawnShockwaveDebris(origin: Vector3, ignore: {Instance})
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore

	for i = 1, DEBRIS_COUNT do
		local angle = (i / DEBRIS_COUNT) * math.pi * 2
		local ringOffset = Vector3.new(math.cos(angle), 0, math.sin(angle)) * DEBRIS_RADIUS
		local randomOffset = Vector3.new(
			(math.random() - 0.5) * 2,
			0,
			(math.random() - 0.5) * 2
		) * (DEBRIS_SPREAD * 0.15)

		local start = origin + ringOffset + randomOffset + Vector3.new(0, 8, 0)
		local result = game.Workspace:Raycast(start, Vector3.new(0, -40, 0), params)
		if not result then
			continue
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

		rock.CFrame = CFrame.lookAt(hitPos + hitNormal * (size * 0.5), hitPos + hitNormal) * CFrame.Angles(
			math.rad(math.random(0, 360)),
			math.rad(math.random(0, 360)),
			math.rad(math.random(0, 360))
		)
		rock.Parent = workspace

		local outward = (Vector3.new(rock.Position.X, origin.Y, rock.Position.Z) - Vector3.new(origin.X, origin.Y, origin.Z))
		if outward.Magnitude < 0.001 then
			outward = Vector3.new(1, 0, 0)
		end

		local att = Instance.new("Attachment")
		att.Parent = rock

		local lv = Instance.new("LinearVelocity")
		lv.Attachment0 = att
		lv.RelativeTo = Enum.ActuatorRelativeTo.World
		lv.MaxForce = math.huge
		lv.VectorVelocity = outward.Unit * DEBRIS_OUT_SPEED + Vector3.new(0, DEBRIS_UP_SPEED, 0)
		lv.Parent = rock

		task.spawn(function()
			task.wait(0.15)
			if lv.Parent then
				lv:Destroy()
			end
		end)

		Debris:AddItem(rock, DEBRIS_LIFETIME)
	end
end

function AbilityController.tryCast(self: AbilityControllerT, abilityName: string)
	-- tryCast is the single "router" for all abilities. It enforces shared rules:
	-- - ability must exist in ABILITIES
	-- - ability must not be on cooldown
	-- Then it runs exactly one ability branch and starts the cooldown.
	local def = ABILITIES[abilityName]
	if def == nil then
		warn(("Unknown '%s' from %s"):format(abilityName, self.player.Name))
		return
	end

	if AbilityController.isOnCooldown(self, abilityName) then
		return
	end

	if abilityName == "DashStrike" then
		local character = getCharacter(self.player)
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

		local forward = root.CFrame.LookVector
		dashWithLinearVelocity(root, forward, DASH_DISTANCE / DASH_TIME, DASH_TIME)

		task.spawn(function()
			task.wait(0.05)

			local hitboxCFrame = root.CFrame + (root.CFrame.LookVector * HITBOX_FORWARD_OFFSET)
			local targets = getTargetsInBox(hitboxCFrame, HITBOX_SIZE, { character })

			for _, targetHumanoid in ipairs(targets) do
				targetHumanoid:TakeDamage(DAMAGE)
				applyKnockbackToHumanoid(targetHumanoid, root.Position, KNOCKBACK)
			end
		end)
	end

	if abilityName == "Shockwave" then
		local character = getCharacter(self.player)
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

		local boxSize = Vector3.new(SHOCKWAVE_RADIUS * 2, SHOCKWAVE_HEIGHT, SHOCKWAVE_RADIUS * 2)
		local boxCFrame = CFrame.new(root.Position)

		local targets = getTargetsInBox(boxCFrame, boxSize, { character })

		for _, targetHumanoid in ipairs(targets) do
			targetHumanoid:TakeDamage(SHOCKWAVE_DAMAGE)
			applyKnockbackToHumanoid(targetHumanoid, root.Position, SHOCKWAVE_KNOCKBACK)
		end

		spawnShockwaveDebris(root.Position, { character })
	end

	if abilityName == "ThrowRock" then
		local character = getCharacter(self.player)
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

		local dir = root.CFrame.LookVector
		local spawnPos =
			root.Position
			+ (dir * ROCK_SPAWN_FORWARD_OFFSET)
			+ Vector3.new(0, ROCK_SPAWN_UP_OFFSET, 0)

		-- This ability delegates to spawnRockBezier so projectile logic stays isolated from the router.
		spawnRockBezier(character, spawnPos, dir)
	end

	AbilityController.startCooldown(self, abilityName, def.cooldown)
end

--// Controllers storage
-- Controllers are stored by Player so we can safely remove them on PlayerRemoving and avoid stale references.
local controllers: {[Player]: AbilityControllerT} = {}

local function getController(player: Player): AbilityControllerT
	local controller = controllers[player]
	if controller == nil then
		controller = AbilityController.new(player)
		controllers[player] = controller
	end
	return controller
end

Players.PlayerRemoving:Connect(function(player: Player)
	-- Cleanup prevents the controllers table from growing forever across sessions.
	controllers[player] = nil
end)

abilityRequest.OnServerEvent:Connect(function(player: Player, abilityName: any)
	-- Remote input is untrusted. Validating types early prevents bad indexing and makes exploit attempts harmless.
	if typeof(abilityName) ~= "string" then
		return
	end

	local controller = getController(player)
	controller:tryCast(abilityName)
end)



