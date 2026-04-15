# Phase 8 Gate Artifacts

Pre-Phase-8 readiness documents for the Forge & Flow repo.

These artifacts exist to make the Phase 8 gate auditable. They are not connector implementations.

## Contents

- [POS Vendor Capability Profile](vendor_capability_profile_pos.md)
- [Labor Vendor Capability Profile](vendor_capability_profile_labor.md)
- [Vendor Live-Data Capability Matrix](vendor_live_data_capability_matrix.md)
- [Source Ownership Matrix](source_ownership_matrix.md)
- [Replay Readiness Matrix](replay_readiness_matrix.md)
- [Compatibility Bridge Scope](compatibility_bridge_scope.md)
- [Phase 8 Readiness Signoff](phase_8_readiness_signoff.md)

## Purpose

Phase 8 adds live POS and labor adapters. Before that work starts, the repo must demonstrate:

1. The app can run end to end from imported fixture bundles without screen-level demo constants.
2. Written vendor capability contracts exist for the first target connectors.
3. Source ownership is explicit for every operational field.
4. Replay scenarios are documented with honest evidence status.
5. The readiness gate is auditable with clear pass/fail/pending status for each item.

If any gate item is pending or blocked, it is documented here rather than hidden.
