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
