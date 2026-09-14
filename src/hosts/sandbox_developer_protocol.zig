//! Concrete, versioned developer-control schemas for the Incinerator sandbox.
//!
//! This is deliberately not a generic command or property protocol. Each
//! operation below maps to an existing query, editor, authoring, persistence,
//! or measurement owner. The Unix transport and product composition live in
//! adapters; this file owns only stable wire values and framing.

const std = @import("std");
const engine = @import("engine_contracts");

pub const protocol_cohort: u16 = 6;
pub const vehicle = @import("vehicle_authoring_contract");
pub const lighting = @import("lighting_authoring_contract");
pub const material = @import("material_authoring_contract");
pub const MaterialValue = engine.assets.MaterialMetadata;
pub const framing_version: u16 = 1;
pub const frame_header_bytes: usize = 32;
pub const frame_magic = "ICDV".*;
/// EA2 definitions contain authored-length curves and labels. Payload storage
/// follows the actual framed size; allocation failure is reported by the local
/// transport. The former 4 KiB fixture limit cannot represent authored vehicles.
pub const max_request_payload_bytes: usize = std.math.maxInt(usize);
pub const max_response_payload_bytes: usize = std.math.maxInt(usize);
/// The maximum-path, maximum-schema discovery document measures 609 bytes.
/// Keep its separate file boundary explicit because it is read before a socket
/// or framed protocol has been admitted.
pub const max_discovery_document_bytes: usize = 4 * 1024;

pub fn maxPayloadBytes(kind: FrameKind) usize {
    return switch (kind) {
        .request => max_request_payload_bytes,
        .response => max_response_payload_bytes,
    };
}

pub const RunId = engine.authoring.RunId;
pub const SchemaId = engine.developer_endpoint.SchemaId;
pub const PersistentId = engine.identity.PersistentId;
pub const AssetId = engine.assets.AssetId;

pub const schema_namespace: u32 = 0x4943_4456; // "ICDV"
pub const query_schema = SchemaId{ .namespace = schema_namespace, .local = 1 };
pub const editor_control_schema = SchemaId{ .namespace = schema_namespace, .local = 2 };
pub const crate_authoring_schema = SchemaId{ .namespace = schema_namespace, .local = 3 };
pub const persistence_schema = SchemaId{ .namespace = schema_namespace, .local = 4 };
pub const measurement_schema = SchemaId{ .namespace = schema_namespace, .local = 5 };
pub const material_schema = SchemaId{ .namespace = schema_namespace, .local = 6 };
pub const lighting_schema = SchemaId{ .namespace = schema_namespace, .local = 8 };
pub const vehicle_schema = SchemaId{ .namespace = schema_namespace, .local = 7 };

pub const SchemaClass = enum {
    query,
    editor_control,
    crate_authoring,
    persistence,
    measurement,
    lighting_authoring,
    material_authoring,
    vehicle_authoring,
};

pub const SchemaDescriptor = struct {
    id: SchemaId,
    name: []const u8,
    version: u16,
    class: SchemaClass,
    description: []const u8,
    wire_shape_signature: []const u8,
};

pub const common_wire_shape_signature_v2 =
    "ICDV/1|frame{magic=ICDV,version:u16be,kind:u8,flags:u8,cohort:u16be," ++
    "reserved:u16be,request_id:u64be,payload_len:u64be,crc32:u32be}|" ++
    "FrameKind{request=1,response=2}|" ++
    "discovery{document_version:u16,lifecycle:Lifecycle,run_id:RunId," ++
    "protocol_cohort:u16,endpoint_path:?string,schema_ids:[]SchemaId," ++
    "schema_digest:?sha256,failure:?string}|" ++
    "request{protocol_cohort:u16,expected_run_id:RunId,request_id:u64," ++
    "schema_id:SchemaId,command:tagged_union}|" ++
    "response{protocol_cohort:u16,request_id:u64,schema_id:SchemaId," ++
    "run_id:RunId,outcome:success(Payload)|failure(Failure)}|" ++
    "RunId{started_wall_unix_ms:i64,nonce:u64}|SchemaId{namespace:u32,local:u32}|" ++
    "Target{persistent_entity:PersistentId{namespace:u64,local:u64}," ++
    "gameplay_entity:{namespace:u64,local:u64,incarnation:u32}," ++
    "content_asset:AssetId{namespace:u64,local:u64}}|" ++
    "Vec3=f32[3]|Bounds{minimum:Vec3,maximum:Vec3}|" ++
    "Lifecycle{disabled,declared,starting,available,stopping,stopped,failed}|" ++
    "SchemaClass{query,editor_control,crate_authoring,persistence,measurement,lighting_authoring,material_authoring,vehicle_authoring}|" ++
    "Availability{available,unavailable}|" ++
    "WorldSemanticType{crate,local_player,remote_player,npc,vehicle,carryable}|" ++
    "ContentSemanticType{district,scene,mesh,material,texture,lighting,vehicle_archetype," ++
    "lighting_preset,map}|AuthoringSource{ui,local_developer_client," ++
    "scripted_validation}|EditScope{preview,session,asset_commit}|" ++
    "AuthoringDisposition{pending,accepted,rejected}|RejectionKind{" ++
    "invalid_request,stale_revision,scope_not_supported,target_not_found," ++
    "target_kind_not_supported,owner_busy,owner_unavailable," ++
    "durable_commit_failed,owner_specific}|SaveDisposition{pending,committed," ++
    "failed,not_found}|FrameDisposition{pending,captured,failed,not_found}|" ++
    "Failure{code:FailureCode,detail:string}|" ++
    "FailureCode{malformed_frame,malformed_json,unknown_protocol_cohort," ++
    "unknown_schema,command_schema_mismatch,invalid_request,run_mismatch," ++
    "endpoint_stopping,owner_busy,owner_unavailable,target_not_found," ++
    "target_kind_not_supported,internal_error}";

const query_wire_shape_v5 =
    "material_details=Material@material-authoring.v1|AssetOwner{engine,game}|SourceFormat{gltf,glb,authored}|AssetDetails{scene,mesh,material:Material,texture:TextureMetadata,lighting}|" ++
    "commands{describe:{},schema_list:{},world_list:{},content_list:{}," ++
    "inspect:{target:Target}}|payloads{endpoint_description:{product:string," ++
    "local_only:bool,transport:string,protocol_cohort:u16,framing_version:u16," ++
    "run_id:RunId,schema_digest:sha256,capabilities:[]string}," ++
    "schema_list:[]SchemaDescriptor{id:SchemaId,name:string,version:u16," ++
    "class:SchemaClass,description:string,wire_shape_signature:string}," ++
    "world_list:[]WorldEntry{target:Target,authoring_target:?Target,semantic_type:WorldSemanticType," ++
    "label:string,selected:bool,position:?Vec3,bounds:?Bounds," ++
    "availability:Availability,current_revision:?u64,inspectable:bool," ++
    "authorable:bool},content_list:[]ContentEntry{asset_id:AssetId," ++
    "semantic_type:ContentSemanticType,label:string,owner:AssetOwner,bundle_key:string," ++
    "revision:u64,availability:Availability,digest:sha256,dependencies:[]AssetId," ++
    "source_format:SourceFormat,cook_status:CookStatus,residency:Residency," ++
    "last_use_frame:?u64,details:AssetDetails,inspectable:bool,authorable:bool}," ++
    "inspection:Inspection{" ++
    "crate:{target:Target,selected:bool,availability:Availability," ++
    "authoring_revision:u64,position:Vec3,half_extents:Vec3," ++
    "linear_velocity:Vec3,angular_velocity:Vec3},world:{entry:WorldEntry}," ++
    "content:{entry:ContentEntry}}}";

const editor_control_wire_shape_v1 =
    "commands{selection_set:{target:Target},selection_clear:{},camera_inspect:{}," ++
    "camera_set_mode:{mode:CameraMode},camera_set_pose:{position:Vec3," ++
    "yaw_radians:f32,pitch_radians:f32},camera_focus:{target:Target}}|" ++
    "payloads{selection:{selected:?Target},camera:CameraState," ++
    "camera_mutation:CameraState}|CameraState{mode:CameraMode," ++
    "free_camera_initialized:bool,position:Vec3,yaw_radians:f32," ++
    "pitch_radians:f32,move_speed_meters_per_second:f32," ++
    "last_focus:?{center:Vec3,radius:f32}}|CameraMode{character,free_camera}";

const crate_authoring_wire_shape_v1 =
    "commands{crate_set_position:{target:Target,expected_revision:u64," ++
    "position:Vec3},transaction_inspect:{transaction_id:u64}," ++
    "undo:{target:Target,expected_revision:u64},redo:{target:Target," ++
    "expected_revision:u64}}|payloads{authoring_admission:{admitted:bool," ++
    "source:AuthoringSource,target:Target,transaction_id:?u64," ++
    "expected_revision:u64,scope:EditScope,rejection:?AuthoringRejection}," ++
    "transaction:{transaction_id:u64,source:AuthoringSource,target:Target," ++
    "scope:EditScope,disposition:AuthoringDisposition,expected_revision:u64," ++
    "committed_revision:?u64,before_position:?Vec3,requested_position:?Vec3," ++
    "committed_position:?Vec3,rejection:?AuthoringRejection," ++
    "authority_tick:?u64,presentation_frame:?u64}}|" ++
    "AuthoringRejection{kind:RejectionKind,owner_domain:?u32,owner_code:?u32," ++
    "detail:string}";

const persistence_wire_shape_v1 =
    "commands{save_world:{},save_result:{save_request_id:u64}}|" ++
    "payloads{save_admission:{admitted:bool,save_request_id:?u64," ++
    "rejection:?string},save_result:{save_request_id:u64," ++
    "disposition:SaveDisposition,slot:string,generation:?u64," ++
    "payload_bytes:?u64,detail:?string}}";

const measurement_wire_shape_v1 =
    "commands{capture_frame:{},frame_result:{capture_id:u64}}|" ++
    "payloads{frame_admission:{admitted:bool,capture_id:?u64,rejection:?string}," ++
    "frame_result:{capture_id:u64,disposition:FrameDisposition," ++
    "artifact_path:?string,authority_tick:?u64,presentation_frame:?u64," ++
    "wall_unix_ms:?i64,detail:?string}}";

const material_wire_shape_v1 =
    "commands{material_inspect:{target:AssetId},material_edit:MaterialRequest}|" ++
    "MaterialRequest{target:AssetId,expected_revision:u64,action:preview(Material)|preview_assignment(AssetId)|assign(AssetId)|clear_preview|apply(Material)|revert|commit}|" ++
    "Material{base_color:f32[4],base_color_texture:?AssetId,base_color_texcoord:u8," ++
    "metallic:f32,roughness:f32,normal_scale:f32,occlusion_strength:f32,emissive:f32[3]," ++
    "metallic_roughness_texture:?AssetId,normal_texture:?AssetId,occlusion_texture:?AssetId,emissive_texture:?AssetId}|" ++
    "payloads{material_inspection:union{material:{id:AssetId,label:string,revision:u64,asset_revision:u64,committed:Material,session:Material,preview:?{source:AuthoringSource,value:Material}},binding:{mesh:AssetId,revision:u64,asset_revision:u64,committed:AssetId,session:AssetId,preview:?{source:AuthoringSource,value:AssetId}}}," ++
    "material_outcome:{transaction_id:u64,source:AuthoringSource,target:AssetId,action:MaterialAction,revision:u64,asset_revision:u64,rejection:?MaterialRejection}}|" ++
    "MaterialRejection{target_missing,wrong_target_kind,material_missing,stale_revision,invalid_material,texture_missing,texture_color_space,preview_owned_by_another_producer,persistence_unavailable,persistence_failed}";

const vehicle_wire_shape_v2 =
    "commands{vehicle_assets:{},vehicle_inspect:{target:PersistentId},vehicle_edit:VehicleRequest,vehicle_result:{transaction_id:u64}}|" ++
    "VehicleRequest{target:PersistentId,expected_revision:u64,expected_asset_revision:u64,action:apply(Definition)|rebuild(Definition)|revert|commit|measure(Definition)|preview(Definition)|clear_preview}|" ++
    "Definition{version:u32,id:{asset:AssetId},label:string,revision:u64,tuning:VehicleTuningV1,visuals:{chassis:VisualPart,wheels:VisualPart[4]}}|" ++
    "VisualPart{mesh:AssetId,material:AssetId,local_pose:{position:f32[3],rotation:f32[4]},scale:f32[3]}|" ++
    "VehicleTuningV1{steering:{rise_per_second:f32,return_per_second:f32,speed_curve:[]{speed_mps:f32,lock_fraction:f32}},chassis_half_extents:f32[3],center_of_mass_offset:f32[3],mass:f32,wheel_attachment_positions:f32[4][3],wheel_radius:f32,wheel_width:f32,suspension_min_length:f32,suspension_max_length:f32,suspension_frequency:f32,suspension_damping:f32,max_steer_radians:f32,max_brake_torque:f32,max_hand_brake_torque:f32,rear_axle:RearAxle,front_anti_roll_stiffness:f32,tire_friction:Tire,powertrain:Powertrain,front_differential_ratio:f32,front_limited_slip_ratio:f32,max_pitch_roll_radians:f32,wheel_collision_max_slope_radians:f32}|" ++
    "RearAxle{suspension_min_length:f32,suspension_max_length:f32,suspension_frequency:f32,suspension_damping:f32,brake_torque_nm:f32,tire_friction:Tire,anti_roll_stiffness:f32}|" ++
    "Tire{longitudinal_peak_slip:f32,longitudinal_peak_friction:f32,longitudinal_slide_slip:f32,longitudinal_slide_friction:f32,lateral_peak_angle_radians:f32,lateral_peak_friction:f32,lateral_slide_angle_radians:f32,lateral_slide_friction:f32}|" ++
    "Powertrain{max_torque_nm:f32,idle_rpm:f32,max_rpm:f32,inertia_kg_m2:f32,angular_damping:f32,torque_curve:[]{rpm_fraction:f32,torque_fraction:f32},forward_gears:[]f32,reverse_gears:[]f32,switch_time_s:f32,clutch_release_s:f32,switch_latency_s:f32,shift_up_rpm:f32,shift_down_rpm:f32,clutch_strength:f32,front_torque_fraction:f32,rear_differential_ratio:f32,rear_limited_slip_ratio:f32,center_limited_slip_ratio:f32}|" ++
    "payloads{vehicle_assets:[]{id:VehicleArchetypeId,label:string,revision:u64,digest:sha256},vehicle_inspection:{live:VehicleView,committed:Definition,asset_revision:u64,presets:[]{source_id:VehicleArchetypeId,source_label:string,source_revision:u64,source_digest:sha256,candidate:Definition},preview:?{source:AuthoringSource,transaction_id:u64,visuals:{chassis:VisualPart,wheels:VisualPart[4]}}},vehicle_outcome:VehicleResult}|" ++
    "VehicleResult{transaction_id:u64,source:AuthoringSource,target:PersistentId,action:VehicleAction,disposition:pending|accepted|rejected,revision:u64,asset_revision:u64,definition_digest:sha256,authority_tick:?u64,rejection:?string,artifact_path:?string}|VehicleView{conditioned_steering:f32,id:PersistentId,definition:Definition,definition_digest:sha256,revision:u64,state:VehicleState,input:VehicleInput,driver_id:?PersistentId}|VehicleInput{throttle:f32,steering:f32,brake:f32,hand_brake:f32}|VehicleState{chassis:{pose:{position:f32[3],rotation:f32[4]},velocity:{linear:f32[3],angular:f32[3]}},wheels:WheelState[4],engine_rpm:f32,current_gear:i32,powertrain:{engine_rpm:f32,gear:i32,clutch_friction:f32,switch_time_left_s:f32,clutch_release_left_s:f32,switch_latency_left_s:f32}}|WheelState{pose:{position:f32[3],rotation:f32[4]},angular_velocity:f32,rotation_angle:f32,steer_angle:f32,suspension_length:f32,has_contact:bool,suspension_impulse_ns:f32,longitudinal_impulse_ns:f32,lateral_impulse_ns:f32,longitudinal_slip:f32,lateral_slip_radians:f32}";

const lighting_wire_shape_v1 =
    "commands{lighting_list:{},lighting_inspect:{target:AssetId},lighting_edit:{target:AssetId,expected_revision:u64,action:preview(Value)|clear_preview|apply(Value)|revert|undo|redo|commit|activate}}|" ++
    "Value{environment:Environment|fixture:{light:Light,pose:Pose,mount:world|vehicle_asset(AssetId)|carryable,follows_night:bool,visual:?Visual,surface:?Surface}}|" ++
    "Visual{mesh:AssetId,material:AssetId,local_pose:Pose,scale:f32[3],emissive_scale:f32}|Surface{mesh:AssetId,emissive_scale:f32}|" ++
    "Light{kind:directional|point|spot,color:f32[3],intensity:f32,enabled:bool,range:?f32,inner_angle:f32,outer_angle:f32,source_radius:f32,casts_shadows:bool}|" ++
    "Environment{sun:Light,sun_direction:f32[3],ambient:f32[3],background:f32[3],display:{exposure:f32,bloom_strength:f32,bloom_threshold:f32,bloom_radius:f32},headlights_enabled:bool,artificial_lights_enabled:bool,shadow_resolution:u32,shadow_bias:f32}|" ++
    "Pose{position:f32[3],rotation:f32[4]}|Record{id:AssetId,label:string,revision:u64,asset_revision:u64,committed:Value,session:Value,preview:?{source:AuthoringSource,value:Value}}|" ++
    "payloads{lighting_list:{records:[]Record,active_environment:AssetId,library_revision:u64,last_ui_outcome:?Outcome,persistence_available:bool,installed_root:?string,project_root:?string},lighting_inspection:Record,lighting_outcome:Outcome}|" ++
    "Outcome{transaction_id:u64,source:AuthoringSource,target:AssetId,action:LightingAction,revision:u64,asset_revision:u64,library_revision:u64,rejection:?LightingRejection}|" ++
    "LightingRejection{target_missing,stale_revision,invalid_value,wrong_value_kind,preview_owned_by_another_producer,persistence_unavailable,persistence_failed,nothing_to_undo,nothing_to_redo}";

const registered_schemas = [_]SchemaDescriptor{
    .{ .id = lighting_schema, .name = "incinerator.demo.lighting-authoring.v1", .version = 1, .class = .lighting_authoring, .description = "Presentation lighting presets, fixture previews, history and durable assets.", .wire_shape_signature = lighting_wire_shape_v1 },
    .{ .id = vehicle_schema, .name = "incinerator.sandbox.vehicle-authoring.v2", .version = 2, .class = .vehicle_authoring, .description = "Per-instance vehicle inspection, revisioned apply/rebuild/revert, atomic archetype commit and isolated measurement.", .wire_shape_signature = vehicle_wire_shape_v2 },
    .{ .id = material_schema, .name = "incinerator.demo.material-authoring.v1", .version = 1, .class = .material_authoring, .description = "Typed material inspection, preview, session apply/revert, and durable game asset commit.", .wire_shape_signature = material_wire_shape_v1 },
    .{
        .id = query_schema,
        .name = "incinerator.sandbox.query.v5",
        .version = 5,
        .class = .query,
        .description = "Endpoint, world, content, and stable-target inspection.",
        .wire_shape_signature = query_wire_shape_v5,
    },
    .{
        .id = editor_control_schema,
        .name = "incinerator.sandbox.editor-control.v1",
        .version = 1,
        .class = .editor_control,
        .description = "Shared editor selection and viewport camera control.",
        .wire_shape_signature = editor_control_wire_shape_v1,
    },
    .{
        .id = crate_authoring_schema,
        .name = "incinerator.sandbox.crate-authoring.v1",
        .version = 1,
        .class = .crate_authoring,
        .description = "Revision-safe crate relocation, transaction inspection, undo, and redo.",
        .wire_shape_signature = crate_authoring_wire_shape_v1,
    },
    .{
        .id = persistence_schema,
        .name = "incinerator.sandbox.persistence.v1",
        .version = 1,
        .class = .persistence,
        .description = "World-save request and result inspection.",
        .wire_shape_signature = persistence_wire_shape_v1,
    },
    .{
        .id = measurement_schema,
        .name = "incinerator.sandbox.measurement.v1",
        .version = 1,
        .class = .measurement,
        .description = "Correlated rendered-frame capture and result inspection.",
        .wire_shape_signature = measurement_wire_shape_v1,
    },
};

/// Frozen SHA-256 of the complete cohort-6 canonical wire-shape catalog.
/// Any intentional wire change must advance the affected schema/cohort and
/// update this value together with its explicit signature.
pub const canonical_schema_digest_v6 = engine.assets.Digest{ 0xd4, 0xf3, 0x6c, 0xcb, 0x9f, 0x29, 0x88, 0xbc, 0x96, 0x0a, 0x02, 0x67, 0xee, 0xb5, 0x49, 0x77, 0xb6, 0x9c, 0x65, 0xc0, 0xaf, 0x54, 0x82, 0x7d, 0x8d, 0x8d, 0x06, 0xa6, 0x16, 0xa9, 0x3d, 0xdf };

pub fn schemaCatalog() []const SchemaDescriptor {
    return &registered_schemas;
}

/// Digest of a canonical, manually registered schema description. Descriptions
/// are part of the cohort contract; field reflection is intentionally absent.
pub fn schemaDigest() engine.assets.Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(common_wire_shape_signature_v2);
    hasher.update(&.{0xfe});
    for (registered_schemas) |schema| {
        var numbers: [10]u8 = undefined;
        std.mem.writeInt(u32, numbers[0..4], schema.id.namespace, .big);
        std.mem.writeInt(u32, numbers[4..8], schema.id.local, .big);
        std.mem.writeInt(u16, numbers[8..10], schema.version, .big);
        hasher.update(&numbers);
        hasher.update(schema.name);
        hasher.update(&.{0});
        hasher.update(@tagName(schema.class));
        hasher.update(&.{0});
        hasher.update(schema.description);
        hasher.update(&.{0});
        hasher.update(schema.wire_shape_signature);
        hasher.update(&.{0xff});
    }
    return hasher.finalResult();
}

pub fn schemaIsRegistered(id: SchemaId) bool {
    for (registered_schemas) |schema| {
        if (std.meta.eql(schema.id, id)) return true;
    }
    return false;
}

pub const Lifecycle = engine.developer_endpoint.Lifecycle;

/// Atomically written next to the process-local socket. The endpoint path is
/// the only transport address exposed; no runtime objects or source paths are
/// discoverable through this document.
pub const DiscoveryDocument = struct {
    document_version: u16 = 1,
    lifecycle: Lifecycle,
    run_id: RunId,
    protocol_cohort: u16 = protocol_cohort,
    endpoint_path: ?[]const u8 = null,
    schema_ids: []const SchemaId,
    schema_digest: ?engine.assets.Digest = null,
    failure: ?[]const u8 = null,

    pub fn validate(self: DiscoveryDocument) !void {
        if (self.document_version != 1) return error.UnknownDiscoveryVersion;
        try self.run_id.validate();
        if (self.protocol_cohort != protocol_cohort) return error.ProtocolCohortMismatch;
        for (self.schema_ids, 0..) |id, index| {
            try id.validate();
            if (!schemaIsRegistered(id)) return error.UnknownDeveloperSchema;
            for (self.schema_ids[0..index]) |previous| {
                if (std.meta.eql(previous, id)) return error.DuplicateDeveloperSchema;
            }
        }
        if (self.schema_digest) |digest| {
            try engine.assets.validateDigest(digest);
            if (!std.mem.eql(u8, &digest, &schemaDigest())) {
                return error.SchemaDigestMismatch;
            }
        }
        if (self.lifecycle != .failed and self.failure != null) {
            return error.UnexpectedEndpointFailure;
        }
        switch (self.lifecycle) {
            .starting, .available, .stopping => {
                const path = self.endpoint_path orelse return error.ActiveEndpointPathMissing;
                _ = try engine.developer_endpoint.Path.init(path);
            },
            .disabled, .declared, .stopped => {
                if (self.endpoint_path != null) return error.InactiveEndpointPathPresent;
                if (self.schema_digest != null) return error.InactiveSchemaDigestPresent;
            },
            .failed => {
                if (self.endpoint_path != null) return error.InactiveEndpointPathPresent;
                if (self.schema_digest != null) return error.InactiveSchemaDigestPresent;
                const failure = self.failure orelse return error.EndpointFailureMissing;
                if (failure.len == 0) return error.EndpointFailureMissing;
            },
        }
        if (self.lifecycle == .available and self.schema_digest == null) {
            return error.AvailableSchemaDigestMissing;
        }
    }
};

pub const GameplayEntityId = struct {
    namespace: u64,
    local: u64,
    incarnation: u32,

    pub fn validate(self: GameplayEntityId) !void {
        if (self.namespace == 0) return error.InvalidGameplayEntityNamespace;
        if (self.local == 0) return error.InvalidGameplayEntityLocal;
        // Incarnation zero is the established EntityRef convention for
        // identities that do not need generation disambiguation.
    }
};

/// Stable, explicit target variants. These are semantic identities, never
/// backend handles, pointers, paths, or arbitrary object/property strings.
pub const Target = union(enum) {
    persistent_entity: PersistentId,
    gameplay_entity: GameplayEntityId,
    content_asset: AssetId,

    pub fn validate(self: Target) !void {
        switch (self) {
            .persistent_entity => |id| try id.validate(),
            .gameplay_entity => |id| try id.validate(),
            .content_asset => |id| try id.validate(),
        }
    }
};

pub const Vec3 = [3]f32;

pub const Bounds = struct {
    minimum: Vec3,
    maximum: Vec3,
};

pub const Availability = enum {
    available,
    unavailable,
};

pub const WorldSemanticType = enum {
    crate,
    local_player,
    remote_player,
    npc,
    vehicle,
    carryable,
};

pub const ContentSemanticType = enum {
    district,
    scene,
    mesh,
    material,
    texture,
    lighting,
    vehicle_archetype,
    lighting_preset,
    map,
};

pub const WorldEntry = struct {
    authoring_target: ?Target = null,
    target: Target,
    semantic_type: WorldSemanticType,
    label: []const u8,
    selected: bool,
    position: ?Vec3,
    bounds: ?Bounds,
    availability: Availability,
    current_revision: ?u64,
    inspectable: bool,
    authorable: bool,
};

pub const ContentEntry = struct {
    asset_id: AssetId,
    semantic_type: ContentSemanticType,
    label: []const u8,
    owner: engine.assets.Owner,
    bundle_key: []const u8,
    revision: u64,
    availability: Availability,
    digest: engine.assets.Digest,
    dependencies: []const AssetId,
    source_format: engine.assets.SourceFormat,
    cook_status: engine.assets.CookStatus,
    residency: engine.assets.Residency,
    last_use_frame: ?u64,
    details: engine.assets.Details,
    inspectable: bool,
    authorable: bool,
};

pub const CrateInspection = struct {
    target: Target,
    selected: bool,
    availability: Availability,
    authoring_revision: u64,
    position: Vec3,
    half_extents: Vec3,
    linear_velocity: Vec3,
    angular_velocity: Vec3,
};

pub const WorldInspection = struct {
    entry: WorldEntry,
};

pub const ContentInspection = struct {
    entry: ContentEntry,
};

pub const Inspection = union(enum) {
    crate: CrateInspection,
    world: WorldInspection,
    content: ContentInspection,
};

pub const CameraMode = enum {
    character,
    free_camera,
};

pub const CameraState = struct {
    mode: CameraMode,
    free_camera_initialized: bool,
    position: Vec3,
    yaw_radians: f32,
    pitch_radians: f32,
    move_speed_meters_per_second: f32,
    last_focus: ?struct {
        center: Vec3,
        radius: f32,
    },
};

pub const AuthoringSource = enum {
    ui,
    local_developer_client,
    scripted_validation,
};

pub const EditScope = enum {
    preview,
    session,
    asset_commit,
};

pub const AuthoringDisposition = enum {
    pending,
    accepted,
    rejected,
};

pub const RejectionKind = enum {
    invalid_request,
    stale_revision,
    scope_not_supported,
    target_not_found,
    target_kind_not_supported,
    owner_busy,
    owner_unavailable,
    durable_commit_failed,
    owner_specific,
};

pub const AuthoringRejection = struct {
    kind: RejectionKind,
    owner_domain: ?u32 = null,
    owner_code: ?u32 = null,
    detail: []const u8,
};

pub const AuthoringAdmission = struct {
    admitted: bool,
    source: AuthoringSource = .local_developer_client,
    target: Target,
    transaction_id: ?u64,
    expected_revision: u64,
    scope: EditScope = .session,
    rejection: ?AuthoringRejection = null,
};

pub const TransactionInspection = struct {
    transaction_id: u64,
    source: AuthoringSource,
    target: Target,
    scope: EditScope,
    disposition: AuthoringDisposition,
    expected_revision: u64,
    committed_revision: ?u64,
    before_position: ?Vec3,
    requested_position: ?Vec3,
    committed_position: ?Vec3,
    rejection: ?AuthoringRejection,
    authority_tick: ?u64,
    presentation_frame: ?u64,
};

pub const SaveDisposition = enum {
    pending,
    committed,
    failed,
    not_found,
};

pub const SaveAdmission = struct {
    admitted: bool,
    save_request_id: ?u64,
    rejection: ?[]const u8,
};

pub const SaveResult = struct {
    save_request_id: u64,
    disposition: SaveDisposition,
    slot: []const u8,
    generation: ?u64,
    payload_bytes: ?u64,
    detail: ?[]const u8,
};

pub const FrameDisposition = enum {
    pending,
    captured,
    failed,
    not_found,
};

pub const FrameAdmission = struct {
    admitted: bool,
    capture_id: ?u64,
    rejection: ?[]const u8,
};

pub const FrameResult = struct {
    capture_id: u64,
    disposition: FrameDisposition,
    artifact_path: ?[]const u8,
    authority_tick: ?u64,
    presentation_frame: ?u64,
    wall_unix_ms: ?i64,
    detail: ?[]const u8,
};

pub const Empty = struct {};

pub const Command = union(enum) {
    vehicle_assets: Empty,
    vehicle_inspect: struct { target: PersistentId },
    vehicle_edit: vehicle.Request,
    vehicle_result: struct { transaction_id: u64 },
    lighting_list: Empty,
    lighting_inspect: struct { target: AssetId },
    lighting_edit: lighting.Request,
    material_inspect: struct { target: AssetId },
    material_edit: material.Request,
    describe: Empty,
    schema_list: Empty,
    world_list: Empty,
    content_list: Empty,
    inspect: struct { target: Target },
    selection_set: struct { target: Target },
    selection_clear: Empty,
    camera_inspect: Empty,
    camera_set_mode: struct { mode: CameraMode },
    camera_set_pose: struct {
        position: Vec3,
        yaw_radians: f32,
        pitch_radians: f32,
    },
    camera_focus: struct { target: Target },
    crate_set_position: struct {
        target: Target,
        expected_revision: u64,
        position: Vec3,
    },
    transaction_inspect: struct { transaction_id: u64 },
    undo: struct {
        target: Target,
        expected_revision: u64,
    },
    redo: struct {
        target: Target,
        expected_revision: u64,
    },
    save_world: Empty,
    save_result: struct { save_request_id: u64 },
    capture_frame: Empty,
    frame_result: struct { capture_id: u64 },

    pub fn schemaId(self: Command) SchemaId {
        return switch (self) {
            .vehicle_assets, .vehicle_inspect, .vehicle_edit, .vehicle_result => vehicle_schema,
            .lighting_list, .lighting_inspect, .lighting_edit => lighting_schema,
            .material_inspect, .material_edit => material_schema,
            .describe, .schema_list, .world_list, .content_list, .inspect => query_schema,
            .selection_set,
            .selection_clear,
            .camera_inspect,
            .camera_set_mode,
            .camera_set_pose,
            .camera_focus,
            => editor_control_schema,
            .crate_set_position, .transaction_inspect, .undo, .redo => crate_authoring_schema,
            .save_world, .save_result => persistence_schema,
            .capture_frame, .frame_result => measurement_schema,
        };
    }
};

pub const Request = struct {
    protocol_cohort: u16 = protocol_cohort,
    expected_run_id: RunId,
    request_id: u64,
    schema_id: SchemaId,
    command: Command,

    pub fn init(expected_run_id: RunId, request_id: u64, command: Command) Request {
        return .{
            .expected_run_id = expected_run_id,
            .request_id = request_id,
            .schema_id = command.schemaId(),
            .command = command,
        };
    }

    pub fn validate(self: Request) !void {
        if (self.protocol_cohort != protocol_cohort) return error.ProtocolCohortMismatch;
        try self.expected_run_id.validate();
        if (self.request_id == 0) return error.InvalidRequestId;
        try self.schema_id.validate();
        if (!schemaIsRegistered(self.schema_id)) return error.UnknownDeveloperSchema;
        if (!std.meta.eql(self.schema_id, self.command.schemaId())) {
            return error.CommandSchemaMismatch;
        }
        switch (self.command) {
            .vehicle_assets => {},
            .vehicle_inspect => |value| try value.target.validate(),
            .vehicle_result => |value| if (value.transaction_id == 0) return error.InvalidTransactionId,
            .vehicle_edit => |value| {
                try value.target.validate();
                if (value.expected_asset_revision == 0) return error.InvalidVehicleAssetRevision;
                switch (value.action) {
                    .apply, .rebuild, .measure, .preview => |candidate| try candidate.validate(),
                    .revert, .commit, .clear_preview => {},
                }
            },
            .lighting_list => {},
            .lighting_inspect => |value| try value.target.validate(),
            .lighting_edit => |value| {
                try value.target.validate();
                if (value.expected_revision == 0) return error.InvalidLightingRevision;
            },
            .material_inspect => |value| try value.target.validate(),
            .material_edit => |value| {
                try value.target.validate();
                if (value.expected_revision == 0) return error.InvalidMaterialRevision;
            },
            .inspect => |value| try value.target.validate(),
            .selection_set => |value| try value.target.validate(),
            .camera_focus => |value| try value.target.validate(),
            .crate_set_position => |value| {
                try requirePersistentTarget(value.target);
                try validateVec3(value.position);
            },
            .transaction_inspect => |value| if (value.transaction_id == 0) {
                return error.InvalidTransactionId;
            },
            .undo => |value| try requirePersistentTarget(value.target),
            .redo => |value| try requirePersistentTarget(value.target),
            .save_result => |value| if (value.save_request_id == 0) {
                return error.InvalidSaveRequestId;
            },
            .frame_result => |value| if (value.capture_id == 0) {
                return error.InvalidCaptureId;
            },
            .camera_set_pose => |value| {
                try validateVec3(value.position);
                if (!std.math.isFinite(value.yaw_radians) or
                    !std.math.isFinite(value.pitch_radians))
                {
                    return error.InvalidCameraPose;
                }
            },
            else => {},
        }
    }
};

fn requirePersistentTarget(target: Target) !void {
    try target.validate();
    if (target != .persistent_entity) return error.PersistentTargetRequired;
}

fn validateVec3(value: Vec3) !void {
    for (value) |component| {
        if (!std.math.isFinite(component)) return error.NonFiniteVector;
    }
}

pub const EndpointDescription = struct {
    product: []const u8,
    local_only: bool,
    transport: []const u8,
    protocol_cohort: u16,
    framing_version: u16,
    run_id: RunId,
    schema_digest: engine.assets.Digest,
    capabilities: []const []const u8,
};

pub const SelectionResult = struct {
    selected: ?Target,
};

pub const Payload = union(enum) {
    vehicle_assets: []const vehicle.AssetSummary,
    vehicle_inspection: vehicle.Inspection,
    vehicle_outcome: vehicle.Result,
    lighting_list: lighting.View,
    lighting_inspection: lighting.Record,
    lighting_outcome: lighting.Outcome,
    material_inspection: material.Inspection,
    material_outcome: material.Outcome,
    endpoint_description: EndpointDescription,
    schema_list: []const SchemaDescriptor,
    world_list: []const WorldEntry,
    content_list: []const ContentEntry,
    inspection: Inspection,
    selection: SelectionResult,
    camera: CameraState,
    camera_mutation: CameraState,
    authoring_admission: AuthoringAdmission,
    transaction: TransactionInspection,
    save_admission: SaveAdmission,
    save_result: SaveResult,
    frame_admission: FrameAdmission,
    frame_result: FrameResult,

    pub fn schemaId(self: Payload) SchemaId {
        return switch (self) {
            .vehicle_assets, .vehicle_inspection, .vehicle_outcome => vehicle_schema,
            .lighting_list, .lighting_inspection, .lighting_outcome => lighting_schema,
            .material_inspection, .material_outcome => material_schema,
            .endpoint_description, .schema_list, .world_list, .content_list, .inspection => query_schema,
            .selection, .camera, .camera_mutation => editor_control_schema,
            .authoring_admission, .transaction => crate_authoring_schema,
            .save_admission, .save_result => persistence_schema,
            .frame_admission, .frame_result => measurement_schema,
        };
    }
};

pub const FailureCode = enum {
    malformed_frame,
    malformed_json,
    unknown_protocol_cohort,
    unknown_schema,
    command_schema_mismatch,
    invalid_request,
    run_mismatch,
    endpoint_stopping,
    owner_busy,
    owner_unavailable,
    target_not_found,
    target_kind_not_supported,
    internal_error,
};

pub const Failure = struct {
    code: FailureCode,
    detail: []const u8,
};

pub const ResponseOutcome = union(enum) {
    success: Payload,
    failure: Failure,
};

pub const Response = struct {
    protocol_cohort: u16 = protocol_cohort,
    request_id: u64,
    schema_id: SchemaId,
    run_id: RunId,
    outcome: ResponseOutcome,

    pub fn validate(self: Response) !void {
        if (self.protocol_cohort != protocol_cohort) return error.ProtocolCohortMismatch;
        if (self.request_id == 0) return error.InvalidRequestId;
        try self.schema_id.validate();
        if (!schemaIsRegistered(self.schema_id)) return error.UnknownDeveloperSchema;
        try self.run_id.validate();
        switch (self.outcome) {
            .success => |payload| if (!std.meta.eql(payload.schemaId(), self.schema_id)) {
                return error.ResponseSchemaMismatch;
            },
            .failure => {},
        }
    }
};

pub fn expectedPayloadTag(command: Command) std.meta.Tag(Payload) {
    return switch (command) {
        .vehicle_assets => .vehicle_assets,
        .vehicle_inspect => .vehicle_inspection,
        .vehicle_edit, .vehicle_result => .vehicle_outcome,
        .lighting_list => .lighting_list,
        .lighting_inspect => .lighting_inspection,
        .lighting_edit => .lighting_outcome,
        .material_inspect => .material_inspection,
        .material_edit => .material_outcome,
        .describe => .endpoint_description,
        .schema_list => .schema_list,
        .world_list => .world_list,
        .content_list => .content_list,
        .inspect => .inspection,
        .selection_set, .selection_clear => .selection,
        .camera_inspect => .camera,
        .camera_set_mode, .camera_set_pose, .camera_focus => .camera_mutation,
        .crate_set_position, .undo, .redo => .authoring_admission,
        .transaction_inspect => .transaction,
        .save_world => .save_admission,
        .save_result => .save_result,
        .capture_frame => .frame_admission,
        .frame_result => .frame_result,
    };
}

/// Validate the complete exchange, not only its broad schema family. Query and
/// editor schemas intentionally contain several operations, so schema equality
/// alone cannot prove that a response belongs to the requested command.
pub fn validateResponseForRequest(request: Request, response: Response) !void {
    try request.validate();
    try response.validate();
    if (request.request_id != response.request_id) return error.ResponseRequestMismatch;
    if (!std.meta.eql(request.schema_id, response.schema_id)) {
        return error.ResponseSchemaMismatch;
    }
    if (!std.meta.eql(request.expected_run_id, response.run_id)) {
        return error.DeveloperRunMismatch;
    }
    switch (response.outcome) {
        .success => |payload| if (std.meta.activeTag(payload) != expectedPayloadTag(request.command)) {
            return error.ResponsePayloadMismatch;
        },
        .failure => {},
    }
}

pub const FrameKind = enum(u8) {
    request = 1,
    response = 2,
};

pub const Header = struct {
    kind: FrameKind,
    protocol_cohort: u16,
    request_id: u64,
    payload_len: u64,
    payload_checksum: u32,

    pub fn init(kind: FrameKind, cohort: u16, request_id: u64, payload: []const u8) Header {
        return .{
            .kind = kind,
            .protocol_cohort = cohort,
            .request_id = request_id,
            .payload_len = payload.len,
            .payload_checksum = std.hash.crc.Crc32.hash(payload),
        };
    }

    pub fn encode(self: Header) [frame_header_bytes]u8 {
        var bytes: [frame_header_bytes]u8 = @splat(0);
        @memcpy(bytes[0..4], &frame_magic);
        std.mem.writeInt(u16, bytes[4..6], framing_version, .big);
        bytes[6] = @intFromEnum(self.kind);
        bytes[7] = 0; // flags; none are defined in cohort 1.
        std.mem.writeInt(u16, bytes[8..10], self.protocol_cohort, .big);
        // bytes 10..12 are reserved and must remain zero.
        std.mem.writeInt(u64, bytes[12..20], self.request_id, .big);
        std.mem.writeInt(u64, bytes[20..28], self.payload_len, .big);
        std.mem.writeInt(u32, bytes[28..32], self.payload_checksum, .big);
        return bytes;
    }

    pub fn decode(bytes: *const [frame_header_bytes]u8) !Header {
        if (!std.mem.eql(u8, bytes[0..4], &frame_magic)) return error.InvalidFrameMagic;
        if (std.mem.readInt(u16, bytes[4..6], .big) != framing_version) {
            return error.UnknownFramingVersion;
        }
        const kind = std.enums.fromInt(FrameKind, bytes[6]) orelse
            return error.InvalidFrameKind;
        if (bytes[7] != 0 or bytes[10] != 0 or bytes[11] != 0) {
            return error.UnsupportedFrameFlags;
        }
        const cohort = std.mem.readInt(u16, bytes[8..10], .big);
        if (cohort == 0) return error.InvalidProtocolCohort;
        const request_id = std.mem.readInt(u64, bytes[12..20], .big);
        if (request_id == 0) return error.InvalidRequestId;
        return .{
            .kind = kind,
            .protocol_cohort = cohort,
            .request_id = request_id,
            .payload_len = std.mem.readInt(u64, bytes[20..28], .big),
            .payload_checksum = std.mem.readInt(u32, bytes[28..32], .big),
        };
    }

    pub fn validatePayload(self: Header, payload: []const u8) !void {
        if (self.payload_len != payload.len) return error.FrameLengthMismatch;
        if (self.payload_checksum != std.hash.crc.Crc32.hash(payload)) {
            return error.FrameChecksumMismatch;
        }
    }
};

pub const Frame = struct {
    header: Header,
    payload: []u8,

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        self.* = undefined;
    }
};

pub fn writeFrame(
    writer: *std.Io.Writer,
    kind: FrameKind,
    cohort: u16,
    request_id: u64,
    payload: []const u8,
) !void {
    if (payload.len > maxPayloadBytes(kind)) return error.FramePayloadTooLarge;
    const header = Header.init(kind, cohort, request_id, payload).encode();
    try writer.writeAll(&header);
    try writer.writeAll(payload);
    try writer.flush();
}

pub fn readFrameAlloc(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Frame {
    const header = try readHeader(reader);
    const payload = try readPayloadAlloc(allocator, reader, header);
    return .{ .header = header, .payload = payload };
}

pub fn readHeader(reader: *std.Io.Reader) !Header {
    var encoded_header: [frame_header_bytes]u8 = undefined;
    try reader.readSliceAll(&encoded_header);
    return Header.decode(&encoded_header);
}

pub fn readPayloadAlloc(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    header: Header,
) ![]u8 {
    const payload_len = std.math.cast(usize, header.payload_len) orelse
        return error.FrameLengthNotRepresentable;
    if (payload_len > maxPayloadBytes(header.kind)) return error.FramePayloadTooLarge;
    const payload = try allocator.alloc(u8, payload_len);
    errdefer allocator.free(payload);
    try reader.readSliceAll(payload);
    try header.validatePayload(payload);
    return payload;
}

pub fn encodeRequestAlloc(allocator: std.mem.Allocator, request: Request) ![]u8 {
    try request.validate();
    return std.json.Stringify.valueAlloc(allocator, request, .{});
}

pub fn parseRequest(allocator: std.mem.Allocator, payload: []const u8) !std.json.Parsed(Request) {
    var parsed = try parseRequestSyntax(allocator, payload);
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}

pub fn parseRequestSyntax(
    allocator: std.mem.Allocator,
    payload: []const u8,
) !std.json.Parsed(Request) {
    const parsed = try std.json.parseFromSlice(
        Request,
        allocator,
        payload,
        .{ .allocate = .alloc_always },
    );
    return parsed;
}

pub fn encodeResponseAlloc(allocator: std.mem.Allocator, response: Response) ![]u8 {
    try response.validate();
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn parseResponse(allocator: std.mem.Allocator, payload: []const u8) !std.json.Parsed(Response) {
    var parsed = try std.json.parseFromSlice(
        Response,
        allocator,
        payload,
        .{ .allocate = .alloc_always },
    );
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}

test "manual schema catalog has stable classes and digest" {
    try std.testing.expectEqual(@as(usize, 8), schemaCatalog().len);
    var seen: [std.meta.tags(SchemaClass).len]bool = @splat(false);
    for (schemaCatalog()) |schema| {
        try schema.id.validate();
        try std.testing.expect(schemaIsRegistered(schema.id));
        try std.testing.expect(schema.wire_shape_signature.len != 0);
        seen[@intFromEnum(schema.class)] = true;
    }
    for (seen) |present| try std.testing.expect(present);
    const digest = schemaDigest();
    try engine.assets.validateDigest(digest);
    try std.testing.expectEqualSlices(u8, &canonical_schema_digest_v6, &digest);
}

test "discovery lifecycle documents require active paths and available digest" {
    var ids: [registered_schemas.len]SchemaId = undefined;
    for (registered_schemas, 0..) |schema, index| ids[index] = schema.id;
    const run_id = RunId{ .started_wall_unix_ms = 1, .nonce = 2 };

    try (DiscoveryDocument{
        .lifecycle = .disabled,
        .run_id = run_id,
        .schema_ids = &ids,
    }).validate();
    try (DiscoveryDocument{
        .lifecycle = .declared,
        .run_id = run_id,
        .schema_ids = &ids,
    }).validate();
    try (DiscoveryDocument{
        .lifecycle = .starting,
        .run_id = run_id,
        .endpoint_path = "/tmp/incinerator-starting.sock",
        .schema_ids = &ids,
    }).validate();
    try (DiscoveryDocument{
        .lifecycle = .available,
        .run_id = run_id,
        .endpoint_path = "/tmp/incinerator-available.sock",
        .schema_ids = &ids,
        .schema_digest = schemaDigest(),
    }).validate();
    try (DiscoveryDocument{
        .lifecycle = .stopping,
        .run_id = run_id,
        .endpoint_path = "/tmp/incinerator-stopping.sock",
        .schema_ids = &ids,
    }).validate();
    try (DiscoveryDocument{
        .lifecycle = .stopped,
        .run_id = run_id,
        .schema_ids = &ids,
    }).validate();
    try (DiscoveryDocument{
        .lifecycle = .failed,
        .run_id = run_id,
        .schema_ids = &ids,
        .failure = "listener unavailable",
    }).validate();

    try std.testing.expectError(error.ActiveEndpointPathMissing, (DiscoveryDocument{
        .lifecycle = .starting,
        .run_id = run_id,
        .schema_ids = &ids,
    }).validate());
    try std.testing.expectError(error.AvailableSchemaDigestMissing, (DiscoveryDocument{
        .lifecycle = .available,
        .run_id = run_id,
        .endpoint_path = "/tmp/incinerator-available.sock",
        .schema_ids = &ids,
    }).validate());
    try std.testing.expectError(error.InactiveEndpointPathPresent, (DiscoveryDocument{
        .lifecycle = .stopped,
        .run_id = run_id,
        .endpoint_path = "/tmp/incinerator-stale.sock",
        .schema_ids = &ids,
    }).validate());
    try std.testing.expectError(error.InactiveSchemaDigestPresent, (DiscoveryDocument{
        .lifecycle = .declared,
        .run_id = run_id,
        .schema_ids = &ids,
        .schema_digest = schemaDigest(),
    }).validate());
    try std.testing.expectError(error.EndpointFailureMissing, (DiscoveryDocument{
        .lifecycle = .failed,
        .run_id = run_id,
        .schema_ids = &ids,
    }).validate());
    try std.testing.expectError(error.EndpointFailureMissing, (DiscoveryDocument{
        .lifecycle = .failed,
        .run_id = run_id,
        .schema_ids = &ids,
        .failure = "",
    }).validate());
    try std.testing.expectError(error.UnexpectedEndpointFailure, (DiscoveryDocument{
        .lifecycle = .available,
        .run_id = run_id,
        .endpoint_path = "/tmp/incinerator-available.sock",
        .schema_ids = &ids,
        .schema_digest = schemaDigest(),
        .failure = "stale failure",
    }).validate());
}

test "request schema is derived from its concrete command" {
    const request = Request.init(.{ .started_wall_unix_ms = 1, .nonce = 2 }, 9, .{ .crate_set_position = .{
        .target = .{ .persistent_entity = .{ .namespace = 1, .local = 4 } },
        .expected_revision = 7,
        .position = .{ 3, 1, -5 },
    } });
    try request.validate();
    try std.testing.expectEqual(crate_authoring_schema, request.schema_id);

    var mismatched = request;
    mismatched.schema_id = query_schema;
    try std.testing.expectError(error.CommandSchemaMismatch, mismatched.validate());
}

test "request JSON round trips tagged concrete operation" {
    const request = Request.init(.{ .started_wall_unix_ms = 1, .nonce = 2 }, 41, .{ .camera_set_pose = .{
        .position = .{ 1.25, -2, 9 },
        .yaw_radians = 0.5,
        .pitch_radians = -0.25,
    } });
    const json = try encodeRequestAlloc(std.testing.allocator, request);
    defer std.testing.allocator.free(json);
    var parsed = try parseRequest(std.testing.allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 41), parsed.value.request_id);
    try std.testing.expectEqual(CameraMode.free_camera, CameraMode.free_camera);
    try std.testing.expectEqual(@as(f32, 1.25), parsed.value.command.camera_set_pose.position[0]);
}

test "response correlation includes run and concrete payload variant" {
    const run_id = RunId{ .started_wall_unix_ms = 1, .nonce = 2 };
    const request = Request.init(run_id, 41, .{ .world_list = .{} });
    const valid = Response{
        .request_id = 41,
        .schema_id = query_schema,
        .run_id = run_id,
        .outcome = .{ .success = .{ .world_list = &.{} } },
    };
    try validateResponseForRequest(request, valid);

    var wrong_run = valid;
    wrong_run.run_id.nonce = 3;
    try std.testing.expectError(
        error.DeveloperRunMismatch,
        validateResponseForRequest(request, wrong_run),
    );

    var wrong_payload = valid;
    wrong_payload.outcome = .{ .success = .{ .content_list = &.{} } };
    try std.testing.expectError(
        error.ResponsePayloadMismatch,
        validateResponseForRequest(request, wrong_payload),
    );
}

test "response JSON preserves run correlation and concrete payload" {
    const response = Response{
        .request_id = 41,
        .schema_id = editor_control_schema,
        .run_id = .{ .started_wall_unix_ms = 1, .nonce = 2 },
        .outcome = .{ .success = .{ .camera = .{
            .mode = .free_camera,
            .free_camera_initialized = true,
            .position = .{ 1, 2, 3 },
            .yaw_radians = 0.5,
            .pitch_radians = -0.25,
            .move_speed_meters_per_second = 5,
            .last_focus = null,
        } } },
    };
    const json = try encodeResponseAlloc(std.testing.allocator, response);
    defer std.testing.allocator.free(json);
    var parsed = try parseResponse(std.testing.allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 41), parsed.value.request_id);
    try std.testing.expectEqual(
        CameraMode.free_camera,
        parsed.value.outcome.success.camera.mode,
    );
    try std.testing.expectEqual(@as(f32, 3), parsed.value.outcome.success.camera.position[2]);
}

test "ICDV header is exactly 32 bytes and rejects corruption" {
    const payload = "{\"request\":true}";
    const original = Header.init(.request, protocol_cohort, 77, payload);
    const encoded = original.encode();
    try std.testing.expectEqual(@as(usize, 32), encoded.len);
    const decoded = try Header.decode(&encoded);
    try std.testing.expectEqual(FrameKind.request, decoded.kind);
    try std.testing.expectEqual(@as(u64, 77), decoded.request_id);
    try decoded.validatePayload(payload);

    var corrupt_payload = payload.*;
    corrupt_payload[2] = 'X';
    try std.testing.expectError(
        error.FrameChecksumMismatch,
        decoded.validatePayload(&corrupt_payload),
    );

    var corrupt_header = encoded;
    corrupt_header[0] = 'x';
    try std.testing.expectError(error.InvalidFrameMagic, Header.decode(&corrupt_header));
    corrupt_header = encoded;
    corrupt_header[7] = 1;
    try std.testing.expectError(error.UnsupportedFrameFlags, Header.decode(&corrupt_header));
}

test "framed vehicle values are not constrained by the old four KiB fixture" {
    const payload = try std.testing.allocator.alloc(u8, 16 * 1024);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');
    var reader = std.Io.Reader.fixed(payload);
    const header = Header.init(.request, protocol_cohort, 78, payload);
    const decoded = try readPayloadAlloc(std.testing.allocator, &reader, header);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, payload, decoded);
}

test "stable target parser rejects backend-shaped ambiguity" {
    try (Target{ .persistent_entity = .{ .namespace = 1, .local = 4 } }).validate();
    try std.testing.expectError(
        error.PersistentTargetRequired,
        requirePersistentTarget(.{ .content_asset = .{ .namespace = 1, .local = 4 } }),
    );
}

test "protocol public surface compiles" {
    std.testing.refAllDecls(@This());
}
