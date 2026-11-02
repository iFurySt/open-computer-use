# Virtual display opt-in

Goal: default to no virtual display parameter or creation, with explicit host opt-in.

Scope: native config/schema/dispatch, JS config/guidance and distribution, platform
schema parity, docs and regression tests. Keep restoration and turn-ended cleanup.

Validation: Swift config/dispatch/schema tests, Node config/REPL/packaging tests,
Windows/Linux Go tests, documentation and repository checks. No live monitor creation.

Progress:
- [x] Verify existing creation and parameter paths.
- [x] Implement the configuration and guards.
- [x] Complete validation and review the diff.
- [x] Prepare review handoff.

Results: 381 native tests passed (7 opt-in tests skipped); 48 Node REPL/config/CLI
and 4 repository Node tests passed; native MCP smoke verified default/false/true
schemas and stale-call rejection without creating a display. Windows Go suite
and the affected Linux schema tests passed. The complete Linux suite requires a
Linux host. Repository hygiene is blocked by files already absent from main;
`make check-docs` passes.
