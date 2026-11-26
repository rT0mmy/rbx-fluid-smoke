--!strict
--!native

--[[
Smoke that drifts like a fluid: each puff is one particle on a pooled, code-moved part, carried by
curl noise and wind, dragged along in the wake of moving bodies and pushed out of them.

	Smoke.UseConfig(mySettings) -- optional; Smoke.Config otherwise

	RunService.RenderStepped:Connect(function(deltaTime)
		Smoke.Step(deltaTime, { { Model = car, Root = car.PrimaryPart } })
	end)

	local tyre = Smoke.Source(template, { Spacing = 1.5 })
	tyre:Update(deltaTime, contactPosition, velocity, groundHeight, 0.8)
]]

local RunService = game:GetService('RunService')

local Defaults = require(`@self/Config`)

export type Config = Defaults.Config
export type Look = Defaults.Look

export type Body = {
	Model: Model, -- its bounding box is what pushes smoke aside, and it identifies the body between frames
	Root: BasePart, -- moves with the model; its velocity drives the wake
}

export type SourceOptions = {
	Rate: number?, -- puffs per second while it is updated; 0 by default
	Spacing: number?, -- a puff every this many studs it travels, laid out along the way it came; 0 turns it off
	Spread: number?, -- studs each puff lands from the point, across the ground; 0 by default
}

type Pool = {
	Template: ParticleEmitter,
	Version: number, -- the look Size, SizeTimes, SizeValues and Faded were built for
	Size: NumberSequence,
	SizeTimes: { number }, -- Size's keypoints as plain numbers, so a puff's size is read without touching the engine
	SizeValues: { number },
	Free: { Puff },
	InUse: number, -- its puffs in the air
	Faded: { [number]: NumberSequence }, -- [opacity step] = the look's Transparency at that opacity
}

--// A part with its emitter, and the puff it carries while in the air. Reused, so releasing a puff allocates nothing.
type Puff = {
	Part: BasePart,
	Emitter: ParticleEmitter,
	Version: number, -- the look its emitter is dressed in
	Strength: number, -- the opacity step it was released at
	Opacity: number, -- the step its emitter's Transparency is set to; below Strength while close to the camera
	Pool: Pool,
	Position: vector,
	Velocity: vector,
	Age: number,
	Life: number,
	Floor: number, -- height of the ground under it, easing toward Ground
	Ground: number, -- height of the ground last found under it
	NextCast: number, -- the age it looks for the ground again at
	Swirl: vector?, -- the curl last sampled for it; nil until its first step
	Phase: number, -- which frames it resamples the curl on
}

type Mover = {
	Root: BasePart,
	Frame: number, -- the last frame its body was passed to Step
	Offset: CFrame, -- bounding box in Root's space
	Half: vector,
	HalfWidth: number,
	HalfLength: number,
	Position: vector, -- of the bounding box
	XAxis: vector, -- the bounding box's axes, for measuring a point in its space with dot products
	YAxis: vector,
	ZAxis: vector,
	ReachSquared: number, -- puffs further than this from Position are neither pushed nor in its wake
	Velocity: vector,
	Speed: number,
	Heading: vector,
	Wakes: boolean, -- fast enough to drag a wake
	Width: number, -- the wake's half-width
	Churn: number, -- extra Swirl multiplier right behind it
}

type SourceState = {
	Template: ParticleEmitter,
	Rate: number,
	Spacing: number,
	Spread: number,
	Owed: number, -- puffs due but not yet released, as a fraction of one
	Last: vector?, -- where it was at its last update
}

--// The math works in the vector library's own type, whose calls compile to builtins. A Vector3 is the same value
--// at run time, but the type checker keeps the two apart, so it is cast at the edges with `:: any`.
local ZERO = vector.zero
local UP = vector.create(0, 1, 0)

local random = Random.new()

--// Opacity is applied in steps this coarse
const OPACITY_STEPS = 16

--// Each puff samples the curl every this many frames. Its velocity eases toward the air over about
--// 1 / Drag seconds, so a swirl a frame old does not show, and it halves the noise calls.
const SWIRL_EVERY = 2

--// ...and every this many beyond Config.FarDistance of the camera, where a stale swirl shows even less
const SWIRL_FAR = 4

--// Ground is looked for from this many studs above a puff, so it is found even after the puff has drifted onto
--// a rising slope
const GROUND_LIFT = 4

--// Per second; how fast a puff's floor eases to the ground found under it, so a step does not jerk it upward
const GROUND_EASE = 6

--// A source that moves further than this between updates has been moved, not driven, and leaves no trail
const SOURCE_JUMP = 100

--// The most puffs one source update releases
const SOURCE_BURST = 16

local onClient = RunService:IsClient()
local warnedServer = false

--// The settings in use; Smoke.UseConfig swaps in a game's own table
local Config: Config = Defaults

--// [template] = its pool
local pools: { [ParticleEmitter]: Pool } = {}
local puffs: { Puff } = {}
local slotsMade = 0
local released = 0
local dropped = 0
local frame = 0
local clock = 0 -- seconds of Step, so the eddies drift with the smoke and not the wall clock
local folder: Folder? = nil

--// Bumped by Restyle
local version = 1

--// [model] = its mover; dropped once its body is left out of a Step
local movers: { [Model]: Mover } = {}
local nearby: { Mover } = {}

--// Leaves out the bodies' models, when Config.GroundParams is nil; refilled when the bodies change
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.IgnoreWater = true
local bodiesChanged = false

--// Box around every puff's position at the start of the next Step, so bodies far from all smoke are skipped whole
local boundsMin = vector.create(math.huge, math.huge, math.huge)
local boundsMax = -boundsMin

local moved: { BasePart } = {}
local targets: { CFrame } = {}

--[[
	A piecewise-linear curve's value at t

	@param times {number} -- ascending, from 0 to 1
	@param values {number}
	@param t number -- 0..1
	@return number
--]]
local function sample(times: { number }, values: { number }, t: number): number
	--// Two keypoints, at 0 and 1: a plain lerp, which is the default look
	if #times == 2 then return values[1] + (values[2] - values[1]) * t end

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
		pool = {
			Template = template,
			Version = 0,
			Size = NumberSequence.new(0),
			SizeTimes = {},
			SizeValues = {},
			Free = {},
			InUse = 0,
			Faded = {},
		}
		pools[template] = pool
	end

	if pool.Version ~= version then
		local look = Config.Look

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
	A clone of a template, stripped of its own motion, on a puff's part

	@param template ParticleEmitter
	@param part BasePart
	@return ParticleEmitter
--]]
local function emitterFor(template: ParticleEmitter, part: BasePart): ParticleEmitter
	local emitter = template:Clone()
	emitter.Enabled = false
	emitter.LockedToPart = true
	emitter.Speed = NumberRange.new(0)
	emitter.SpreadAngle = Vector2.zero
	emitter.Acceleration = Vector3.zero
	emitter.Drag = 0
	emitter.VelocityInheritance = 0
	emitter.WindAffectsDrag = false
	emitter.Parent = part

	return emitter
end

--[[
	Hands a puff's part back to its pool. It is not taken out of `puffs`.

	@param puff Puff
	@return nil
--]]
local function free(puff: Puff)
	local pool = puff.Pool
	pool.InUse -= 1
	table.insert(pool.Free, puff)
end

--[[
	A free part carrying the pool's emitter, or nil once MaxPuffs parts exist and none is free

	@param pool Pool
	@return Puff?
--]]
local function slotFor(pool: Pool): Puff?
	local slot = table.remove(pool.Free)
	if slot then return slot end

	if slotsMade >= Config.MaxPuffs then
		--// Every part is made: take a free one from another template, so parts made for a template that is gone
		--// are not stranded. Pools left holding nothing are forgotten, which lets their templates be collected.
		for template, other in pools do
			local taken = table.remove(other.Free)

			if taken then
				taken.Emitter:Destroy()
				taken.Emitter = emitterFor(pool.Template, taken.Part)
				taken.Pool = pool
				taken.Version = 0
				taken.Opacity = -1

				return taken
			end

			if other ~= pool and other.InUse == 0 then pools[template] = nil end
		end

		return nil
	end

	slotsMade += 1

	if not folder then
		local made = Instance.new('Folder')
		made.Name = Config.FolderName
		made.Parent = workspace
		folder = made
	end

	local part: BasePart = Instance.new('Part')
	part.Name = '_SmokePuff'
	part.Size = Vector3.one * 0.2
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Parent = folder

	return {
		Part = part,
		Emitter = emitterFor(pool.Template, part),
		Version = 0,
		Strength = 0,
		Opacity = -1,
		Pool = pool,
		Position = ZERO,
		Velocity = ZERO,
		Age = 0,
		Life = 0,
		Floor = 0,
		Ground = 0,
		NextCast = 0,
		Swirl = nil,
		Phase = 0,
	}
end

--[[
	Frees the part of the puff in the air nearest the end of its life, for StealOldest

	@return boolean -- whether there was one
--]]
local function stealOldest(): boolean
	local oldest, most = 0, -1

	for index, puff in puffs do
		local t = puff.Age / puff.Life

		if t > most then
			oldest, most = index, t
		end
	end

	if oldest == 0 then return false end

	local puff = puffs[oldest]
	puff.Emitter:Clear()
	free(puff)

	puffs[oldest] = puffs[#puffs]
	puffs[#puffs] = nil

	return true
end

--[[
	Puts a slot's emitter in the current look, if it is not already

	@param slot Puff
	@param pool Pool
	@return nil
--]]
local function dress(slot: Puff, pool: Pool)
	if slot.Version == version then return end

	local look = Config.Look
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
	@param step number -- 0..OPACITY_STEPS
	@return NumberSequence
--]]
local function fadedFor(pool: Pool, step: number): NumberSequence
	local cached = pool.Faded[step]
	if cached then return cached end

	local look = Config.Look
	local scale = step / OPACITY_STEPS
	local faded: NumberSequence

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

	@param position vector
	@param time number
	@return vector
--]]
local function curl(position: vector, time: number): vector
	local scale = Config.NoiseScale
	local x, y, z = position.x * scale + time, position.y * scale - time, position.z * scale
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
	The ground's height beneath a point, if it is within GroundReach

	@param position vector
	@return number?
--]]
local function groundUnder(position: vector): number?
	local hit = workspace:Raycast(
		(position + UP * GROUND_LIFT) :: any,
		(UP * -(Config.GroundReach + GROUND_LIFT)) :: any,
		Config.GroundParams or groundParams
	)

	return if hit then hit.Position.Y else nil
end

--[[
	A body's box and motion this frame, measured once per model, and again if its Root changes

	@param body Body
	@param settings Config
	@return Mover
--]]
local function moverOf(body: Body, settings: Config): Mover
	local model = body.Model
	local found = movers[model]
	local mover: Mover

	if found and found.Root == body.Root then
		mover = found
	else
		local box, size = model:GetBoundingBox()
		local half: vector = (size / 2) :: any

		mover = {
			Root = body.Root,
			Frame = 0,
			Offset = body.Root.CFrame:ToObjectSpace(box),
			Half = half,
			HalfWidth = math.min(half.x, half.z),
			HalfLength = math.max(half.x, half.z),
			Position = ZERO,
			XAxis = ZERO,
			YAxis = ZERO,
			ZAxis = ZERO,
			ReachSquared = 0,
			Velocity = ZERO,
			Speed = 0,
			Heading = ZERO,
			Wakes = false,
			Width = 0,
			Churn = 0,
		}

		movers[model] = mover
		bodiesChanged = true
	end

	local box = mover.Root.CFrame * mover.Offset
	mover.Frame = frame
	mover.Position = box.Position :: any
	mover.XAxis = box.XVector :: any
	mover.YAxis = box.YVector :: any
	mover.ZAxis = box.ZVector :: any
	mover.ReachSquared = (mover.HalfLength + settings.WakeLength) ^ 2

	local velocity: vector = mover.Root.AssemblyLinearVelocity :: any
	local flat = vector.create(velocity.x, 0, velocity.z)
	local speed = vector.magnitude(flat)

	mover.Velocity = velocity
	mover.Speed = speed
	mover.Heading = if speed > 1e-3 then flat / speed else ZERO
	mover.Wakes = speed >= settings.WakeMinSpeed
	mover.Width = mover.HalfWidth * settings.WakeWidth
	mover.Churn = settings.WakeChurn * math.min(speed / settings.WakeChurnSpeed, 1)

	return mover
end

local Smoke = {}

--[[
	Releases one puff from a template, at a point on the ground

	@param template ParticleEmitter -- shapes the puff, with Config.Look over it
	@param position Vector3
	@param velocity Vector3
	@param floor number? -- height of the ground it came off; when nil, found beneath it with GroundCast on, or
	                     -- its own height otherwise
	@param opacity number? -- 0..1 of the look's opacity; 1 when nil, and nothing is released at 0
	@return boolean -- whether it was released; false at opacity 0, on the server, or with every part in the air
--]]
function Smoke.Emit(
	template: ParticleEmitter,
	position: Vector3,
	velocity: Vector3,
	floor: number?,
	opacity: number?
): boolean
	--// Parts made on the server would replicate to every client
	if not onClient then
		if not warnedServer then
			warnedServer = true
			warn('Smoke.Emit only runs on the client; nothing is released on the server')
		end

		return false
	end

	local step = math.clamp(math.ceil((opacity or 1) * OPACITY_STEPS), 0, OPACITY_STEPS)
	if step == 0 then return false end

	local pool = poolFor(template)
	local puff = slotFor(pool)

	if not puff and Config.StealOldest and stealOldest() then puff = slotFor(pool) end

	if not puff then
		dropped += 1
		return false
	end

	dress(puff, pool)

	if step ~= puff.Opacity then
		puff.Emitter.Transparency = fadedFor(pool, step)
		puff.Opacity = step
	end

	local lifetime = Config.Look.Lifetime or template.Lifetime
	local life = random:NextNumber(lifetime.Min, lifetime.Max)

	--// The particle has to die exactly when the puff frees its part, or it would be dragged into the next puff's spot
	puff.Emitter.Lifetime = NumberRange.new(life)
	puff.Part.CFrame = CFrame.new(position)
	puff.Emitter:Emit(1)

	released += 1

	local at: vector = position :: any
	local ground = floor
	if ground == nil then ground = if Config.GroundCast then groundUnder(at) else nil end

	puff.Position = at
	puff.Velocity = velocity :: any
	puff.Age = 0
	puff.Life = life
	puff.Floor = ground or at.y
	puff.Ground = puff.Floor
	puff.NextCast = random:NextNumber(0, Config.GroundEvery) -- spread out, so casts do not land on the same frame
	puff.Strength = step
	puff.Swirl = nil
	puff.Phase = released % SWIRL_FAR

	pool.InUse += 1
	boundsMin = vector.min(boundsMin, at)
	boundsMax = vector.max(boundsMax, at)

	table.insert(puffs, puff)

	return true
end

--[[
	Moves every puff through the air one frame

	@param deltaTime number
	@param bodies {[any]: Body}? -- everything that stirs the air: pushes smoke out of its box and drags a wake
	@return nil
--]]
function Smoke.Step(deltaTime: number, bodies: { [any]: Body }?)
	if #puffs == 0 then return end

	Config.Profiler.Begin('Smoke')

	local settings = Config

	--// Puffs age in full so each frees its part when its particle dies, but a hitch moves them no further than
	--// MaxStep, so they cannot leap through a body
	local moveTime = math.min(deltaTime, settings.MaxStep)

	clock += deltaTime
	frame += 1

	local time = clock * settings.NoiseDrift
	local follow = 1 - math.exp(-settings.Drag * moveTime)
	local margin = settings.PushMargin
	local rise = settings.Rise
	local swirlGain = settings.Swirl
	local pushSpeed = settings.PushSpeed
	local pushCarry = settings.PushCarry
	local wakeLength = settings.WakeLength
	local wakeCarry = settings.WakeCarry
	local wakeConverge = settings.WakeConverge
	local floorHold = settings.FloorHold
	local nearFade = settings.NearFade
	local nearHide = settings.NearHide

	local casting = settings.GroundCast
	local groundEvery = settings.GroundEvery
	local groundFollow = 1 - math.exp(-GROUND_EASE * moveTime)

	--// math.noise is about -0.5..0.5, so the wind swells and slackens by up to Gust of itself
	local gust = 1 + settings.Gust * 2 * math.noise(clock * 0.2, 7.31)
	local wind: vector = ((settings.Wind + workspace.GlobalWind * settings.GlobalWind) * gust) :: any

	local camera = workspace.CurrentCamera
	local view = if camera then camera.CFrame else CFrame.identity
	local eye: vector = view.Position :: any
	local look: vector = view.LookVector :: any
	local farSquared = if camera then settings.FarDistance ^ 2 else math.huge
	local fading = camera ~= nil and nearFade > nearHide

	table.clear(nearby)

	if bodies then
		for _, body in bodies do
			local mover = moverOf(body, settings)

			--// Skipped whole when no puff is within its reach
			local offset = mover.Position - vector.clamp(mover.Position, boundsMin, boundsMax)
			if vector.dot(offset, offset) <= mover.ReachSquared then table.insert(nearby, mover) end
		end
	end

	for model, mover in movers do
		if mover.Frame ~= frame then
			movers[model] = nil
			bodiesChanged = true
		end
	end

	if bodiesChanged and casting and not settings.GroundParams then
		local models: { Instance } = {}

		for model in movers do
			table.insert(models, model)
		end

		groundParams.FilterDescendantsInstances = models
		bodiesChanged = false
	end

	table.clear(moved)
	table.clear(targets)

	local count = 0
	local index = 1
	local lowest = vector.create(math.huge, math.huge, math.huge)
	local highest = -lowest

	while index <= #puffs do
		local puff = puffs[index]
		puff.Age += deltaTime

		if puff.Age >= puff.Life then
			free(puff)
			puffs[index] = puffs[#puffs]
			puffs[#puffs] = nil
			continue
		end

		local t = puff.Age / puff.Life
		local position = puff.Position
		local churn = 1
		local air = wind + vector.create(0, rise * (1 - t), 0)

		for _, mover in nearby do
			local offset = position - mover.Position

			if vector.dot(offset, offset) > mover.ReachSquared then continue end

			local xAxis, yAxis, zAxis = mover.XAxis, mover.YAxis, mover.ZAxis
			local spotX = vector.dot(offset, xAxis)
			local spotY = vector.dot(offset, yAxis)
			local spotZ = vector.dot(offset, zAxis)
			local half = mover.Half
			local overX = half.x + margin - math.abs(spotX)
			local overY = half.y + margin - math.abs(spotY)
			local overZ = half.z + margin - math.abs(spotZ)

			if overX > 0 and overY > 0 and overZ > 0 then
				local out = if overX <= overY and overX <= overZ
					then xAxis * math.sign(spotX)
					elseif overY <= overZ then yAxis * math.sign(spotY)
					else zAxis * math.sign(spotZ)

				air += out * (pushSpeed + mover.Speed * pushCarry)
			end

			if not mover.Wakes then continue end

			--// Measured from the rear along the way the body is moving, not the way it faces, so a drift's wake trails its slide
			local heading = mover.Heading
			local halfLength = mover.HalfLength
			local along = vector.dot(offset, heading)
			local behind = -along - halfLength
			if behind < -2 * halfLength or behind > wakeLength then continue end

			local side = offset - heading * along
			side = vector.create(side.x, 0, side.z)

			local width = mover.Width
			local across = vector.magnitude(side)
			if across >= width then continue end

			local strength = (1 - math.max(behind, 0) / wakeLength) * (1 - across / width)

			air += mover.Velocity * (wakeCarry * strength) - side * (wakeConverge * strength)
			churn += mover.Churn * strength
		end

		local swirl = puff.Swirl
		local fromEye = position - eye
		local every = if vector.dot(fromEye, fromEye) > farSquared then SWIRL_FAR else SWIRL_EVERY

		if not swirl or (frame + puff.Phase) % every == 0 then
			swirl = curl(position, time)
			puff.Swirl = swirl
		end

		air += (swirl :: vector) * (swirlGain * churn)

		local velocity = puff.Velocity + (air - puff.Velocity) * follow
		position += velocity * moveTime

		if casting then
			if puff.Age >= puff.NextCast then
				puff.NextCast = puff.Age + groundEvery
				puff.Ground = groundUnder(position) or puff.Ground
			end

			puff.Floor += (puff.Ground - puff.Floor) * groundFollow
		end

		local pool = puff.Pool
		local radius = sample(pool.SizeTimes, pool.SizeValues, t) / 2
		local floor = puff.Floor + radius * floorHold

		if position.y < floor then
			position = vector.create(position.x, floor, position.z)
			if velocity.y < 0 then velocity = vector.create(velocity.x, 0, velocity.z) end
		end

		puff.Position = position
		puff.Velocity = velocity

		--// Fades out as its centre nears the camera's plane, where the engine would drop it all at once. Puffs
		--// released before a Restyle are left alone, as their pool's fades are for the new look.
		if fading and puff.Version == version and pool.Version == version then
			local depth = vector.dot(position - eye, look) / radius
			local fade = math.clamp((depth - nearHide) / (nearFade - nearHide), 0, 1)
			local step = math.ceil(puff.Strength * fade)

			if step ~= puff.Opacity then
				puff.Emitter.Transparency = fadedFor(pool, step)
				puff.Opacity = step
			end
		end

		lowest = vector.min(lowest, position)
		highest = vector.max(highest, position)

		count += 1
		moved[count] = puff.Part
		targets[count] = CFrame.new(position :: any)

		index += 1
	end

	boundsMin = lowest
	boundsMax = highest

	workspace:BulkMoveTo(moved, targets, Enum.BulkMoveMode.FireCFrameChanged)

	Config.Profiler.End()
end

--[[
	Throws smoke out from a point, as a blast would. Puffs within radius are given up to strength studs per second
	away from it, less the further out they are, and settle back into the air at Drag.

	@param position Vector3
	@param radius number -- studs
	@param strength number -- studs per second, at the centre
	@return nil
--]]
function Smoke.Impulse(position: Vector3, radius: number, strength: number)
	local centre: vector = position :: any

	for _, puff in puffs do
		local offset = puff.Position - centre
		local distance = vector.magnitude(offset)
		if distance >= radius then continue end

		local out: vector = if distance > 1e-3 then offset / distance else random:NextUnitVector() :: any
		puff.Velocity += out * (strength * (1 - distance / radius))
	end
end

--[[
	Picks up changes to Config.Look; puffs already in the air keep the look they left with

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
		free(puff)
	end

	table.clear(puffs)
end

--[[
	@return number -- puffs in the air
	@return number -- parts made for them so far, against Config.MaxPuffs
	@return number -- puffs not released so far because every part was in the air
--]]
function Smoke.Stats(): (number, number, number)
	return #puffs, slotsMade, dropped
end

--// A point smoke comes from steadily, like a tyre: Update it every frame and it releases puffs by time and by
--// distance travelled, evenly spaced whatever the frame rate
local Source = {}
Source.__index = Source

export type Source = typeof(setmetatable({} :: SourceState, Source))

--[[
	@param template ParticleEmitter -- shapes its puffs, as in Emit
	@param options SourceOptions?
	@return Source
--]]
function Smoke.Source(template: ParticleEmitter, options: SourceOptions?): Source
	local settings: SourceOptions = options or {}

	local state: SourceState = {
		Template = template,
		Rate = settings.Rate or 0,
		Spacing = settings.Spacing or 0,
		Spread = settings.Spread or 0,
		Owed = 0,
		Last = nil,
	}

	return setmetatable(state, Source)
end

--[[
	Releases the puffs due since the last update, laid out from where it was then to where it is now

	@param deltaTime number
	@param position Vector3
	@param velocity Vector3
	@param floor number? -- as in Emit
	@param opacity number? -- as in Emit
	@return number -- puffs released
--]]
function Source.Update(
	self: Source,
	deltaTime: number,
	position: Vector3,
	velocity: Vector3,
	floor: number?,
	opacity: number?
): number
	local here: vector = position :: any
	local last = self.Last or here
	local travelled = vector.magnitude(here - last)

	if travelled > SOURCE_JUMP then
		last = here
		travelled = 0
	end

	self.Last = here

	local owed = self.Owed + self.Rate * deltaTime
	if self.Spacing > 0 then
		owed += travelled / self.Spacing
	end

	local due = math.floor(owed)
	self.Owed = owed - due

	local count = math.min(due, SOURCE_BURST)
	local spread = self.Spread
	local made = 0

	for i = 1, count do
		local at = last + (here - last) * (i / count)

		if spread > 0 then
			at += vector.create(random:NextNumber(-spread, spread), 0, random:NextNumber(-spread, spread))
		end

		if Smoke.Emit(self.Template, at :: any, velocity, floor, opacity) then
			made += 1
		end
	end

	return made
end

--[[
	Releases puffs at once around a point, as Update would spread them

	@param count number
	@param position Vector3
	@param velocity Vector3
	@param floor number? -- as in Emit
	@param opacity number? -- as in Emit
	@return number -- puffs released
--]]
function Source.Burst(
	self: Source,
	count: number,
	position: Vector3,
	velocity: Vector3,
	floor: number?,
	opacity: number?
): number
	local spread = self.Spread
	local made = 0

	for _ = 1, count do
		local at: vector = position :: any

		if spread > 0 then
			at += vector.create(random:NextNumber(-spread, spread), 0, random:NextNumber(-spread, spread))
		end

		if Smoke.Emit(self.Template, at :: any, velocity, floor, opacity) then
			made += 1
		end
	end

	return made
end

--[[
	Forgets where it was, so the next update leaves no trail from there; for when it stops touching the ground

	@return nil
--]]
function Source.Reset(self: Source)
	self.Last = nil
	self.Owed = 0
end

--[[
	Copies every key `target` lacks from `source`, tables included

	@param target {[any]: any}
	@param source {[any]: any}
	@return {[any]: any} -- target
--]]
local function fill(target: { [any]: any }, source: { [any]: any }): { [any]: any }
	for key, value in source do
		local own = target[key]

		if own == nil then
			target[key] = if type(value) == 'table' then fill({}, value) else value
		elseif type(own) == 'table' and type(value) == 'table' then
			fill(own, value)
		end
	end

	return target
end

--[[
	Reads settings from the game's own table from now on, so the game can tune and edit them live.
	Keys it lacks are filled in from the defaults, and keys Smoke does not know are left alone.

	@param settings {[string]: any}
	@return Config -- the same table, filled in
--]]
function Smoke.UseConfig(settings: { [string]: any }): Config
	Config = fill(settings, Defaults :: any) :: any
	Smoke.Config = Config

	Smoke.Restyle()

	return Config
end

--// The settings in use, read live
Smoke.Config = Config

return Smoke
