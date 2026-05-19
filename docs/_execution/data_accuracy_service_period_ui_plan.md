# Data Accuracy Service-Period UI Plan

## Goal

Fix two UI gaps from the graph-backed audit without touching backend routes,
migrations, canonical aggregation, timing/account files, or projection retry
files.

## Plan

1. In Operator Web Data Accuracy, reload configured service-period definitions
   whenever the active widget/session/location inputs change, so saved keys and
   visible rows cannot carry over from the prior context.
2. In the Admin per-location data accuracy table, render the union of configured
   service periods and explicit keyed service-period settings. Missing keyed
   rows should use the vendor defaults already implied by that location/vendor.
3. Make the vendor filter include implicit default rows from configured periods,
   not only explicit keyed service-period rows.
4. Add focused tests for the reload behavior and the mixed configured/keyed
   table behavior.
5. Run the smallest useful verification set: focused tests, analyzer on changed
   Dart files, and `git diff --check`.
