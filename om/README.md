# Pure-Omega AEGIS Agent Gateway Runtime (aegis-runtime-mv)

Seeded Omega (.om) implementation of the AEGIS DAG orchestrator, lease/heartbeat manager, fail-closed policy guard, SHA-256 hash-chained journal, and control-plane gateway router (synced from omega-mv core/aegis/ at f840a6ee9a835e22836609391176596fa911be70, seed/out/omc sha256 708fdc0f81866594ed6df2f492b7a8a6bc7456f2d733a838b7f840549ebba6c3).

- Gate: `OMC=/path/to/seed/out/omc sh om/gate.sh` (two-pass deterministic compile, full behavioral + negative test suite, live CLI smoke, and planted policy-bypass mutant refusal).
