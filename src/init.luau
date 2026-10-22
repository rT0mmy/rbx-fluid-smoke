--!nonstrict
--!native

local Config = require(`./Config`)
local Profiler = require(`@game/ReplicatedStorage/Modules/Shared/Profiler`)

local Smoke = {}

type Pool = {
	Template: ParticleEmitter,
	Version: number, -- the look Size, SizeTimes, SizeValues and Faded were built for
	Size: NumberSequence,
	SizeTimes: { number }, -- Size's keypoints as plain numbers, so a puff's size is read without touching the engine
	SizeValues: { number },
	Free: { Puff },
	Faded: { [number]: NumberSequence }, -- [opacity step] = the look's Transparency at that opacity
}

--// A part with its emitter, and the puff it carries while in the air. Reused, so releasing a puff allocates nothing.
type Puff = {
	Part: BasePart,
	Emitter: ParticleEmitter,
	Version: number, -- the look its emitter is dressed in
	Opacity: number, -- the step its emitter's Transparency is set to
	Pool: Pool,
	Position: Vector3,
	Velocity: Vector3,
	Age: number,
	Life: number,
	Floor: number,
	Swirl: Vector3?, -- the curl last sampled for it; nil until its first step
	Phase: number, -- which frames it resamples the curl on
}

type Car = {
	Seat: BasePart,
	Offset: CFrame, -- bounding box in the seat's space
	Half: Vector3,
	HalfWidth: number,
	HalfLength: number,
	Position: Vector3, -- of the bounding box
	XAxis: Vector3, -- the bounding box's axes, for measuring a point in its space with dot products
	YAxis: Vector3,
	ZAxis: Vector3,
	ReachSquared: number, -- puffs further than this from Position are neither pushed nor in its wake
	Velocity: Vector3,
	Speed: number,
	Heading: Vector3,
}

local random = Random.new()

--// Opacity is applied in steps this coarse
const OPACITY_STEPS = 16

--// Each puff samples the curl every this many frames. Its velocity eases toward the air over about
--// 1 / Drag seconds, so a swirl a frame old does not show, and it halves the noise calls.
const SWIRL_EVERY = 2

--// [template] = its pool
local pools: { [ParticleEmitter]: Pool } = {}
local puffs: { Puff } = {}
local slotsMade = 0
local released = 0
local frame = 0
local folder: Folder? = nil

--// Bumped by Restyle
local version = 1

local cars: { [any]: Car } = setmetatable({}, { __mode = 'k' })
local nearby: { Car } = {}

local moved: { BasePart } = {}
local targets: { CFrame } = {}

--[[
	A piecewise-linear curve's value at t

	@param times {number} -- ascending
	@param values {number}
	@param t number -- 0..1
	@return number
--]]
local function sample(times: { number }, values: { number }, t: number): number
	for i = 2, #times do
		local b = times[i]

		if t <= b then
			local a = times[i - 1]
			local span = b - a

			return if span > 0 then values[i - 1] + (values[i] - values[i - 1]) * (t - a) / span else values[i]
		end
	end

	return values[#values]
end

--[[
	@param template ParticleEmitter
	@return Pool
--]]
local function poolFor(template: ParticleEmitter): Pool
	local pool = pools[template]

	if not pool then
		pool = { Template = template, Version = 0, SizeTimes = {}, SizeValues = {}, Free = {}, Faded = {} }
		pools[template] = pool
	end

	if pool.Version ~= version then
		local look = Config.Smoke.Look

		pool.Size = if look.UseTemplate then template.Size else NumberSequence.new(look.SizeStart, look.SizeEnd)

		table.clear(pool.SizeTimes)
		table.clear(pool.SizeValues)

		for i, key in pool.Size.Keypoints do
			pool.SizeTimes[i] = key.Time
			pool.SizeValues[i] = key.Value
		end

		pool.Version = version
		table.clear(pool.Faded)
	end

	return pool
end

--[[
	A free part carrying the pool's emitter, or nil once MaxPuffs parts exist and none is free

	@param pool Pool
	@return Puff?
--]]
local function slotFor(pool: Pool): Puff?
	local slot = table.remove(pool.Free)
	if slot then return slot end

	if slotsMade >= Config.Smoke.MaxPuffs then return nil end
	slotsMade += 1

	if not folder then
		folder = Instance.new('Folder')
		folder.Name = '_Smoke'
		folder.Parent = workspace
	end

	local part = Instance.new('Part')
	part.Name = '_SmokePuff'
	part.Size = Vector3.one * 0.2
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Parent = folder

	local emitter = pool.Template:Clone()
	emitter.Enabled = false
	emitter.LockedToPart = true
	emitter.Speed = NumberRange.new(0)
	emitter.SpreadAngle = Vector2.zero
	emitter.Acceleration = Vector3.zero
	emitter.Drag = 0
	emitter.VelocityInheritance = 0
	emitter.WindAffectsDrag = false
	emitter.Parent = part

	return {
		Part = part,
		Emitter = emitter,
		Version = 0,
		Opacity = -1,
		Pool = pool,
		Position = Vector3.zero,
		Velocity = Vector3.zero,
		Age = 0,
		Life = 0,
		Floor = 0,
		Swirl = nil,
		Phase = 0,
	}
end

--[[
	Puts a slot's emitter in the current look, if it is not already

	@param slot Puff
	@param pool Pool
	@return nil
--]]
local function dress(slot: Puff, pool: Pool)
	if slot.Version == version then return end

	local look = Config.Smoke.Look
	local template = pool.Template
	local emitter = slot.Emitter

	emitter.Size = pool.Size
	emitter.Color = if look.Color then ColorSequence.new(look.Color) else template.Color
	emitter.LightEmission = look.LightEmission or template.LightEmission
	emitter.LightInfluence = look.LightInfluence or template.LightInfluence
	emitter.Texture = look.Texture or template.Texture

	slot.Version = version
	slot.Opacity = -1
end

--[[
	The look's Transparency with every keypoint's opacity scaled by step / OPACITY_STEPS

	@param pool Pool
	@param step number
	@return NumberSequence
--]]
local function fadedFor(pool: Pool, step: number): NumberSequence
	local faded = pool.Faded[step]
	if faded then return faded end

	local look = Config.Smoke.Look
	local scale = step / OPACITY_STEPS

	if look.UseTemplate then
		local keys = {}

		for i, key in pool.Template.Transparency.Keypoints do
			keys[i] = NumberSequenceKeypoint.new(key.Time, 1 - (1 - key.Value) * scale, key.Envelope * scale)
		end

		faded = NumberSequence.new(keys)
	else
		faded = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(math.clamp(look.PeakAt, 0.001, 0.999), 1 - look.Opacity * scale),
			NumberSequenceKeypoint.new(1, 1),
		})
	end

	pool.Faded[step] = faded

	return faded
end

--[[
	The air's swirl at a point: the curl of a noise field, so it neither bunches smoke up nor thins
	it out. Forward differences, 9 noise samples.

	@param position Vector3
	@param time number
	@return Vector3
--]]
local function curl(position: Vector3, time: number): Vector3
	local scale = Config.Smoke.NoiseScale
	local x, y, z = position.X * scale + time, position.Y * scale - time, position.Z * scale
	local e = 0.1

	local a = math.noise(x, y, z)
	local b = math.noise(x + 31.4, y - 17.2, z + 11.9)
	local c = math.noise(x - 23.7, y + 41.3, z - 7.1)

	local aY = math.noise(x, y + e, z) - a
	local aZ = math.noise(x, y, z + e) - a
	local bX = math.noise(x + 31.4 + e, y - 17.2, z + 11.9) - b
	local bZ = math.noise(x + 31.4, y - 17.2, z + 11.9 + e) - b
	local cX = math.noise(x - 23.7 + e, y + 41.3, z - 7.1) - c
	local cY = math.noise(x - 23.7, y + 41.3 + e, z - 7.1) - c

	return vector.create(cY - bZ, aZ - cX, bX - aY) / e
end

--[[
	A car's body and motion this frame, measured once per car

	@param host Host
	@param wakeLength number -- studs
	@return Car
--]]
local function carOf(host, wakeLength: number): Car
	local car = cars[host]

	if not car then
		local box, size = host.Model:GetBoundingBox()
		local half = size / 2

		car = {
			Seat = host.Seat,
			Offset = host.Seat.CFrame:ToObjectSpace(box),
			Half = half,
			HalfWidth = math.min(half.X, half.Z),
			HalfLength = math.max(half.X, half.Z),
			Position = box.Position,
			XAxis = box.XVector,
			YAxis = box.YVector,
			ZAxis = box.ZVector,
			ReachSquared = 0,
			Velocity = Vector3.zero,
			Speed = 0,
			Heading = Vector3.zero,
		}

		cars[host] = car
	end

	local box = car.Seat.CFrame * car.Offset
	car.Position = box.Position
	car.XAxis = box.XVector
	car.YAxis = box.YVector
	car.ZAxis = box.ZVector
	car.ReachSquared = (car.HalfLength + wakeLength) ^ 2

	local velocity = car.Seat.AssemblyLinearVelocity
	local flat = vector.create(velocity.X, 0, velocity.Z)

	car.Velocity = velocity
	car.Speed = vector.magnitude(flat)
	car.Heading = if car.Speed > 1e-3 then flat / car.Speed else Vector3.zero

	return car
end

--[[
	Releases one puff from a template, at a point on the ground

	@param template ParticleEmitter -- shapes the puff, with Config.Smoke.Look over it
	@param position Vector3
	@param velocity Vector3
	@param floor number -- height of the ground it came off
	@param opacity number? -- 0..1 of the look's opacity; 1 when nil, and nothing is released at 0
	@return nil
--]]
function Smoke.Emit(template: ParticleEmitter, position: Vector3, velocity: Vector3, floor: number, opacity: number?)
	local step = math.clamp(math.ceil((opacity or 1) * OPACITY_STEPS), 0, OPACITY_STEPS)
	if step == 0 then return end

	local pool = poolFor(template)
	local puff = slotFor(pool)
	if not puff then return end

	dress(puff, pool)

	if step ~= puff.Opacity then
		puff.Emitter.Transparency = fadedFor(pool, step)
		puff.Opacity = step
	end

	local lifetime = Config.Smoke.Look.Lifetime or template.Lifetime
	local life = random:NextNumber(lifetime.Min, lifetime.Max)

	--// The particle has to die exactly when the puff frees its part, or it would be dragged into the next puff's spot
	puff.Emitter.Lifetime = NumberRange.new(life)
	puff.Part.CFrame = CFrame.new(position)
	puff.Emitter:Emit(1)

	released += 1

	puff.Position = position
	puff.Velocity = velocity
	puff.Age = 0
	puff.Life = life
	puff.Floor = floor
	puff.Swirl = nil
	puff.Phase = released % SWIRL_EVERY

	table.insert(puffs, puff)
end

--[[
	Moves every puff through the air one frame

	@param deltaTime number
	@param hosts {[Model]: Host} -- every car in effects range; each one stirs the air
	@return nil
--]]
function Smoke.Step(deltaTime: number, hosts)
	if #puffs == 0 then return end

	Profiler.Begin('Smoke')

	local settings = Config.Smoke
	local time = os.clock() * settings.NoiseDrift
	local follow = 1 - math.exp(-settings.Drag * deltaTime)
	local margin = settings.PushMargin

	frame += 1

	table.clear(nearby)

	for _, host in hosts do
		table.insert(nearby, carOf(host, settings.WakeLength))
	end

	table.clear(moved)
	table.clear(targets)

	local count = 0
	local index = 1

	while index <= #puffs do
		local puff = puffs[index]
		puff.Age += deltaTime

		if puff.Age >= puff.Life then
			table.insert(puff.Pool.Free, puff)
			puffs[index] = puffs[#puffs]
			puffs[#puffs] = nil
			continue
		end

		local t = puff.Age / puff.Life
		local position = puff.Position
		local churn = 1
		local air = vector.create(0, settings.Rise * (1 - t), 0)

		for _, car in nearby do
			local offset = position - car.Position

			if vector.dot(offset, offset) > car.ReachSquared then continue end

			local spotX = vector.dot(offset, car.XAxis)
			local spotY = vector.dot(offset, car.YAxis)
			local spotZ = vector.dot(offset, car.ZAxis)
			local half = car.Half
			local overX = half.X + margin - math.abs(spotX)
			local overY = half.Y + margin - math.abs(spotY)
			local overZ = half.Z + margin - math.abs(spotZ)

			if overX > 0 and overY > 0 and overZ > 0 then
				local out = if overX <= overY and overX <= overZ
					then car.XAxis * math.sign(spotX)
					elseif overY <= overZ then car.YAxis * math.sign(spotY)
					else car.ZAxis * math.sign(spotZ)

				air += out * (settings.PushSpeed + car.Speed * settings.PushCarry)
			end

			if car.Speed < settings.WakeMinSpeed then continue end

			--// Measured from the rear along the way the car is moving, not the way it faces, so a drift's wake trails its slide
			local along = vector.dot(offset, car.Heading)
			local behind = -along - car.HalfLength
			if behind < -2 * car.HalfLength or behind > settings.WakeLength then continue end

			local side = offset - car.Heading * along
			side = vector.create(side.X, 0, side.Z)

			local width = car.HalfWidth * settings.WakeWidth
			local across = vector.magnitude(side)
			if across >= width then continue end

			local strength = (1 - math.max(behind, 0) / settings.WakeLength) * (1 - across / width)

			air += car.Velocity * (settings.WakeCarry * strength) - side * (settings.WakeConverge * strength)
			churn += settings.WakeChurn * strength * math.min(car.Speed / settings.WakeChurnSpeed, 1)
		end

		local swirl = puff.Swirl

		if not swirl or (frame + puff.Phase) % SWIRL_EVERY == 0 then
			swirl = curl(position, time)
			puff.Swirl = swirl
		end

		air += swirl * (settings.Swirl * churn)

		local velocity = puff.Velocity + (air - puff.Velocity) * follow
		position += velocity * deltaTime

		local pool = puff.Pool
		local floor = puff.Floor + sample(pool.SizeTimes, pool.SizeValues, t) / 2 * settings.FloorHold

		if position.Y < floor then
			position = vector.create(position.X, floor, position.Z)
			if velocity.Y < 0 then velocity = vector.create(velocity.X, 0, velocity.Z) end
		end

		puff.Position = position
		puff.Velocity = velocity

		count += 1
		moved[count] = puff.Part
		targets[count] = CFrame.new(position)

		index += 1
	end

	workspace:BulkMoveTo(moved, targets, Enum.BulkMoveMode.FireCFrameChanged)

	Profiler.End()
end

--[[
	Picks up changes to Config.Smoke.Look; puffs already in the air keep the look they left with

	@return nil
--]]
function Smoke.Restyle()
	version += 1
end

--[[
	Removes every puff in the air

	@return nil
--]]
function Smoke.Clear()
	for _, puff in puffs do
		puff.Emitter:Clear()
		table.insert(puff.Pool.Free, puff)
	end

	table.clear(puffs)
end

--[[
	@return number -- puffs in the air
	@return number -- parts made for them so far, against Config.Smoke.MaxPuffs
--]]
function Smoke.Stats(): (number, number)
	return #puffs, slotsMade
end

return Smoke
