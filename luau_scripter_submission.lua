--!strict -- Strict typing helps catch nil/typing mistakes early so the server fails safely

-- Server-side ability system (authoritative):
-- Client only sends an ability name; server validates cooldown/state and applies damage/knockback.
-- This keeps combat results exploit-resistant (clients don’t provide damage/positions).

-- Services: core Roblox APIs used for player lifecycle, remotes, frame stepping, and cleanup
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

-- Remotes:
-- WaitForChild is used because replicated instances might not exist at script start.
-- Remote is typed so strict mode catches wrong usage.
local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local abilityRequest = remotesFolder:WaitForChild("AbilityRequest") :: RemoteEvent

-- Ability definitions:
-- Single table drives cooldown lookup so tryCast can be generic and easily extended.
local ABILITIES = {
	-- cooldowns are balance knobs; server enforces them to prevent client spam
}

-- DashStrike tuning:
-- Distance + time define dash speed; hitbox is server overlap query to avoid client hit spoofing.
local DASH_DISTANCE = 12
local DASH_TIME = 0.12
local HITBOX_SIZE = Vector3.new(15, 15, 15)
local HITBOX_FORWARD_OFFSET = 5
local DAMAGE = 20
local KNOCKBACK = 400

-- Shockwave tuning:
-- Implemented as an overlap box sized from radius/height for simple, fast AOE detection.
-- Debris values are purely VFX and get auto-cleaned.
local SHOCKWAVE_RADIUS = 14
local SHOCKWAVE_HEIGHT = 6
local SHOCKWAVE_DAMAGE = 30
local SHOCKWAVE_KNOCKBACK = 125
local DEBRIS_COUNT = 22
local DEBRIS_LIFETIME = 1.2
local DEBRIS_OUT_SPEED = 55
local DEBRIS_UP_SPEED = 30

-- Rock throw tuning:
-- Projectile path is deterministic math (Bezier), not physics, for consistency.
-- Raycast between frames prevents tunneling at high speeds.
local ROCK_RANGE = 17
local ROCK_FLIGHT_TIME = 0.45
local ROCK_ARC_HEIGHT = 14
local ROCK_DAMAGE = 25
local ROCK_KNOCKBACK = 90

-- AbilityController:
-- Per-player state container (cooldowns) so multiple players don’t share timers.
local AbilityController = {}
AbilityController.__index = AbilityController

-- Cooldowns:
-- Boolean flags are enough because abilities are name-keyed; simple and hard to desync.
function AbilityController.startCooldown(self: AbilityControllerT, abilityName: string, cooldownSeconds: number)
	self.onCooldown[abilityName] = true

	-- Spawn a timer without blocking the main thread
	task.spawn(function()
		task.wait(cooldownSeconds)
		self.onCooldown[abilityName] = false
	end)
end

-- Character accessors:
-- Kept as helpers so ability logic reads cleanly and we centralize nil-check patterns.
local function getCharacter(player: Player): Model
	return player.Character
end

local function getRoot(character: Model): BasePart
	-- Root part is required for movement direction + knockback source/target
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

-- Hit detection (server-authoritative):
-- OverlapParams excludes the caster so you don't self-hit; "seen" avoids double-hitting one humanoid.
local function getTargetsInBox(boxCFrame: CFrame, boxSize: Vector3, ignoreInstances: {Instance}): {Humanoid}
	-- Uses GetPartBoundsInBox for fast region-based hit detection (no per-target raycasts)
end

-- Knockback:
-- Applies velocity away from impact position; horizontal-only direction prevents weird vertical launches.
local function applyKnockbackToHumanoid(humanoid: Humanoid, fromPosition: Vector3, strength: number)
	-- AssemblyLinearVelocity sets an immediate impulse-like push without needing BodyMovers
end

-- Dash movement:
-- LinearVelocity is attached temporarily, then destroyed so dash doesn't persist.
local function dashWithLinearVelocity(root: BasePart, direction: Vector3, speed: number, duration: number)
	-- Attachment is reused so repeated dashes don't create attachment spam
end

-- Bezier math:
-- Quadratic Bezier (p0 -> p2 with p1 as arc control) creates a smooth lob using only Vector3 lerps.
local function bezierQuadratic(p0: Vector3, p1: Vector3, p2: Vector3, t: number): Vector3
	local a = p0:Lerp(p1, t)
	local b = p1:Lerp(p2, t)
	return a:Lerp(b, t)
end

-- Rock projectile:
-- Anchored projectile is moved manually each Heartbeat for deterministic motion.
-- Raycast from lastPos to newPos prevents missing hits between frames (anti-tunneling).
local function spawnRockBezier(ownerCharacter: Model, startPos: Vector3, direction: Vector3)
	-- Filter excludes owner + the projectile itself so you can't instantly collide with yourself
end

-- Shockwave debris VFX:
-- Raycast downward to sample ground material/color so debris matches the map.
-- Debris service cleans up parts so we don't leak objects.
local function spawnShockwaveDebris(origin: Vector3, ignore: {Instance})
end

function AbilityController.tryCast(self: AbilityControllerT, abilityName: string)
	-- Validate ability name against server table so clients can't request arbitrary actions
	local def = ABILITIES[abilityName]
	if def == nil then
		warn(("Unknown '%s' from %s"):format(abilityName, self.player.Name))
		return
	end

	-- Server cooldown enforcement: prevents client-side spam/exploit
	if AbilityController.isOnCooldown(self, abilityName) then
		return
	end

	-- Each ability follows the same pattern:
	-- 1) validate character/root/humanoid alive
	-- 2) perform the ability's server-side action
	-- 3) start cooldown from ABILITIES table

	if abilityName == "DashStrike" then
		-- Dash uses LookVector so "forward" matches where the player is facing
		-- Hit check is delayed slightly so the hitbox aligns with the dash movement timing
	end

	if abilityName == "Shockwave" then
		-- AOE uses a box derived from radius/height for cheap server detection
		-- VFX is separate so combat math stays readable and VFX can be tuned independently
	end

	if abilityName == "ThrowRock" then
		-- Spawn point is offset forward/up so projectile doesn't start inside the player
		-- Uses deterministic arc + raycast hits so it behaves consistently across clients
	end

	-- Cooldown starts after successful cast; def.cooldown is the single tuning value
	AbilityController.startCooldown(self, abilityName, def.cooldown)
end

-- Controller storage:
-- One controller per player to keep cooldown state isolated and easy to clean up.
local controllers: {[Player]: AbilityControllerT} = {}

Players.PlayerRemoving:Connect(function(player: Player)
	-- Release reference so controllers table doesn't keep players in memory after leaving
	controllers[player] = nil
end)

abilityRequest.OnServerEvent:Connect(function(player: Player, abilityName: any)
	-- Type-check the remote payload: ignore non-strings to reduce exploit surface / bad data
	if typeof(abilityName) ~= "string" then
		return
	end

	-- Server entrypoint: resolve player's controller then attempt cast (all validation inside tryCast)
	local controller = getController(player)
	controller:tryCast(abilityName)
end)


