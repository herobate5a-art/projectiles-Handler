-- this module is the main system for all gun bullets
-- it handles how bullets move, hit things, and the effects they make
local projectileHandler = {}
projectileHandler.__index = projectileHandler

local runService = game:GetService("RunService")
local debris = game:GetService("Debris")

-- simple types to keep the data organized
type weaponType = "Pistol" | "SMG" | "Sniper"

type projectileData = {
	bulletType: weaponType,
	muzzleRef: Attachment,
	mousePos: Vector3,
	player: Player
}

-- internal signal system to handle hit events easily
local internalSignal = {}
internalSignal.__index = internalSignal

-- creates a new table to store all functions that should run on hit
function internalSignal.new()
	local self = setmetatable({}, internalSignal)
	self._activeConnections = {}
	return self
end

-- adds a new function to the list of connections to be called later
function internalSignal:connect(callback)
	local connection = {callback = callback, isActive = true}
	table.insert(self._activeConnections, connection)
	
	return {
		disconnect = function()
			connection.isActive = false
		end
	}
end

-- loops through the connections list and executes each function using task.spawn
function internalSignal:fire(...)
	for i = #self._activeConnections, 1, -1 do
		local conn = self._activeConnections[i]
		if conn.isActive then
			task.spawn(conn.callback, ...)
		else
			-- removes broken or disconnected functions from the table
			table.remove(self._activeConnections, i)
		end
	end
end

-- empties the connections table to stop all signals for this object
function internalSignal:destroy()
	self._activeConnections = {}
end

-- the main bullet object setup
local bulletObj = {}
bulletObj.__index = bulletObj

-- sets up the bullet data, calculates direction, and starts the object
function bulletObj.new(data: projectileData)
	local self = setmetatable({}, bulletObj)

	-- assigns all the basic info like player and start position to the object
	self.user = data.player
	self.kind = data.bulletType
	self.spawnPos = data.muzzleRef.WorldPosition
	self.currentPos = self.spawnPos
	self.creationTime = os.clock()
	self.isDead = false

	-- calculates the direction by subtracting start point from end point
	local dirVector = (data.mousePos - self.spawnPos)
	local lookDir = dirVector.Unit

	-- prevents errors if the magnitude is zero by setting a default up direction
	if dirVector.Magnitude < 0.001 then
		lookDir = Vector3.new(0, 1, 0)
	end

	-- assigns specific physics values like speed and gravity based on weapon kind
	if self.kind == "Sniper" then
		self.velocityValue = 550
		self.dropForce = Vector3.new(0, -8, 0)
		self.pierceCount = 3
		self.partSize = Vector3.new(0.1, 0.1, 5)
		self.mainColor = Color3.fromRGB(255, 40, 40)

	elseif self.kind == "SMG" then
		self.velocityValue = 220
		self.dropForce = Vector3.new(0, -45, 0)
		self.pierceCount = 0
		self.partSize = Vector3.new(0.1, 0.1, 1.8)
		self.mainColor = Color3.fromRGB(255, 255, 255)

	else -- standard pistol settings
		self.velocityValue = 160
		self.dropForce = Vector3.new(0, -30, 0)
		self.pierceCount = 0
		self.partSize = Vector3.new(0.1, 0.1, 1.2)
		self.mainColor = Color3.fromRGB(255, 210, 0)
	end

	self.currentVelocity = lookDir * self.velocityValue
	self.onHit = internalSignal.new()

	-- runs security functions to check if the shot is allowed
	local canSpawn = self:_runSecurityChecks(data.muzzleRef)

	if canSpawn then
		-- creates the visual part if the security check passes
		self:_buildVisuals(lookDir)
	else
		-- cleans up the object immediately if the shot is blocked
		self:remove()
	end

	return self
end

-- validates the muzzle position and checks for walls near the player
function bulletObj:_runSecurityChecks(muzzle: Attachment): boolean
	local char = self.user.Character
	if not char then return false end

	local root = char:FindFirstChild("HumanoidRootPart")
	if not root then return false end

	-- measures distance between player and gun to prevent reach exploits
	local gap = (muzzle.WorldPosition - root.Position).Magnitude
	if gap > 18 then return false end

	-- uses a raycast to see if the player is trying to shoot through a wall
	local wallParams = RaycastParams.new()
	wallParams.FilterType = Enum.RaycastFilterType.Exclude
	wallParams.FilterDescendantsInstances = {char}

	local hitWall = workspace:Raycast(root.Position, (muzzle.WorldPosition - root.Position), wallParams)

	if hitWall then
		return false
	end

	return true
end

-- creates a new Part and adds a Trail for the bullet visual
function bulletObj:_buildVisuals(direction: Vector3)
	local bulletModel = Instance.new("Part")
	bulletModel.Size = self.partSize
	bulletModel.Color = self.mainColor
	bulletModel.Material = Enum.Material.Neon
	bulletModel.Anchored = true
	bulletModel.CanCollide = false
	bulletModel.CanQuery = false
	bulletModel.CastShadow = false

	-- sets the initial position and rotation of the bullet part
	bulletModel.CFrame = CFrame.new(self.currentPos, self.currentPos + direction)
	bulletModel.Parent = workspace

	-- creates attachments and a trail to show the bullet path
	local startAtt = Instance.new("Attachment", bulletModel)
	startAtt.Position = Vector3.new(0, self.partSize.Y/2, 0)

	local endAtt = Instance.new("Attachment", bulletModel)
	endAtt.Position = Vector3.new(0, -self.partSize.Y/2, 0)

	local tracer = Instance.new("Trail", bulletModel)
	tracer.Attachment0 = startAtt
	tracer.Attachment1 = endAtt
	tracer.Color = ColorSequence.new(self.mainColor)
	tracer.Transparency = NumberSequence.new(0, 1)
	tracer.Lifetime = 0.08

	self.visualPart = bulletModel
end

-- calculates new position and checks for collisions using Raycast
function bulletObj:update(dt: number)
	if self.isDead then return end

	-- stops the bullet if it lives longer than the max time
	if os.clock() - self.creationTime > 3.5 then
		self:remove()
		return
	end

	local oldPos = self.currentPos
	local nextVel = self.currentVelocity + (self.dropForce * dt)
	local moveAmount = (self.currentVelocity + nextVel) * 0.5 * dt

	-- fires a ray from old position to the new one to detect hits
	local castParams = RaycastParams.new()
	castParams.FilterType = Enum.RaycastFilterType.Exclude
	castParams.FilterDescendantsInstances = {self.visualPart, self.user.Character}

	local hitResult = workspace:Raycast(oldPos, moveAmount, castParams)

	if hitResult then
		-- handles the hit logic if the ray touches something
		self:_onCollision(hitResult)
	else
		-- updates the math position if the path is clear
		self.currentPos += moveAmount
		self.currentVelocity = nextVel
	end

	-- moves the visual part to match the new calculated position
	if self.visualPart then
		self.visualPart.CFrame = CFrame.new(self.currentPos, self.currentPos + self.currentVelocity)
	end
end

-- deals damage to humanoids and triggers the hit signal
function bulletObj:_onCollision(result: RaycastResult)
	local partHit = result.Instance
	local modelHit = partHit:FindFirstAncestorOfClass("Model")
	local targetHuman = modelHit and modelHit:FindFirstChildOfClass("Humanoid")

	-- applies damage from the table if a humanoid is found
	if targetHuman and targetHuman.Health > 0 then
		local damageTable = { Sniper = 80, SMG = 10, Pistol = 25 }
		local finalDmg = damageTable[self.kind] or 20
		targetHuman:TakeDamage(finalDmg)
	end

	-- calls the onHit signal functions with the hit data
	self.onHit:fire(partHit, result.Position, targetHuman)

	-- handles sniper piercing by decreasing count and continuing movement
	if self.kind == "Sniper" and self.pierceCount > 0 then
		if not targetHuman then
			self.pierceCount -= 1
			self.currentPos = result.Position + (self.currentVelocity.Unit * 0.6)
			return
		end
	end

	-- creates effects and starts the removal process
	self:_spawnImpactVFX(result.Position)
	self:remove()
end

-- spawns a temporary part and emits particles for impact visuals
function bulletObj:_spawnImpactVFX(pos: Vector3)
	local vfxAnchor = Instance.new("Part")
	vfxAnchor.Size = Vector3.new(0.05, 0.05, 0.05)
	vfxAnchor.Transparency = 1
	vfxAnchor.Anchored = true
	vfxAnchor.Position = pos
	vfxAnchor.CanCollide = false
	vfxAnchor.Parent = workspace

	local sparks = Instance.new("ParticleEmitter", vfxAnchor)
	sparks.Color = ColorSequence.new(self.mainColor)
	sparks.Size = NumberSequence.new(0.25, 0)
	sparks.Lifetime = NumberRange.new(0.15, 0.35)
	sparks.Speed = NumberRange.new(6, 12)
	sparks.Rate = 500
	sparks:Emit(12)

	-- schedules the vfx part to be destroyed after 0.6 seconds
	debris:AddItem(vfxAnchor, 0.6)
end

-- clears memory and destroys instances related to this bullet
function bulletObj:remove()
	if self.isDead then return end
	self.isDead = true

	if self.visualPart then
		self.visualPart:Destroy()
	end

	self.onHit:destroy()
	setmetatable(self, nil)
end

-- a table to keep track of all bullets currently in flight
local activeBullets = {}

-- initializes a new Pistol bullet and adds it to the active table
function projectileHandler.firePistol(muzzle, target, owner)
	local b = bulletObj.new({
		bulletType = "Pistol",
		muzzleRef = muzzle,
		mousePos = target,
		player = owner
	})

	if b and not b.isDead then
		table.insert(activeBullets, b)
	end
end

-- initializes a new SMG bullet and adds it to the active table
function projectileHandler.fireSMG(muzzle, target, owner)
	local b = bulletObj.new({
		bulletType = "SMG",
		muzzleRef = muzzle,
		mousePos = target,
		player = owner
	})

	if b and not b.isDead then
		table.insert(activeBullets, b)
	end
end

-- initializes a new Sniper bullet and adds it to the active table
function projectileHandler.fireSniper(muzzle, target, owner)
	local b = bulletObj.new({
		bulletType = "Sniper",
		muzzleRef = muzzle,
		mousePos = target,
		player = owner
	})

	if b and not b.isDead then
		table.insert(activeBullets, b)
	end
end

-- runs the update function for every bullet in the active list every frame
runService.Heartbeat:Connect(function(dt)
	for i = #activeBullets, 1, -1 do
		local b = activeBullets[i]

		if not b or b.isDead then
			-- removes bullets that are finished from the list
			table.remove(activeBullets, i)
		else
			-- calls the movement and collision update
			b:update(dt)
		end
	end
end)

return projectileHandler

--how to use the library down there

-- localScript inside the tool that handler for weapons
--[[(localScript)
local weaponTool = script.Parent
local clientPlayer = game.Players.LocalPlayer
local runService = game:GetService("RunService")

-- this event must exist inside the tool
local shootEvent = weaponTool:WaitForChild("ShootEvent") 

-- setup weapon specs
local fireRate = 0.5 -- (put here the weapon fire rate)
local lastShotTime = 0

local function attemptFire()
	if os.clock() - lastShotTime < fireRate then return end
	lastShotTime = os.clock()

	local mouse = clientPlayer:GetMouse()
	local target = mouse.Hit.Position

	-- send the signal to the server
	shootEvent:FireServer(target)
end

-- trigger the fire function
weaponTool.Activated:Connect(function()
	attemptFire()
end)]]

--[[(ServerScript)
-- server-side handler that communicates with the module
local weaponTool = script.Parent
local storage = game:GetService("ReplicatedStorage")

-- this event must be manually created inside the tool
local shootEvent = weaponTool:WaitForChild("ShootEvent") 

-- require our main projectile module
local bulletManager = require(storage:WaitForChild("ProjectileService"))

-- configurations
local gunHandle = weaponTool:WaitForChild("Handle")
local muzzlePoint = gunHandle:WaitForChild("Muzzle")

shootEvent.OnServerEvent:Connect(function(player, targetPos)	
	local weaponType = "Pistol" 
	
	if weaponType == "Pistol" then
		bulletManager.firePistol(muzzlePoint, targetPos, player)
	elseif weaponType == "SMG" then
		bulletManager.fireSMG(muzzlePoint, targetPos, player)
	elseif weaponType == "Sniper" then
		bulletManager.fireSniper(muzzlePoint, targetPos, player)
	end
end)
]]

--DONE!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
