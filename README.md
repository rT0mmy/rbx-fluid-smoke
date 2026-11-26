# Smoke

Smoke for Roblox that drifts like a fluid. Each puff is a single particle on a pooled, invisible,
anchored part, and code moves those parts every frame through these effects:

- **Curl noise.** The air swirls without bunching smoke up or thinning it out.
- **Wind.** A steady drift, optionally gusting, and optionally following `workspace.GlobalWind`.
- **Wakes.** Smoke behind a moving body is dragged along after it, pulled in toward its track and
  churned. A drifting car's wake trails its slide, not the way it faces.
- **Pushing.** Smoke inside a body's bounding box is pushed out of it.
- **Blasts.** `Smoke.Impulse` throws smoke out from a point.

Puffs stay above the ground: either the height they were released at, or, with `GroundCast`, the
ground found beneath them as they drift, so smoke follows slopes and ramps. Puffs fade out as they
reach the camera, so they don't vanish all at once as the camera passes through them.

Nothing goes over the network. Each client runs its own puffs.

```lua
local Smoke = require(ReplicatedStorage.Smoke)

local tyre = Smoke.Source(template, { Spacing = 1.5, Spread = 0.3 })

RunService.RenderStepped:Connect(function(deltaTime)
	if sliding then
		tyre:Update(deltaTime, contactPosition, velocity, contactPosition.Y, heat)
	else
		tyre:Reset()
	end

	Smoke.Step(deltaTime, { { Model = car, Root = car.PrimaryPart } })
end)
```

## API

**`Smoke.Source(template, options?)`** makes a point that smoke comes from steadily, such as a tyre.
`options` is `{ Rate: number?, Spacing: number?, Spread: number? }`: puffs per second, a puff every
`Spacing` studs travelled, and how far across the ground each puff lands from the point. Puffs released
by distance are laid out along the path since the last update, so they're evenly spaced whatever the
frame rate.
- `source:Update(deltaTime, position, velocity, floor?, opacity?)` releases the puffs due since the
  last update and returns how many were released. A jump of over 100 studs leaves no trail.
- `source:Burst(count, position, velocity, floor?, opacity?)` releases `count` puffs at once.
- `source:Reset()` forgets where the source was, so the next update doesn't lay a trail from there.
  Call it when a tyre stops sliding or leaves the ground.

**`Smoke.Emit(template, position, velocity, floor?, opacity?)`** releases one puff and returns
whether it did.
- `template` is a `ParticleEmitter` that shapes the puff. `Config.Look` can override parts of it,
  and its own motion properties (Speed, Spread, Acceleration, Drag) are ignored.
- `floor` is the height of the ground the puff came off. Its centre stays above that height. When
  it's nil, the ground beneath the puff is found with `GroundCast` on, or the puff's own height is
  used otherwise.
- `opacity` (0 to 1) scales the look's opacity. At 0, nothing is released.
- Once `Config.MaxPuffs` parts exist and none is free, a free part made for another template is
  reused, so templates cloned per car and later destroyed don't strand their parts. Failing that,
  `StealOldest` takes the part of the puff nearest the end of its life; otherwise the puff is
  dropped and counted in `Stats`.
- It only runs on the client. On the server it warns once and releases nothing.

**`Smoke.Step(deltaTime, bodies?)`** moves every puff one frame. Call it once per frame on the
client. `bodies` is any table of `Body = { Model: Model, Root: BasePart }`, keyed however you like,
and it can be rebuilt every frame; `Model` identifies the body between frames. Each body's bounding
box is measured once, in `Root`'s space, and again if its `Root` changes or it is left out of a
step. `Root`'s velocity drives its wake.

**`Smoke.Impulse(position, radius, strength)`** throws smoke out from a point, as a blast would.
Puffs within `radius` get up to `strength` studs per second away from it, less the further out they
are, and settle back into the air at `Drag`.

**`Smoke.UseConfig(settings)`** makes Smoke read your own table from then on, and returns it. That
lets a game keep its tuning next to its other settings and edit it live. Keys it lacks are filled in
from the defaults, and keys Smoke doesn't know are left alone. Without it, Smoke uses `Smoke.Config`.

**`Smoke.Restyle()`** picks up changes to `Config.Look`. Puffs already in the air keep the look
they left with.

**`Smoke.Clear()`** removes every puff. **`Smoke.Stats()`** returns the puffs in the air, the parts
made so far, and the puffs dropped so far because every part was in the air.

The module is `--!strict` and exports `Config`, `Look`, `Body`, `Source` and `SourceOptions` types.

## Settings

`Smoke.Config`, read live. The defaults are in `src/Config.luau`.

| Group | Keys |
|---|---|
| Pool | `MaxPuffs` (parts across every source), `StealOldest` (when every part is in the air, a new puff takes the oldest one's part instead of being dropped) |
| Step | `MaxStep` (the most time one frame moves puffs, so a hitch can't carry them through a body), `FarDistance` (studs from the camera beyond which puffs resample the noise half as often) |
| Camera | `NearFade`, `NearHide` (in puff radii, measured along the camera's view: a puff starts fading at `NearFade` and is gone by `NearHide`; `NearFade` 0 turns it off) |
| Drift | `Drag` (how fast a puff takes on the air's speed), `Rise`, `FloorHold`, `NoiseScale`, `NoiseDrift`, `Swirl` |
| Wind | `Wind` (studs per second), `GlobalWind` (fraction of `workspace.GlobalWind` added), `Gust` (0 to 1, how far the wind swells and slackens) |
| Ground | `GroundCast` (follow the ground beneath each puff), `GroundEvery` (seconds between casts per puff), `GroundReach` (studs down), `GroundParams` (`RaycastParams`; nil leaves out the bodies passed to `Step`) |
| Wake | `WakeMinSpeed`, `WakeLength`, `WakeWidth`, `WakeCarry`, `WakeConverge`, `WakeChurn`, `WakeChurnSpeed` |
| Push | `PushMargin`, `PushSpeed`, `PushCarry` |
| Look | `UseTemplate`, `SizeStart`, `SizeEnd`, `PeakAt`, `Opacity`, plus optional overrides `Lifetime`, `Color`, `LightEmission`, `LightInfluence`, `Texture` |
| Other | `FolderName` (the workspace folder for puff parts), `Profiler` (a `{ Begin, End }` pair called around each step; `debug.profilebegin`/`profileend` by default) |

With `Look.UseTemplate`, a puff takes the template's Size and Transparency. Otherwise it grows from
`SizeStart` to `SizeEnd`, fades in to its most opaque at `PeakAt` of its life, then fades out.

## Performance

- Puff parts are pooled and reused, so releasing a puff allocates nothing.
- All the parts move in one `BulkMoveTo` call.
- The math uses the `vector` library, whose calls compile to builtins.
- Each puff resamples the noise every second frame, or every fourth beyond `FarDistance`.
- Bodies with no puff within their reach are skipped whole, and per-body wake terms are worked
  out once per frame rather than once per puff.
- With `GroundCast`, each puff casts once per `GroundEvery`, staggered so the casts spread across
  frames: about 8 a frame at 128 puffs and 60 FPS.
- Opacity comes in 16 steps, and each step's `NumberSequence` is cached per look. The camera fade
  only sets a puff's `Transparency` when its step changes.

## Development

Tools are pinned in `aftman.toml`. `rojo build -o Smoke.rbxm` builds the model;
`stylua src` and `selene src` format and lint it.
