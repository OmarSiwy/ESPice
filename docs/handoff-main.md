# Handoff: main-session state (2026-09-23)

## Branches
- `main`: frontend simplification merged (--no-ff), not pushed. `zig build test` was green
  on the agent's branch (297/297; fixtures 518/616, same 98 failures as bcc13b3).
- `ci/release-matrix`: release workflow + `-Dcuda-arch`/`-Dhip-arch` + no-backend gpu.zig
  fix + no LLD on macOS. Verified locally; the workflow itself has never run on GitHub.
- `wip/numeric-ref-node` (this branch): UNVERIFIED fix for `v(out, 2)` treating a numeric
  reference node as ground (`directiveNodeName` in src/frontend/prepare.zig now goes through
  `nodeNameOf`), plus a regression assertion in src/frontend/tests/prepared.zig.
- Agent branches, not merged: `worktree-agent-a4d63279396fb619c` (va-models, handoff
  docs/handoff-va-models.md), `worktree-agent-a17f44bf2fd9e4b47` (host SIMD kernels, −2.9 to
  −4.4% Ir, handoff docs/handoff-espice-kernels.md), `worktree-agent-ab9985e38396806c7`
  (solvers; was told to stop and write docs/handoff-solvers.md), and
  `worktree-agent-aa3d1dd78990ce480` (instance-lane prototype: no-go, delete it).

## Open problem
`zig build test-prepared -Dgpu=false` on merged main: 44/46; failing tests are
"analysis directives dispatch every implemented capability..." and "prepared metadata and
query identities outlive parse storage". The frontend merge also left two stale references
(prepared.origin/source, `.ast.`), fixed on this branch. Check whether both failures exist on
`worktree-agent-a8aecc88a86f87d47` before the fix; if yes, they are the frontend agent's, not
the `v(out,2)` change. Then verify the fix and merge.

## Next steps (user-requested, not started)
1. Merge the agent branches (va-models, espice-kernels, solvers) after each passes the gate.
2. Move src/analysis/solvers -> src/solvers (update AGENTS.md DAG rule).
3. src/device/ (device_ir + device half of eval.zig + model loading), API via /api-design.
4. src/core/ for shared leaf types (problem_types, numerics, requests, output_types).
5. Fold problem's request/preparation code into frontend; keep the Problem facade + C ABI thin.
6. Audit Problem dispatch: one GPU context/probe per session, batch-shaped queries as one
   solve_batch, ParEval pool reused, prerequisite results shared.
7. Re-run the frontend simplify pass.
