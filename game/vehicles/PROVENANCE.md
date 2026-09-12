# Incinerator original vehicles

External source material: none

Meridian and Courier are original fictional vehicle designs authored for this
repository. Geometry, color/response atlases, and scripts are original project
content. No Rockstar, GTA, real manufacturer, downloaded model, or pretrained
asset is included. `generate.py` regenerates GLBs from the declared dimensions;
it does not overwrite authored handling. +Y is up, -Z is forward, +X is the
wheel axle. Body vertices are in metres; wheel meshes have unit width/diameter.
Canonical `.icvehicle` revision-1 handling was selected after EA2 measurement
and native driving. JSON files retain the authoring seeds; `.icvehicle` owns
subsequent commits. See `docs/validation/ea2-vehicle-authoring.md` for evidence.

EA2-H updates the road-car baselines to ICVEHDEF 2. Courier and Meridian are
revision 2; Courier AWD starts at revision 1 and shares Courier's original
visual assets. Its durable local ID is the first eight little-endian SHA-256
bytes of `incinerator.vehicle.archetype.courier-awd.v1`. Current JSON files
mirror the promoted canonical definitions; they are not runtime inheritance.
See `docs/validation/ea2-handling-profiles.md` for selection and rejection evidence.

The current fleet uses three independently cooked original silhouettes:
Meridian is a two-door coupe, Courier is a four-door sedan, and Courier AWD is
an SUV with its own `vehicle/courier-awd` bundle. Semantic `Body`, `Wheel`,
`Paint` and `Rubber` IDs remain stable within each bundle. GLB asset extras
record body style and door count; wheel geometry remains normalized and the
admitted definition supplies its dimensions and attachment positions.
The initial responsive fleet used Meridian 3, Courier 3, and Courier AWD 2.
The SUV's collision dimensions and wheel layout match its taller/wider model.
See `docs/validation/vehicle-responsive-fleet.md` for response tuning evidence.

The requested stronger-steering experiment advances Meridian and Courier to 4,
and Courier AWD to 3: maximum lock +10%, speed-curve fractions doubled up to
full lock. This candidate has unresolved reverse-transition and skid-fixture
failures; see `docs/validation/vehicle-steering-lock.md`. It is not a fully
validated replacement for the previous handling baseline.

Controlled high-speed testing restores the last passing steering values at
Meridian/Courier revision 5 and SUV revision 4. The stronger-lock experiment
remains documented but is no longer the shipping default. Body styles and the
single Apply workflow are retained. The fleet now starts at z=-8 facing south
down the streamed vehicle test road. See docs/validation/vehicle-high-speed.md.

## September 8, 2026 — stronger measured cornering

Courier and Meridian revision 6, Courier AWD SUV revision 5 raise authored lateral tire peak/sliding coefficients by 3x. The physics ground remains at 0.2; these are title vehicle definitions using the existing tire/surface combination, not a hidden adapter multiplier. Rear service brake torque is 600 Nm. The SUV also raises longitudinal tire coefficients by 3x and lowers its centre of mass from -0.18 to -0.45 m to avoid the rollover observed with higher grip. Rear longitudinal sliding-slip coordinates are 0.30 for Meridian and 0.12 for SUV, preserving power/handbrake breakaway in the measured cohort. Steering lock, speed fractions and response rates remain unchanged. See [the cornering and town validation](../../docs/validation/vehicle-grip-town.md) for before/after measurements and limitations.

## September 8, 2026 — speed and grip follow-up

Sedan/coupe revision 7 and SUV revision 6 increase forward speed to approximately twice the measured baseline and strengthen tire grip. Engine curves, tire response, coupe lower gears, sedan reverse ratio and sedan/coupe centre of mass are coordinated canonical tuning changes. Steering mapping/rates and body styles remain unchanged. Exact before/after definitions, all coupled metrics and validation are retained in [vehicle-speed-grip](../../docs/validation/vehicle-speed-grip.md).

## September 12, 2026 — handbrake stopping and additional cornering grip

Sedan/coupe revision 8 and SUV revision 7 add 20% effective lateral tire capacity,
stronger rear sliding traction and less lateral-grip collapse at wheel lock.
Sedan/SUV centres of mass move down 0.10 m after the stronger-grip candidate
rolled during sustained full steering. The shared game pedal policy gives the
handbrake priority over propulsion. See [the stopping/cornering validation](../../docs/validation/vehicle-handbrake-grip.md)
for complete before/after values, held-stop coverage, coupling and tradeoffs.
