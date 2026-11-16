# Reliability improvements

Scope: receive-state transitions, atomic serialized device-state persistence,
record-removal cleanup, deterministic concurrency tests, and reproducible checks.

Implementation:
1. Replace receive booleans with an enum and centralize writer closure and terminal transitions.
2. Serialize snapshots; flush a sibling temporary file and atomically rename it over state.
3. On record removal, cancel pending waiters and discard receive caches; preserve completed files.
4. Control close/hash timing with completers in tests rather than timing assumptions.
5. Pin Flutter 3.44.7 and use JDK 17 for Android; add one verification command.

Validation: focused regressions, full Flutter tests, static analysis, Android debug build.
