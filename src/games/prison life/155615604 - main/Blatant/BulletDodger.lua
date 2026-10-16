local BulletDodger
local Targets
local Range
local MissDistance
local AimDetection
local ShotDetection
local DamageDetection
local RemoteDetection
local TracerDetection
local GunHooks
local CombatTime
local DodgeTime
local Interval
local Cooldown
local DodgeMode
local MoveMethod
local Speed
local SafePath
local GroundCheck
local JumpChance
local JumpDelay
local TeamCheck
local Weapons
local ShowLines
local Notify
local DebugLog

local threat = {
	Axis = Vector3.new(1, 0, 0),
	Entity = nil,
	Source = 'None',
	Time = 0,
	Urgent = false
}
local dodge = {
	Active = false,
	Cooldown = 0,
	Flip = 0,
	Jump = 0,
	NextLog = 0,
	NextScan = 0,
	Side = 1,
	Until = 0
}
local loggedRemotes, lines = {}, {}
local hooked, healthConnection, lastHealth = false, nil, 0
local remoteCount, remoteFired = 0, 0

local rayCheck = RaycastParams.new()
rayCheck.RespectCanCollide = true
rayCheck.FilterType = Enum.RaycastFilterType.Exclude

-- The games own bullet group so line of sight matches what a bullet can actually reach
local bulletGroup = pcall(function()
	rayCheck.CollisionGroup = 'ClientBullet'
end) and 'ClientBullet' or 'Default'

local function notifBullet(text)
	if Notify.Enabled then
		notif('BulletDodger', text, 2)
	end
end

local function console(...)
	if DebugLog.Enabled then
		print('[BulletDodger]', ...)
	end
end

local function logBullet(text)
	local now = os.clock()
	if DebugLog.Enabled and dodge.NextLog < now then
		dodge.NextLog = now + 0.5
		print('[BulletDodger]', text)
	end

	if Notify.Enabled then
		notif('BulletDodger', text, 3)
	end
end

local function printStatus()
	print('[BulletDodger] status')
	print('  place: '..tostring(game.PlaceId))
	print('  alive: '..tostring(entitylib.isAlive))
	print('  pl.Shoot: '..tostring(pl and pl.Shoot ~= nil)..' | pl.Bullet: '..tostring(pl and pl.Bullet ~= nil))
	print('  GunTracers: '..tostring(pl and pl.GunTracers ~= nil)..(hooked and ' (hooked)' or ' (not hooked)'))
	print('  gun remotes watched: '..tostring(remoteCount)..' | fired at least once: '..tostring(remoteFired))
	print('  mode: '..tostring(DodgeMode.Value)..' | method: '..tostring(MoveMethod.Value)..' | range: '..tostring(Range.Value))
end

local function horizontal(vec)
	local flat = vec * Vector3.new(1, 0, 1)
	if flat.Magnitude < 0.05 then
		return nil
	end

	return flat.Unit
end

-- Distance from a point to a ray, or to a segment when a length is given
local function pointToLine(origin, direction, point, length)
	local delta = point - origin
	local projection = delta:Dot(direction)
	if projection <= 0 then
		return delta.Magnitude
	end

	if length and projection > length then
		projection = length
	end

	return (delta - (direction * projection)).Magnitude
end

local function setFilter(instances, group)
	rayCheck.FilterDescendantsInstances = instances
	rayCheck.CollisionGroup = group or bulletGroup
end

local function canSee(from, to, character)
	setFilter(character and {lplr.Character, character, workspace.CurrentCamera} or {lplr.Character, workspace.CurrentCamera})
	return workspace:Raycast(from, to - from, rayCheck) == nil
end

local function isWeapon(tool)
	local list = Weapons and Weapons.List
	if list and #list > 0 then
		for _, name in list do
			if tool.Name:lower() == tostring(name):lower() then
				return true
			end
		end

		return false
	end

	return true
end

local function isHostile(entity)
	if entity.Health <= 0 or not entity.RootPart then
		return false
	end

	if not entity.Player then
		return Targets.NPCs.Enabled
	end

	if isFriend(entity.Player) then
		return false
	end

	if TeamCheck.Enabled and entity.Player.Team == lplr.Team then
		return entity.Character:GetAttribute('Hostile') == true
	end

	return true
end

local function getGun(entity)
	local character = entity.Character
	local tool = character and character:FindFirstChildWhichIsA('Tool', true)
	if tool and isWeapon(tool) then
		return tool
	end

	return nil
end

local function getAimLine(entity, gun)
	if not entity.Head or not entity.Head.Parent then
		return nil
	end

	local head = entity.Head
	local origin = head.Position
	if gun then
		local muzzle = gun:FindFirstChild('Muzzle', true)
		if muzzle and muzzle:IsA('BasePart') then
			origin = muzzle.Position
		end
	end

	return origin, head.CFrame.LookVector
end

local function getClosestThreat()
	if not (entitylib.isAlive and entitylib.character.RootPart) then
		return nil
	end

	local position = entitylib.character.RootPart.Position
	local closest, found = math.huge, nil
	for _, entity in entitylib.List do
		if isHostile(entity) and getGun(entity) then
			local distance = (entity.RootPart.Position - position).Magnitude
			if distance <= Range.Value and distance < closest and canSee(entity.Head.Position, position, entity.Character) then
				closest = distance
				found = entity
			end
		end
	end

	return found
end

local function armThreat(axis, time, source, entity, urgent)
	local flat = axis and horizontal(axis)
	if flat then
		threat.Axis = flat
	end

	if threat.Time < time then
		threat.Time = time
	end

	threat.Source = source
	threat.Entity = entity or threat.Entity
	threat.Urgent = urgent or threat.Urgent
end

local function addLine(origin, direction, length, color)
	if not ShowLines.Enabled or length <= 0 then
		return
	end

	local part = Instance.new('Part')
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CastShadow = false
	part.Color = color
	part.Material = Enum.Material.Neon
	part.Size = Vector3.new(0.12, 0.12, math.max(length, 0.2))
	part.Transparency = 0.4
	part.CFrame = CFrame.lookAt(origin + (direction * (length / 2)), origin + (direction * length))
	part.Parent = workspace
	table.insert(lines, part)
	task.delay(0.35, function()
		local index = table.find(lines, part)
		if index then
			table.remove(lines, index)
		end

		part:Destroy()
	end)
end

-- Every detected shot funnels down to here, origin and point are the muzzle and where the bullet is heading
local function bulletDetected(origin, point, source, shooter)
	if not BulletDodger.Enabled then
		return
	end

	local root = entitylib.isAlive and entitylib.character.RootPart
	if not root then
		return
	end

	local delta = point - origin
	local length = delta.Magnitude
	if length < 0.1 then
		return
	end

	local direction = delta.Unit
	if length < 2 then
		length = Range.Value
		point = origin + (direction * length)
	end

	local position = root.Position
	if (origin - position).Magnitude < 6 and not shooter then
		return
	end

	local miss = pointToLine(origin, direction, position, length)
	if miss <= MissDistance.Value then
		armThreat(shooter and (position - shooter.RootPart.Position) or direction, os.clock() + CombatTime.Value, source, shooter, true)
		addLine(origin, direction, length, Color3.new(1, 0.25, 0.25))
		notifBullet('Dodging a shot ('..source..')')
		logBullet('Shot from '..source..' was coming for us')
	else
		addLine(origin, direction, length, Color3.new(0.25, 0.6, 1))
		logBullet('Shot from '..source..' missed us by '..math.floor(miss)..' studs')
	end
end

-- A lone position we can not turn into a line, treated as an impact near us
local function impactDetected(position, source, shooter)
	if not BulletDodger.Enabled then
		return
	end

	local root = entitylib.isAlive and entitylib.character.RootPart
	if not root then
		return
	end

	local miss = (position - root.Position).Magnitude
	if miss > MissDistance.Value + 3 then
		return
	end

	local axis = shooter and (root.Position - shooter.RootPart.Position) or (position - root.Position)
	armThreat(axis, os.clock() + CombatTime.Value, source, shooter, true)
	notifBullet('Dodging an impact ('..source..')')
	logBullet('Impact from '..source..' landed '..math.floor(miss)..' studs away')
end

local function gunCalled(name, ...)
	if not (BulletDodger.Enabled and ShotDetection.Enabled) then
		return
	end

	local origin, point = ...
	if typeof(origin) ~= 'Vector3' or typeof(point) ~= 'Vector3' then
		return
	end

	bulletDetected(origin, point, 'Gun '..name, nil)
end

-- Hooking the gun functions directly is the only way to see other players bullets, the games tracer
-- callback is filtered to the local shooter so we can not lean on it here
local function installGunHooks()
	if hooked then
		return
	end

	local gunTracers = pl and pl.GunTracers
	if not gunTracers then
		console('no pl.GunTracers found, cannot hook the guns')
		return
	end

	for _, name in {'createBullet', 'createTaser', 'createSniper'} do
		local original = gunTracers[name]
		if typeof(original) == 'function' then
			local previous = original
			local replacement = function(...)
				gunCalled(name, ...)
				return previous(...)
			end

			previous = hookfunction(original, replacement)
			hooked = true
			console('hooked GunTracers.'..name)
		end
	end
end

local function watchRemote(remote)
	if not remote:IsA('RemoteEvent') and not remote:IsA('UnreliableRemoteEvent') then
		return
	end

	remoteCount = remoteCount + 1
	console('watching remote '..remote.Name)
	remote.OnClientEvent:Connect(function(...)
		if not (BulletDodger.Enabled and RemoteDetection.Enabled) then
			return
		end

		local args = table.pack(...)
		local vectors, shooter = {}, nil
		for index = 1, args.n do
			local value = args[index]
			if typeof(value) == 'Vector3' then
				table.insert(vectors, value)
			elseif typeof(value) == 'Instance' and value:IsA('Player') then
				shooter = entitylib.getEntity(value)
			end
		end

		if not loggedRemotes[remote] then
			loggedRemotes[remote] = true
			remoteFired = remoteFired + 1
			local types = {}
			for index = 1, args.n do
				table.insert(types, typeof(args[index]))
			end

			logBullet(remote.Name..' sent us: '..(#types > 0 and table.concat(types, ', ') or 'nothing'))
		end

		if #vectors >= 2 then
			bulletDetected(vectors[1], vectors[2], 'Remote '..remote.Name, shooter)
		elseif #vectors == 1 then
			impactDetected(vectors[1], 'Remote '..remote.Name, shooter)
		end
	end)
end

local function watchRemotes()
	local folder = replicatedStorage:FindFirstChild('GunRemotes') or replicatedStorage:WaitForChild('GunRemotes', 30)
	if not folder then
		return
	end

	for _, remote in folder:GetChildren() do
		watchRemote(remote)
	end

	folder.ChildAdded:Connect(watchRemote)
end

-- The guns own tracers are long thin parts, if one shows up next to a hostile it is their shot
local function partAdded(object)
	if not object:IsA('BasePart') then
		return
	end

	local size = object.Size
	if size.Z < 5 or size.X > 1.5 or size.Y > 1.5 then
		return
	end

	task.defer(function()
		if not (object.Parent and BulletDodger.Enabled and TracerDetection.Enabled) then
			return
		end

		local cframe, half = object.CFrame, size.Z / 2
		local near = cframe.Position - (cframe.LookVector * half)
		local far = cframe.Position + (cframe.LookVector * half)
		local shooter = nil
		for _, entity in entitylib.List do
			if isHostile(entity) and (entity.Head.Position - near).Magnitude < 20 then
				shooter = entity
				break
			end
		end

		if shooter then
			bulletDetected(near, far, 'Tracer', shooter)
		end
	end)
end

local function bindHealth(entity)
	if healthConnection then
		healthConnection:Disconnect()
		healthConnection = nil
	end

	lastHealth = entity.Humanoid.Health
	healthConnection = entity.Humanoid:GetPropertyChangedSignal('Health'):Connect(function()
		local health = entity.Humanoid.Health
		if health < lastHealth and DamageDetection.Enabled and entitylib.isAlive then
			local shooter = getClosestThreat()
			local root = entitylib.character.RootPart
			local axis = shooter and (root.Position - shooter.RootPart.Position) or workspace.CurrentCamera.CFrame.RightVector
			armThreat(axis, os.clock() + CombatTime.Value, 'Damage', shooter, true)
			notifBullet('Dodging, we got hit')
			logBullet(shooter and ('Hit by '..shooter.Player.Name..', reacting') or 'Hit by something, reacting')
		end

		lastHealth = health
	end)
end

local function pathClear(character, direction)
	local root = character.RootPart
	setFilter({lplr.Character, workspace.CurrentCamera}, root.CollisionGroup)
	if workspace:Blockcast(CFrame.new(root.Position), Vector3.new(2, character.HipHeight + (root.Size.Y / 2), 2), direction * 4, rayCheck) then
		return false
	end

	if GroundCheck.Enabled then
		setFilter({lplr.Character, workspace.CurrentCamera}, root.CollisionGroup)
		if not workspace:Raycast(root.Position + (direction * 4) + Vector3.new(0, 2, 0), Vector3.new(0, -16, 0), rayCheck) then
			return false
		end
	end

	return true
end

local function dodgeDirection(character)
	local axis = threat.Axis
	local left = Vector3.new(-axis.Z, 0, axis.X)
	local right = -left
	if not SafePath.Enabled then
		return dodge.Side > 0 and left or right
	end

	local leftClear, rightClear = pathClear(character, left), pathClear(character, right)
	if leftClear == rightClear then
		return dodge.Side > 0 and left or right
	end

	return leftClear and left or right
end

local function move(character, direction, delta)
	local root, humanoid = character.RootPart, character.Humanoid
	if humanoid.Sit then
		return
	end

	if MoveMethod.Value == 'Velocity' then
		root.AssemblyLinearVelocity = Vector3.new(direction.X * Speed.Value, root.AssemblyLinearVelocity.Y, direction.Z * Speed.Value)
	elseif MoveMethod.Value == 'Walk' then
		humanoid:Move(direction, false)
	else
		root.CFrame = root.CFrame + (direction * (Speed.Value * delta))
	end
end

local function stopMoving(character)
	local root, humanoid = character.RootPart, character.Humanoid
	if MoveMethod.Value == 'CFrame' then
		return
	end

	root.AssemblyLinearVelocity = (humanoid.MoveDirection * humanoid.WalkSpeed) + Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
end

local function tryJump(character)
	local humanoid = character.Humanoid
	if humanoid.Sit or humanoid.FloorMaterial == Enum.Material.Air then
		return
	end

	local now = os.clock()
	if dodge.Jump > now then
		return
	end

	dodge.Jump = now + JumpDelay.Value
	setFilter({lplr.Character, workspace.CurrentCamera}, character.RootPart.CollisionGroup)
	if workspace:Raycast(character.Head.Position, Vector3.new(0, 5, 0), rayCheck) then
		return
	end

	if math.random(1, 100) <= JumpChance.Value then
		humanoid.Jump = true
	end
end

-- Look for anyone currently pointing a gun at us, this is what beats the instant hit guns
local function updateAim()
	local character = entitylib.character
	local position = character.RootPart.Position
	local closest, originOf, entityOf = math.huge, nil, nil
	for _, entity in entitylib.List do
		if isHostile(entity) then
			local gun = getGun(entity)
			if gun then
				local origin, direction = getAimLine(entity, gun)
				local distance = origin and (origin - position).Magnitude
				if distance and distance <= Range.Value and distance < closest and pointToLine(origin, direction, position, Range.Value) <= MissDistance.Value then
					if not Targets.Walls.Enabled or canSee(origin, position, entity.Character) then
						closest, originOf, entityOf = distance, origin, entity
					end
				end
			end
		end
	end

	if originOf then
		armThreat(position - originOf, os.clock() + 0.15, 'Aim', entityOf)
		logBullet('Aimed at by '..(entityOf.Player and entityOf.Player.Name or 'an NPC'))
	end
end

local function update(delta)
	if not (BulletDodger.Enabled and entitylib.isAlive) then
		return
	end

	local character = entitylib.character
	if not character.RootPart then
		return
	end

	local now = os.clock()
	if AimDetection.Enabled and dodge.NextScan < now then
		dodge.NextScan = now + 0.05
		updateAim()
	end

	if not dodge.Active then
		if threat.Time > now and (dodge.Cooldown < now or threat.Urgent) then
			dodge.Active = true
			dodge.Until = now + DodgeTime.Value
			dodge.Flip = now + Interval.Value
			dodge.Side = math.random(1, 2) == 1 and 1 or -1
			threat.Urgent = false
		else
			return
		end
	end

	if threat.Time < now and dodge.Until < now then
		dodge.Active = false
		dodge.Cooldown = now + Cooldown.Value
		threat.Entity = nil
		threat.Source = 'None'
		threat.Urgent = false
		stopMoving(character)
		return
	end

	if dodge.Flip < now then
		dodge.Flip = now + Interval.Value
		dodge.Side = -dodge.Side
	end

	local direction = dodgeDirection(character)
	if DodgeMode.Value ~= 'Jump' then
		move(character, direction, delta)
	end

	if DodgeMode.Value ~= 'Strafe' then
		tryJump(character)
	end
end

local function refreshOptions()
	local mode = DodgeMode.Value
	JumpChance.Object.Visible = mode ~= 'Strafe'
	JumpDelay.Object.Visible = mode ~= 'Strafe'
	Speed.Object.Visible = mode ~= 'Jump'
	MoveMethod.Object.Visible = mode ~= 'Jump'
end

BulletDodger = vape.Categories.Blatant:CreateModule({
	Name = 'BulletDodger',
	Function = function(callback)
		if callback then
			BulletDodger:Clean(entitylib.Events.LocalAdded:Connect(bindHealth))
			if entitylib.isAlive then
				task.spawn(bindHealth, entitylib.character)
			end

			BulletDodger:Clean(function()
				if healthConnection then
					healthConnection:Disconnect()
					healthConnection = nil
				end
			end)

			BulletDodger:Clean(workspace.DescendantAdded:Connect(partAdded))
			BulletDodger:Clean(task.spawn(watchRemotes))
			if GunHooks.Enabled then
				pcall(installGunHooks)
			end

			refreshOptions()
			task.defer(printStatus)
			BulletDodger:Clean(runService.Heartbeat:Connect(update))
		else
			threat.Time = 0
			threat.Entity = nil
			dodge.Active = false
			for _, part in lines do
				part:Destroy()
			end

			table.clear(lines)
			console('disabled')
		end
	end,
	ExtraText = function()
		return dodge.Active and 'Dodging' or nil
	end,
	Tooltip = 'Moves you out of the line of fire.\nAim - Strafes while someone with a gun is aiming at you, this is the only source that works on the instant hit guns\nShots - Strafes when a bullet or tracer is detected\nDamage - Strafes for a moment after you take a hit'
})
Targets = BulletDodger:CreateTargets({
	Players = true,
	Walls = true
})
Range = BulletDodger:CreateSlider({
	Name = 'Range',
	Min = 5,
	Max = 300,
	Default = 100,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end,
	Tooltip = 'Only bother with shooters inside this distance.'
})
MissDistance = BulletDodger:CreateSlider({
	Name = 'Miss Distance',
	Min = 1,
	Max = 30,
	Default = 5,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end,
	Tooltip = 'How close a bullet or an aim line has to pass before it counts as aimed at you.'
})
AimDetection = BulletDodger:CreateToggle({
	Name = 'Aim Detection',
	Default = true,
	Tooltip = 'Dodge while someone with a gun is aiming at you.\nGuns in this game usually hit the moment they are fired, so getting out of the way before the shot is the only dodge that lands.'
})
ShotDetection = BulletDodger:CreateToggle({
	Name = 'Shot Detection',
	Default = true,
	Tooltip = 'Dodge when a bullet is detected, worth having against automatic weapons where the next shot is a moment away.'
})
DamageDetection = BulletDodger:CreateToggle({
	Name = 'Damage Detection',
	Default = true,
	Tooltip = 'Dodge for a few seconds after taking a hit, in case the other sources miss something.'
})
RemoteDetection = BulletDodger:CreateToggle({
	Name = 'Gun Remotes',
	Default = true,
	Darker = true,
	Tooltip = 'Listen to the gun remotes for the exact shot lines.'
})
TracerDetection = BulletDodger:CreateToggle({
	Name = 'Tracer Parts',
	Default = true,
	Darker = true,
	Tooltip = 'Treat the games own tracers as shots, works even if the remotes carry nothing useful.'
})
GunHooks = BulletDodger:CreateToggle({
	Name = 'Gun Hooks',
	Default = false,
	Darker = true,
	Function = function(callback)
		if callback then
			pcall(installGunHooks)
		end
	end,
	Tooltip = 'Hook the gun functions directly.\nThe most accurate source we have for other players shots, but it can interfere with the legit tracer, hit sound and damage indicator modules.'
})
CombatTime = BulletDodger:CreateSlider({
	Name = 'Combat Time',
	Min = 0.1,
	Max = 5,
	Default = 1.5,
	Decimal = 10,
	Darker = true,
	Suffix = function(val)
		return val == 1 and 'second' or 'seconds'
	end,
	Tooltip = 'How long a detected shot or hit keeps us dodging.'
})
DodgeMode = BulletDodger:CreateDropdown({
	Name = 'Dodge',
	List = {'Strafe', 'Jump', 'Strafe & Jump'},
	Function = function()
		refreshOptions()
	end,
	Tooltip = 'Strafe - Side steps perpendicular to the shooter, the safest and the one that actually breaks their aim\nJump - Hops to shift your hitbox, good against shots aimed low but not enough on its own\nStrafe & Jump - Both'
})
MoveMethod = BulletDodger:CreateDropdown({
	Name = 'Method',
	List = {'Velocity', 'Walk', 'CFrame'},
	Darker = true,
	Tooltip = 'Velocity - Physics based and the safest\nWalk - Uses the humanoid mover, looks the most legit but it is slow\nCFrame - Moves the root directly, instant but the anti cheat watches position deltas'
})
Speed = BulletDodger:CreateSlider({
	Name = 'Speed',
	Min = 5,
	Max = 150,
	Default = 55,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end,
	Tooltip = 'How fast we step out of the line of fire.'
})
Interval = BulletDodger:CreateSlider({
	Name = 'Interval',
	Min = 0.05,
	Max = 1,
	Default = 0.3,
	Decimal = 100,
	Suffix = function(val)
		return val == 1 and 'second' or 'seconds'
	end,
	Tooltip = 'How often we switch sides, staying unpredictable is what makes their aim miss.'
})
DodgeTime = BulletDodger:CreateSlider({
	Name = 'Dodge Time',
	Min = 0.05,
	Max = 1,
	Default = 0.25,
	Decimal = 100,
	Darker = true,
	Suffix = function(val)
		return val == 1 and 'second' or 'seconds'
	end,
	Tooltip = 'Minimum length of one dodge, a shot will always be dodged for at least this long.'
})
Cooldown = BulletDodger:CreateSlider({
	Name = 'Cooldown',
	Min = 0,
	Max = 2,
	Default = 0,
	Decimal = 10,
	Darker = true,
	Suffix = function(val)
		return val == 1 and 'second' or 'seconds'
	end,
	Tooltip = 'Delay before a new dodge may start, useful to keep it from looking like a seizure.'
})
SafePath = BulletDodger:CreateToggle({
	Name = 'Safe Path',
	Default = true,
	Tooltip = 'Pick the side that is not blocked so we do not strafe into a wall.'
})
GroundCheck = BulletDodger:CreateToggle({
	Name = 'Ground Check',
	Default = false,
	Darker = true,
	Tooltip = 'Refuse to dodge off a ledge, this can get you killed more often than it saves you.'
})
JumpChance = BulletDodger:CreateSlider({
	Name = 'Jump Chance',
	Min = 1,
	Max = 100,
	Default = 50,
	Suffix = '%',
	Visible = false,
	Darker = true
})
JumpDelay = BulletDodger:CreateSlider({
	Name = 'Jump Delay',
	Min = 0.1,
	Max = 2,
	Default = 0.5,
	Decimal = 10,
	Visible = false,
	Darker = true,
	Suffix = function(val)
		return val == 1 and 'second' or 'seconds'
	end
})
TeamCheck = BulletDodger:CreateToggle({
	Name = 'Team Check',
	Default = true,
	Darker = true,
	Tooltip = 'Only dodge the enemy team, hostile players on your own team still count.'
})
Weapons = BulletDodger:CreateTextList({
	Name = 'Weapons',
	Placeholder = 'weapon name',
	Tooltip = 'Only react to these tools, leave it empty to react to every tool.'
})
ShowLines = BulletDodger:CreateToggle({
	Name = 'Show Lines',
	Default = false,
	Darker = true,
	Tooltip = 'Draw every detected shot, red means it was coming for you.'
})
Notify = BulletDodger:CreateToggle({
	Name = 'Notify',
	Default = false,
	Darker = true
})
DebugLog = BulletDodger:CreateToggle({
	Name = 'Debug',
	Default = false,
	Darker = true,
	Function = function(callback)
		if callback then
			task.defer(printStatus)
		end
	end,
	Tooltip = 'Print every detection with its source to the developer console (F9).\nTurning it on dumps a status block straight away.'
})
