// Incinerator's narrow adapter extensions for pinned Jolt 23dadd0e.
#pragma once
#include "joltc.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct IC_VehiclePowertrainState {
    float engine_rpm;
    int32_t gear;
    float clutch_friction;
    float switch_time_left_s;
    float clutch_release_left_s;
    float switch_latency_left_s;
} IC_VehiclePowertrainState;
bool IC_Vehicle_GetPowertrainState(const JPH_WheeledVehicleController *controller, IC_VehiclePowertrainState *state);
bool IC_Vehicle_SetPowertrainState(JPH_WheeledVehicleController *controller, const IC_VehiclePowertrainState *state);
bool IC_Vehicle_SetEngineCoefficients(JPH_WheeledVehicleController *controller, float max_torque, float idle_rpm, float max_rpm, float inertia, float damping);
void IC_Vehicle_GetWheelSlip(const JPH_Wheel *wheel, float *longitudinal, float *lateral_radians);
float IC_Vehicle_GetCenterLimitedSlipRatio(const JPH_WheeledVehicleController *controller);
uint32_t IC_Vehicle_GetDifferentialCount(const JPH_WheeledVehicleController *controller);
int32_t IC_Vehicle_GetDifferentialLeftWheel(const JPH_WheeledVehicleController *controller, uint32_t index);
void IC_Vehicle_SetCombinedTireResponse(JPH_WheeledVehicleController *controller, const float *longitudinal_slide_slip, const float *lateral_slide_angle);
void IC_Vehicle_GetTireImpulseLimits(const JPH_WheeledVehicleController *controller, uint32_t wheel, float longitudinal_slip, float lateral_slip, float *longitudinal, float *lateral);
#ifdef __cplusplus
}
#endif
