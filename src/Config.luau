--!nonstrict

--// The settings Smoke starts with. Smoke.UseConfig hands it a game's own table instead, and any
--// key that table lacks is filled in from here.

local Config = {}

Config.MaxPuffs = 128 -- across every source

--// Drift
Config.Drag = 2.5 -- per second; how fast a puff gives up its own speed to the air around it
Config.Rise = 2 -- for a fresh puff, easing to 0 by the end of its life
Config.FloorHold = 0.35 -- of its radius a puff's centre stays above the ground it left
Config.NoiseScale = 0.08 -- per stud; smaller makes larger eddies
Config.NoiseDrift = 0.4 -- how fast the eddies change
Config.Swirl = 3

--// Wake: air behind a moving body is dragged after it and churned
Config.WakeMinSpeed = 4
Config.WakeLength = 30 -- studs behind the body
Config.WakeWidth = 1.6 -- of the body's half-width
Config.WakeCarry = 1.25 -- of the body's velocity, right behind it
Config.WakeConverge = 1.5 -- per second, pulling smoke in toward the body's track
Config.WakeChurn = 2.5 -- extra Swirl multiplier right behind a body at WakeChurnSpeed
Config.WakeChurnSpeed = 60

--// Smoke inside a body's bounding box, grown by PushMargin studs, is pushed out at PushSpeed plus
--// PushCarry of the body's speed
Config.PushMargin = 1
Config.PushSpeed = 6
Config.PushCarry = 1.2

--// With UseTemplate a puff takes the template's Size and Transparency; otherwise it grows from
--// SizeStart to SizeEnd and fades in to its most opaque at PeakAt of its life, then out. Emit's
--// opacity scales either.
Config.Look = {
	UseTemplate = false,
	SizeStart = 2,
	SizeEnd = 25,
	PeakAt = 0.1,
	Opacity = 0.2, -- at its peak, at Emit opacity 1

	--// Set to replace the template's; nil keeps it
	Lifetime = nil :: NumberRange?,
	Color = nil :: Color3?,
	LightEmission = nil :: number?,
	LightInfluence = nil :: number?,
	Texture = nil :: string?,
}

--// Folder in workspace the puff parts live in
Config.FolderName = '_Smoke'

--// Brackets each frame's work; a game can hand in its own pair
Config.Profiler = {
	Begin = debug.profilebegin :: (label: string) -> (),
	End = debug.profileend :: () -> (),
}

return Config
