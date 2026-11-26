# Smoke

Smoke for Roblox that drifts like a fluid. Each puff is a single particle on a pooled, invisible,
anchored part, and code moves those parts every frame through three effects:

- **Curl noise.** The air swirls without bunching smoke up or thinning it out.
- **Wakes.** Smoke behind a moving body is dragged along after it, pulled in toward its track and
  churned. A drifting car's wake trails its slide, not the way it faces.
- **Pushing.** Smoke inside a body's bounding box is pushed out of it.

Nothing goes over the network. Each client runs its own puffs.

```lua
local Smoke = require(ReplicatedStorage.Smoke)

RunService.RenderStepped:Connect(function(deltaTime)
	Smoke.Step(deltaTime, bodies) -- { { Model = car, Root = car.PrimaryPart }, ... }
end)

--// One puff off a sliding tyre
Smoke.Emit(template, contactPosition, velocity, contactPosition.Y, heat)
```

## API

**`Smoke.Emit(template, position, velocity, floor, opacity?)`** releases one puff.
- `template` is a `ParticleEmitter` that shapes the puff. `Config.Look` can override parts of it,
  and its own motion properties (Speed, Spread, Acceleration, Drag) are ignored.
- `floor` is the height of the ground the puff came off. Its centre stays above that height.
- `opacity` (0 to 1) scales the look's opacity. At 0, nothing is released.
- Nothing is released once `Config.MaxPuffs` parts exist and none is free.

**`Smoke.Step(deltaTime, bodies?)`** moves every puff one frame. Call it once per frame on the
client. `bodies` is any table of `Body = { Model: Model, Root: BasePart }`, keyed however you like;
the key identifies the body between frames. Each body's bounding box is measured once, in
`Root`'s space, and `Root`'s velocity drives its wake.

**`Smoke.UseConfig(settings)`** makes Smoke read your own table from then on. That lets a game
keep its tuning next to its other settings and edit it live. Keys it lacks are filled in from the
defaults, and keys Smoke doesn't know are left alone. Without it, Smoke uses `Smoke.Config`.

**`Smoke.Restyle()`** picks up changes to `Config.Look`. Puffs already in the air keep the look
they left with.

**`Smoke.Clear()`** removes every puff. **`Smoke.Stats()`** returns the puffs in the air and the
parts made so far.

## Settings

`Smoke.Config`, read live. The defaults are in `src/Config.luau`.

| Group | Keys |
|---|---|
| Pool | `MaxPuffs` (parts across every source) |
| Drift | `Drag` (how fast a puff takes on the air's speed), `Rise`, `FloorHold`, `NoiseScale`, `NoiseDrift`, `Swirl` |
| Wake | `WakeMinSpeed`, `WakeLength`, `WakeWidth`, `WakeCarry`, `WakeConverge`, `WakeChurn`, `WakeChurnSpeed` |
| Push | `PushMargin`, `PushSpeed`, `PushCarry` |
| Look | `UseTemplate`, `SizeStart`, `SizeEnd`, `PeakAt`, `Opacity`, plus optional overrides `Lifetime`, `Color`, `LightEmission`, `LightInfluence`, `Texture` |
| Other | `FolderName` (the workspace folder for puff parts), `Profiler` (a `{ Begin, End }` pair called around each step; `debug.profilebegin`/`profileend` by default) |

With `Look.UseTemplate`, a puff takes the template's Size and Transparency. Otherwise it grows from
`SizeStart` to `SizeEnd`, fades in to its most opaque at `PeakAt` of its life, then fades out.

## Performance

- Puff parts are pooled and reused, so releasing a puff allocates nothing.
- All the parts move in one `BulkMoveTo` call.
- Each puff resamples the noise every second frame.
- Opacity comes in 16 steps, and each step's `NumberSequence` is cached per look.

## Development

Tools are pinned in `aftman.toml`. `rojo build -o Smoke.rbxm` builds the model;
`stylua src` and `selene src` format and lint it.
