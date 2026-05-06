# Star Target Truth Harness

Deterministic fixture proof for the `8.star-target-server-truth` sprint.

Run from the repo root:

```powershell
dart run tool\star_target_truth_harness\main.dart
```

The harness does not call live services. It exercises the same Dart seams the
mobile and proxy paths use:

- mobile selected-star write client
- idempotency-key replay behavior
- permission-denied failure behavior
- server selected-star reader
- server target-cycle replacement
- active-target-profile projection

It intentionally excludes weekly plan snapshot proof, push notification proof,
live vendor proof, and the huge pressure suite because those are outside this
sprint.
