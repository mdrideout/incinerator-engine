// Only public Jolt APIs are used here; immutable WheelSettings stay immutable.
#include <Jolt/Jolt.h>
#include <Jolt/Physics/Vehicle/WheeledVehicleController.h>
#include <Jolt/Physics/StateRecorder.h>
#include "vehicle_bridge.h"
#include <cmath>
#include <cstring>
#include <array>

namespace {
// The pinned transmission's public SaveState/RestoreState serializes exactly
// these five named logical values, in this order. Map each scalar explicitly;
// no contact, constraint, body or solver snapshot crosses the engine boundary.
class TransmissionState final : public JPH::StateRecorder {
    IC_VehiclePowertrainState &state;
    unsigned field = 0;
    bool failed = false;
    void *next(size_t size) {
        if (size != sizeof(float)) { failed = true; return nullptr; }
        switch (field++) {
            case 0: return &state.gear;
            case 1: return &state.clutch_friction;
            case 2: return &state.switch_time_left_s;
            case 3: return &state.clutch_release_left_s;
            case 4: return &state.switch_latency_left_s;
            default: failed = true; return nullptr;
        }
    }
public:
    explicit TransmissionState(IC_VehiclePowertrainState &value) : state(value) {}
    void WriteBytes(const void *data, size_t size) override { if (void *slot = next(size)) std::memcpy(slot, data, size); }
    void ReadBytes(void *data, size_t size) override { if (void *slot = next(size)) std::memcpy(data, slot, size); }
    bool IsFailed() const override { return failed; }
    bool IsEOF() const override { return failed; }
    bool complete() const { return !failed && field == 5; }
};
static_assert(sizeof(int) == sizeof(int32_t) && sizeof(float) == sizeof(int32_t));
bool nonnegative(float value) { return std::isfinite(value) && value >= 0; }
}

bool IC_Vehicle_GetPowertrainState(const JPH_WheeledVehicleController *raw, IC_VehiclePowertrainState *state) {
    const auto &controller = *reinterpret_cast<const JPH::WheeledVehicleController *>(raw);
    state->engine_rpm = controller.GetEngine().GetCurrentRPM();
    TransmissionState stream(*state);
    controller.GetTransmission().SaveState(stream);
    return stream.complete();
}

bool IC_Vehicle_SetPowertrainState(JPH_WheeledVehicleController *raw, const IC_VehiclePowertrainState *state) {
    auto &controller = *reinterpret_cast<JPH::WheeledVehicleController *>(raw);
    auto &engine = controller.GetEngine();
    auto &transmission = controller.GetTransmission();
    if (!std::isfinite(state->engine_rpm) || state->engine_rpm < engine.mMinRPM || state->engine_rpm > engine.mMaxRPM ||
        state->gear > int64_t(transmission.mGearRatios.size()) || -int64_t(state->gear) > int64_t(transmission.mReverseGearRatios.size()) ||
        !nonnegative(state->clutch_friction) || state->clutch_friction > 1 ||
        !nonnegative(state->switch_time_left_s) || !nonnegative(state->clutch_release_left_s) || !nonnegative(state->switch_latency_left_s)) return false;
    // Only logical state enters RestoreState, after compatibility validation.
    auto copy = *state;
    TransmissionState stream(copy);
    transmission.RestoreState(stream);
    engine.SetCurrentRPM(state->engine_rpm);
    return stream.complete();
}

bool IC_Vehicle_SetEngineCoefficients(JPH_WheeledVehicleController *raw, float torque, float idle, float maximum, float inertia, float damping) {
    auto &engine = reinterpret_cast<JPH::WheeledVehicleController *>(raw)->GetEngine();
    if (!std::isfinite(torque) || torque <= 0 || !std::isfinite(idle) || idle <= 0 || !std::isfinite(maximum) || maximum <= idle ||
        !std::isfinite(inertia) || inertia <= 0 || !nonnegative(damping) || engine.GetCurrentRPM() < idle || engine.GetCurrentRPM() > maximum) return false;
    engine.mMaxTorque = torque;
    engine.mMinRPM = idle;
    engine.mMaxRPM = maximum;
    engine.mInertia = inertia;
    engine.mAngularDamping = damping;
    return true;
}

void IC_Vehicle_GetWheelSlip(const JPH_Wheel *raw, float *longitudinal, float *lateral) {
    const auto &wheel = *reinterpret_cast<const JPH::WheelWV *>(raw);
    *longitudinal = wheel.mLongitudinalSlip;
    *lateral = wheel.mLateralSlip;
}
uint32_t IC_Vehicle_GetDifferentialCount(const JPH_WheeledVehicleController *raw) {
    return static_cast<uint32_t>(reinterpret_cast<const JPH::WheeledVehicleController *>(raw)->GetDifferentials().size());
}
int32_t IC_Vehicle_GetDifferentialLeftWheel(const JPH_WheeledVehicleController *raw, uint32_t index) {
    return reinterpret_cast<const JPH::WheeledVehicleController *>(raw)->GetDifferentials().at(index).mLeftWheel;
}

void IC_Vehicle_SetCombinedTireResponse(JPH_WheeledVehicleController *raw, const float *longitudinal_slide, const float *lateral_slide) {
    std::array<float, 4> longitudinal, lateral;
    for (unsigned i = 0; i < 4; ++i) {
        longitudinal[i] = longitudinal_slide[i];
        lateral[i] = std::tan(lateral_slide[i]);
    }
    reinterpret_cast<JPH::WheeledVehicleController *>(raw)->SetTireMaxImpulseCallback(
        [longitudinal, lateral](JPH::uint wheel, float &out_long, float &out_lat,
            float load, float mu_long, float mu_lat, float slip_long, float slip_lat, float) {
            // Smooth combined-slip attenuation, normalized by the authored
            // sliding-curve coordinates. Pure-axis response is preserved; slip on one
            // axis reduces capacity on the other. The smooth denominator keeps
            // rolling contact continuous around zero slip in every heading.
            const float x = std::abs(slip_long) / longitudinal[wheel];
            const float y = std::abs(std::tan(slip_lat)) / lateral[wheel];
            out_long = mu_long * load / std::hypot(1.0f, y);
            out_lat = mu_lat * load / std::hypot(1.0f, x);
        });
}

void IC_Vehicle_GetTireImpulseLimits(const JPH_WheeledVehicleController *raw, uint32_t wheel,
    float slip_long, float slip_lat, float *longitudinal, float *lateral) {
    reinterpret_cast<const JPH::WheeledVehicleController *>(raw)->GetTireMaxImpulseCallback()(
        wheel, *longitudinal, *lateral, 1.0f, 1.0f, 1.0f, slip_long, slip_lat, 1.0f / 60.0f);
}

extern "C" float IC_Vehicle_GetCenterLimitedSlipRatio(const JPH_WheeledVehicleController *controller) {
    return reinterpret_cast<const JPH::WheeledVehicleController *>(controller)->GetDifferentialLimitedSlipRatio();
}
