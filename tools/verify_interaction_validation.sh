#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
design="$root/docs/design/gameplay-interaction-validation-and-observability.md"
evidence="$root/docs/validation/gameplay-interaction-validation-and-observability.md"
adr="$root/docs/adr/020-gameplay-interaction-validation-and-observability.md"

fail() {
  echo "interaction validation audit failure: $*" >&2
  exit 1
}

for required in "$design" "$evidence" "$adr"; do
  test -f "$required" || fail "missing ${required#"$root/"}"
done

grep -Fqx '**Status:** Accepted' "$adr" || fail "ADR-020 is not accepted"
grep -Fqx '**Status:** Complete' "$design" || fail "design is not complete"
grep -Fqx '**Status:** Accepted' "$evidence" || fail "evidence ledger is not accepted"
test "$(grep -Ec '^- \[x\]' "$design")" -ge 30 ||
  fail "phase acceptance checklist is incomplete"
if grep -Eq '^- \[ \]' "$design"; then
  fail "unchecked phase work remains in the design"
fi
if grep -Eq '\| IV[0-5].*\| (Pending|In progress)' "$evidence"; then
  fail "phase ledger still contains pending work"
fi
grep -Fq '| Human trace corrective | Accepted 2026-07-15 |' "$evidence" ||
  fail "human-trace corrective is not accepted"

grep -Fq 'src/sandbox/gameplay_scenarios.zig' "$evidence" ||
  fail "shared scenario owner is not recorded"
grep -Fq 'tools/interaction_validation.zig' "$evidence" ||
  fail "fault/fuzz/soak owner is not recorded"
grep -Fq 'src/visibility_oracle.zig' "$evidence" ||
  fail "Metal oracle owner is not recorded"
grep -Fq 'src/sandbox/product_presentation_trace.zig' "$evidence" ||
  fail "normal-product presentation trace owner is not recorded"
grep -Fq 'Gameplay trace schema 2' "$evidence" ||
  fail "typed reason-domain trace amendment is not recorded"
grep -Fq 'transport ingress budget' "$evidence" ||
  fail "graphical catch-up backpressure correction is not recorded"
grep -Fq "primitive pipeline ignored the \`base_color\`" "$evidence" ||
  fail "product/oracle renderer mismatch is not recorded"
grep -Fq 'at least 64 depth-tested' "$evidence" ||
  fail "meaningful death-visibility threshold is not recorded"
grep -Fq 'protocol revision 13' "$evidence" ||
  fail "lifecycle ordering protocol change is not recorded"
grep -Fq 'zig build verify-interactions' "$evidence" ||
  fail "aggregate gate is not recorded"

grep -Fq 'const gameplay_scenarios = @import("sandbox_gameplay_scenarios");' \
  "$root/src/sandbox_controls.zig" || fail "solo adapter does not use the shared scenario catalog"
grep -Fq 'const gameplay_scenarios = @import("sandbox_gameplay_scenarios");' \
  "$root/src/hosts/mp2_client.zig" || fail "network client does not use the shared scenario catalog"
grep -Fq 'const gameplay_scenarios = @import("sandbox_gameplay_scenarios");' \
  "$root/src/hosts/mp6_listen_client.zig" || fail "listen client does not use the shared scenario catalog"
grep -Fq 'network_options.addOption(u16, "protocol_revision", 13);' \
  "$root/tools/build/simulation_graph.zig" || fail "wire cohort was not bumped for lifecycle ordering"
grep -Fq 'PrimitiveFragmentSettings' "$root/shaders/triangle.frag" ||
  fail "primitive material tint shader contract is missing"
grep -Fq 'minimum_meaningful_pixels: u32 = 64' "$root/src/visibility_oracle.zig" ||
  fail "meaningful visibility threshold is missing"

echo "INTERACTION_VALIDATION_AUDIT_PASS phases=6 human_trace=accepted docs=why-design-evidence scenario_catalog=shared fault_runner=seeded protocol=13 renderer_tint=reflected"
