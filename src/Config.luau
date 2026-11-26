--!strict

--// The settings Smoke starts with. Smoke.UseConfig hands it a game's own table instead, and any
--// key that table lacks is filled in from here.

--// With UseTemplate a puff takes the template's Size and Transparency; otherwise it grows from
--// SizeStart to SizeEnd and fades in to its most opaque at PeakAt of its life, then out. Emit's
--// opacity scales either.
export type Look = {
	UseTemplate: boolean,
	SizeStart: number,
	SizeEnd: number,
	PeakAt: number,
	Opacity: number,

	--// Set to replace the template's; nil keeps it
	Lifetime: NumberRange?,
	Color: Color3?,
	LightEmission: number?,
	LightInfluence: number?,
	Texture: string?,
}

export type Profiler = {
	Begin: (label: string) -> (),
	End: () -> (),
}

export type Config = {
	MaxPuffs: number,
	StealOldest: boolean,
	MaxStep: number,
	FarDistance: number,
	NearFade: number,
	NearHide: number,
	Drag: number,
	Rise: number,
	FloorHold: number,
	NoiseScale: number,
	NoiseDrift: number,
	Swirl: number,
	Wind: Vector3,
	GlobalWind: number,
	Gust: number,
	GroundCast: boolean,
	GroundEvery: number,
	GroundReach: number,
	GroundParams: RaycastParams?,
	WakeMinSpeed: number,
	WakeLength: number,
	WakeWidth: number,
	WakeCarry: number,
	WakeConverge: number,
	WakeChurn: number,
	WakeChurnSpeed: number,
	PushMargin: number,
	PushSpeed: number,
	PushCarry: number,
	Look: Look,
	FolderName: string,
	Profiler: Profiler,
}

local Config: Config = {
	MaxPuffs = 128, -- across every source
	StealOldest = false, -- once every part is in the air, a new puff takes the part of the one nearest its end

	--// Step
	MaxStep = 1 / 15, -- seconds; a longer frame moves puffs only this far, so a hitch cannot carry them through a body
	FarDistance = 200, -- studs from the camera beyond which puffs resample the curl half as often

	--// Close to the camera, of a puff's radius, measured along the way the camera looks: it starts fading at
	--// NearFade and is gone by NearHide, rather than vanishing all at once as its centre passes the camera.
	--// NearFade 0 turns it off.
	NearFade = 1,
	NearHide = 0.2,

	--// Drift
	Drag = 2.5, -- per second; how fast a puff gives up its own speed to the air around it
	Rise = 2, -- for a fresh puff, easing to 0 by the end of its life
	FloorHold = 0.35, -- of its radius a puff's centre stays above the ground it left
	NoiseScale = 0.08, -- per stud; smaller makes larger eddies
	NoiseDrift = 0.4, -- how fast the eddies change
	Swirl = 3,

	--// Wind: the air's own drift, in studs per second
	Wind = Vector3.zero,
	GlobalWind = 0, -- of workspace.GlobalWind added to Wind
	Gust = 0, -- 0..1; how far the wind swells and slackens over time

	--// Ground: off, a puff keeps the floor it left. On, each puff looks for the ground beneath it every GroundEvery
	--// seconds, up to GroundReach studs down, and eases its floor to it, so smoke follows slopes and ramps.
	--// GroundParams nil leaves out the bodies passed to Step, so smoke does not settle on their roofs.
	GroundCast = false,
	GroundEvery = 0.25,
	GroundReach = 30,
	GroundParams = nil,

	--// Wake: air behind a moving body is dragged after it and churned
	WakeMinSpeed = 4,
	WakeLength = 30, -- studs behind the body
	WakeWidth = 1.6, -- of the body's half-width
	WakeCarry = 1.25, -- of the body's velocity, right behind it
	WakeConverge = 1.5, -- per second, pulling smoke in toward the body's track
	WakeChurn = 2.5, -- extra Swirl multiplier right behind a body at WakeChurnSpeed
	WakeChurnSpeed = 60,

	--// Smoke inside a body's bounding box, grown by PushMargin studs, is pushed out at PushSpeed plus
	--// PushCarry of the body's speed
	PushMargin = 1,
	PushSpeed = 6,
	PushCarry = 1.2,

	Look = {
		UseTemplate = false,
		SizeStart = 2,
		SizeEnd = 25,
		PeakAt = 0.1,
		Opacity = 0.2, -- at its peak, at Emit opacity 1

		Lifetime = nil,
		Color = nil,
		LightEmission = nil,
		LightInfluence = nil,
		Texture = nil,
	},

	--// Folder in workspace the puff parts live in
	FolderName = '_Smoke',

	--// Brackets each frame's work; a game can hand in its own pair
	Profiler = {
		Begin = debug.profilebegin,
		End = debug.profileend,
	},
}

return Config
