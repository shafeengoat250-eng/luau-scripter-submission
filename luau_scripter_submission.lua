--!strict

-- Services used by this server-side ability handler:
-- Players: player lifecycle + events (PlayerRemoving)
-- ReplicatedStorage: shared remotes container (client -> server requests)
-- RunService: per-frame stepping for projectile motion (Heartbeat)
-- Debris: timed cleanup for temporary physical parts (shockwave debris)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

-- RemoteEvent entrypoint:
-- The client asks to cast an ability by sending the ability name.
-- The server owns validation, cooldowns, hit detection, and damage.
local remotesFolder = ReplicatedStorage.Remotes
local abilityRequest =  remotesFolder.AbilityRequest:: RemoteEvent

-- Ability definitions:
-- Central place to tune cooldowns per ability (anti-spam + balancing).
-- The server consults this table to verify the ability exists.
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

-- DashStrike tuning:
-- DashDistance/DashTime define dash speed (distance / time).
-- Hitbox params define where and how big the "strike" check is after dashing.
-- Damage/Knockback define outcomes applied to valid targets.
local DASH_DISTANCE = 12
local DASH_TIME = 0.12
local HITBOX_SIZE = Vector3.new(15, 15, 15)
local HITBOX_FORWARD_OFFSET = 5
local DAMAGE = 20
local KNOCKBACK = 250

-- Shockwave tuning:
-- Uses a box query to include a controlled vertical slice (height) and radius-like width.
-- Debris settings are for visual feedback (spawned parts that burst outward then clean up).
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

-- ThrowRock tuning:
-- Projectile is moved along a quadratic Bezier arc for predictable flight.
-- Range/FlightTime define how far and how fast it travels.
-- ArcHeight defines the "lob" feel.
-- Damage/Knockback apply if a humanoid is hit via raycast along steps.
local ROCK_RANGE = 30
local ROCK_FLIGHT_TIME = 0.45
local ROCK_ARC_HEIGHT = 10
local ROCK_DAMAGE = 50
local ROCK_KNOCKBACK = 90
local ROCK_SIZE = Vector3.new(3,3,3)
local ROCK_SPAWN_FORWARD_OFFSET = 1
local ROCK_SPAWN_UP_OFFSET = 1

-- AbilityController:
-- One controller per player to track cooldown state.
-- This avoids global cooldown collisions between different players.
local AbilityController = {}
AbilityController.__index = AbilityController

-- Stored controller data:
-- player: owning player
-- onCooldown: map of abilityName -> boolean (true while cooling down)
type AbilityControllerData = {
	player: Player,
	onCooldown: {[string]: boolean},
}

-- Public controller interface:
-- isOnCooldown: check a specific ability cooldown state
-- startCooldown: begin cooldown timer (server-side authority)
-- tryCast: validate + execute ability, then start cooldown if successful
export type AbilityControllerT = AbilityControllerData & {
	isOnCooldown: (self: AbilityControllerT, abilityName: string) -> boolean,
	startCooldown: (self: AbilityControllerT, abilityName: string, cooldownSeconds: number) -> (),
	tryCast: (self: AbilityControllerT, abilityName: string) -> (),
}

-- Constructor:
-- Creates a new cooldown table for this player and attaches methods via metatable.
function AbilityController.new(player: Player): AbilityControllerT
	local self: AbilityControllerData = {
		player = player,
		onCooldown = {},
	}

	return setmetatable(self:: any, AbilityController) :: any
end

-- Cooldown read:
-- Explicit true-check keeps nil/false meaning "not cooling down".
function AbilityController.isOnCooldown(self: AbilityControllerT, abilityName: string): boolean
	return self.onCooldown[abilityName] == true
end

-- Cooldown write:
-- Sets flag immediately, then clears after cooldownSeconds.
-- Runs async so ability cast doesn’t block the main thread.
function AbilityController.startCooldown(self: AbilityControllerT, abilityName: string, cooldownSeconds: number)
	
	self.onCooldown[abilityName] = true

	task.spawn(function()
		task.wait(cooldownSeconds)
		self.onCooldown[abilityName] = false
	end)
end

-- Character helper:
-- Used to keep tryCast readable and centralized.
-- Note: player.Character can be nil during respawn or if the player has no character.
local function getCharacter(player: Player): Model
	return player.Character
end

-- Humanoid helper:
-- Used to confirm target is alive and to apply TakeDamage.
local function getHumanoid(character: Model): Humanoid
	return character:FindFirstChildOfClass("Humanoid")
end

-- Root helper:
-- HumanoidRootPart is the reference for position, forward direction, and applying velocity.
-- Returns nil if missing or not a BasePart (defensive).
local function getRoot(character: Model): BasePart
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

-- Server hit detection helper:
-- Queries parts inside a box and returns unique humanoids found.
-- ignoreInstances prevents hitting the caster and other ignored objects.
-- The "seen" map prevents duplicates (multiple parts in the same character).
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

-- Knockback application:
-- Uses the difference between the target root and the impact origin to push away horizontally.
-- Adds a small upward component to make knockback feel punchier and avoid ground friction deadening.
-- Uses AssemblyLinearVelocity for immediate physics response.
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

	-- Fallback direction if the positions are nearly identical (prevents NaN from unit vector).
	if horizontal.Magnitude < 0.001 then
		horizontal = Vector3.new(0, 0, -1)
	end

	root.AssemblyLinearVelocity = Vector3.new(
		horizontal.Unit.X * strength,
		root.AssemblyLinearVelocity.Y + 12,
		horizontal.Unit.Z * strength
	)
end

-- Dash movement:
-- Creates (or reuses) an Attachment on the root, then applies a LinearVelocity burst.
-- The velocity is destroyed after duration to avoid leaving movement forces behind.
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

-- Quadratic Bezier:
-- Used to compute projectile arc positions cheaply and deterministically.
-- t should typically be in [0, 1] for standard Bezier usage.
local function bezierQuadratic(p0: Vector3, p1: Vector3, p2: Vector3, t: number): Vector3
	local a = p0:Lerp(p1, t)
	local b = p1:Lerp(p2, t)
	return a:Lerp(b, t)
end

-- Rock projectile:
-- Anchored part moved per-frame along Bezier curve.
-- Raycast between frames prevents tunneling (fast-moving projectile skipping collisions).
-- Excludes ownerCharacter and the rock itself from raycast checks.
local function spawnRockBezier(ownerCharacter: Model, startPos: Vector3, direction: Vector3)
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

	-- Heartbeat loop:
	-- Moves projectile forward based on dt to keep time-based travel consistent across server FPS.
	-- Disconnects + destroys rock on hit or end-of-flight to avoid leaks.
	conn = RunService.Heartbeat:Connect(function(dt: number)
		if hit then
			return
		end

		-- Progress parameter increments by normalized dt.
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

				-- On any collision, cleanup immediately (even if it didn't hit a humanoid).
				if conn then conn:Disconnect() end
				if rock.Parent then rock:Destroy() end
				return
			end
		end

		-- Apply movement:
		rock.Position = pos

	
		-- Face the direction of travel (small UX polish for projectiles).
		if step.Magnitude > 0.001 then
			rock.CFrame = CFrame.lookAt(pos, pos + step.Unit)
		end

		lastPos = pos

		-- End-of-flight cleanup:
		if t >= 2 then
			if conn then conn:Disconnect() end
			if rock.Parent then rock:Destroy() end
		end
	end)
end

-- Shockwave debris visuals:
-- Spawns small parts around the origin, aligned to the ground via downward raycast.
-- Copies material/color from the hit ground part when possible for better immersion.
-- Applies a short LinearVelocity impulse outward/upward, then removes it and lets Debris cleanup.
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

		-- Position slightly above the hit surface along the normal (prevents z-fighting/clipping).
		rock.CFrame = CFrame.lookAt(hitPos + hitNormal * (size * 0.5), hitPos + hitNormal) * CFrame.Angles(
			math.rad(math.random(0, 360)),
			math.rad(math.random(0, 360)),
			math.rad(math.random(0, 360))
		)
		rock.Parent = workspace

		-- Outward direction is computed in the horizontal plane so debris spreads around the origin.
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
			-- Short impulse window keeps effect snappy; then physics takes over naturally.
			task.wait(0.15)
			if lv.Parent then
				lv:Destroy()
			end
		end)

	
		-- Always cleanup debris parts to prevent workspace clutter.
		Debris:AddItem(rock, DEBRIS_LIFETIME)
	end
end

-- Ability execution:
-- Validates ability name exists, checks cooldown, validates character/humanoid/root are present and alive,
-- then runs the matching ability logic.
-- Cooldown is started after execution is triggered to prevent spamming.
function AbilityController.tryCast(self: AbilityControllerT, abilityName: string)
	local def = ABILITIES[abilityName]
	if def == nil then
		-- Logging unknown ability names helps detect exploit attempts or desync bugs.
		warn(("Unknown '%s' from %s"):format(abilityName, self.player.Name))
		return
	end


	-- Hard server cooldown gate: if true, ignore the request silently (no gameplay effect).
	if AbilityController.isOnCooldown(self, abilityName) then
		return
	end

	-- DashStrike:
	-- 1) dash forward using LinearVelocity for a short time
	-- 2) after a small delay, query a forward hitbox and apply damage/knockback
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
			-- Delay synchronizes the hit with the dash movement (feels like a strike at the front).
			task.wait(0.05)

			local hitboxCFrame = root.CFrame + (root.CFrame.LookVector * HITBOX_FORWARD_OFFSET)
			local targets = getTargetsInBox(hitboxCFrame, HITBOX_SIZE, { character })

			for _, targetHumanoid in ipairs(targets) do
				targetHumanoid:TakeDamage(DAMAGE)
				applyKnockbackToHumanoid(targetHumanoid, root.Position, KNOCKBACK)
			end
		end)
	end

	-- Shockwave:
	-- 1) query a box around the caster to find nearby humanoids within radius/height
	-- 2) apply damage + knockback from caster position
	-- 3) spawn short-lived debris visuals
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

	-- ThrowRock:
	-- 1) compute spawn position slightly forward and up from the caster
	-- 2) launch an anchored projectile along a Bezier arc and raycast for collisions
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

		spawnRockBezier(character, spawnPos, dir)
	end

	-- Starts cooldown after ability work begins to prevent immediate recast requests.
	AbilityController.startCooldown(self, abilityName, def.cooldown)
end

-- Controller cache:
-- Stores per-player controllers so cooldowns persist across multiple remote calls.
local controllers: {[Player]: AbilityControllerT} = {}

-- Fetch-or-create controller:
-- Ensures each player has exactly one controller instance while they’re in the server.
local function getController(player: Player): AbilityControllerT
	local controller = controllers[player]
	if controller == nil then
		controller = AbilityController.new(player)
		controllers[player] = controller
	end
	return controller
end

-- PlayerRemoving cleanup:
-- Remove controller to avoid memory leaks and stale references.
Players.PlayerRemoving:Connect(function(player: Player)
	
	controllers[player] = nil
end)

-- Remote handler:
-- Validates abilityName type to prevent non-string payloads.
-- Routes to the player's controller which handles cooldown + execution.
abilityRequest.OnServerEvent:Connect(function(player: Player, abilityName: any)

	if typeof(abilityName) ~= "string" then
		return
	end

	local controller = getController(player)
	controller:tryCast(abilityName)
end)
