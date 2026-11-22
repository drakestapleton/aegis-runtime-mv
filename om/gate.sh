#!/bin/sh
set -eu
OMC="${OMC:-/home/drakestapleton/canon/omega-mv/seed/out/omc}"
[ -x "$OMC" ] || { echo "NOT_RUN: set OMC to seed/out/omc"; exit 3; }
SCR=$(mktemp -d)
trap "rm -rf $SCR" EXIT

build_det() {
  name=$1; shift
  cat "$@" > "$SCR/$name.om"
  "$OMC" < "$SCR/$name.om" > "$SCR/$name.1" 2> "$SCR/$name.err" || { echo "FAIL compile $name"; cat "$SCR/$name.err"; exit 1; }
  "$OMC" < "$SCR/$name.om" > "$SCR/$name.2" 2>> "$SCR/$name.err" || { echo "FAIL compile2 $name"; exit 1; }
  cmp -s "$SCR/$name.1" "$SCR/$name.2" || { echo "FAIL nondeterministic $name"; exit 1; }
  chmod +x "$SCR/$name.1"
  echo "BUILD_OK $name bytes=$(wc -c < "$SCR/$name.1") sha256=$(sha256sum "$SCR/$name.1" | awk "{print \$1}")"
}

build_det aegis_test om/om2.om om/sha2.om om/dag.om om/heartbeat.om om/policy.om om/journal.om om/gateway.om om/test.om
"$SCR/aegis_test.1"

build_det aegis_main om/om2.om om/sha2.om om/dag.om om/heartbeat.om om/policy.om om/journal.om om/gateway.om om/main.om
printf "INIT 4 10 5\nTOKEN aegis_operator_secret_token_012345\nREQ GET /health -\nVERIFY\nQUIT\n" | "$SCR/aegis_main.1"

# Planted mutant control: weaken unconfigured-token refusal -> aegis_test MUST fail
sed "s/ret POL_DENY_NO_TOKEN/ret POL_ALLOW/" om/policy.om > "$SCR/policy_mut.om"
cat om/om2.om om/sha2.om om/dag.om om/heartbeat.om "$SCR/policy_mut.om" om/journal.om om/gateway.om om/test.om > "$SCR/mut.om"
"$OMC" < "$SCR/mut.om" > "$SCR/mut.bin" && chmod +x "$SCR/mut.bin"
if "$SCR/mut.bin" >/dev/null 2>&1; then
  echo "FAIL mutant escaped"
  exit 1
fi
echo "MUTANT_CAUGHT policy_bypass_refused"
echo "AEGIS-OM-GATE PASS"
