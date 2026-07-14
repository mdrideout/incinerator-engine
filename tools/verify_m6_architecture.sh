#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
authority="$root/src/session/authority.zig"
protocol="$root/src/session/protocol.zig"
client="$root/src/session/client.zig"
snapshot_source="$root/src/session/snapshot_source.zig"
local_solo="$root/src/session/local_solo.zig"
server="$root/src/hosts/mp2_server.zig"

fail() {
  echo "M6 architecture failure: $*" >&2
  exit 1
}

require() {
  local description="$1"
  local pattern="$2"
  local source="$3"
  rg -U -q -- "$pattern" "$source" || fail "$description"
}

reject() {
  local description="$1"
  local pattern="$2"
  shift 2
  if rg -n --glob '*.zig' -- "$pattern" "$@"; then
    fail "$description"
  fi
}

require "authority ingress is not class-reserved" \
  'const IngressMailbox = struct[\s\S]*control:[\s\S]*gameplay:[\s\S]*input:[\s\S]*notice:' \
  "$authority"
require "authority does not freeze an ordered cycle prefix" \
  'fn freeze[\s\S]*popOldest' "$authority"
require "authority does not execute the complete eight-stage cycle" \
  'ingress_freeze[\s\S]*admission[\s\S]*semantic_work[\s\S]*simulation[\s\S]*outcome_drain[\s\S]*derivative_preparation[\s\S]*durable_disposition[\s\S]*publication' \
  "$authority"
require "publication metadata is not double-buffered with prepared output" \
  'fn stagePublicationMetadata[\s\S]*prepared_participants[\s\S]*prepared_replication' \
  "$authority"
require "publication failure cannot roll back unpublished metadata" \
  'fn rollbackPublicationMetadata' "$authority"
require "authority egress lacks a generational lease" \
  'pub const OutboundLease[\s\S]*generation' "$authority"
require "dedicated adapter does not commit only after GNS acceptance" \
  'self\.network\.send[\s\S]*commitOutboundLease' "$server"
require "embedded adapter does not consume authority output through a lease" \
  'beginOutboundLease\(\)' "$local_solo"
require "wire protocol lacks application delivery receipts" \
  'pub const DeliveryReceipt[\s\S]*delivery_id' "$protocol"
require "client lacks delivered-message deduplication" \
  'pub fn receiveDelivered[\s\S]*duplicate' "$client"
require "authority lacks bounded reconnect replay" \
  'fn prepareReliableReplay' "$authority"
require "durable capture is not a queued request/result port" \
  'pub fn request[\s\S]*pub fn take[\s\S]*pub fn release' "$snapshot_source"

reject "legacy pop-before-send authority API remains" \
  'pub fn pollOutbound|fn pollOutbound' "$root/src" "$root/tools"
reject "legacy direct admission clock mutation remains" \
  'updateAdmissionTime' "$authority"
reject "durable commit still exposes synchronous capture" \
  'pub fn capture' "$snapshot_source"

echo "M6_ARCHITECTURE_PASS ingress=class_reserved cycle=eight_stage publication=double_buffered delivery=leased receipts=cumulative replay=bounded durable=stage_seven"
