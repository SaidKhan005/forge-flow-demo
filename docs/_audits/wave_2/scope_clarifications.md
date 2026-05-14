# Wave 2 — Scope Clarifications

> Open questions Claude2 (second-Claude lane orchestrator) raised while
> picking work from `docs/_indices/WAVE_2_LEDGER.md`. Main orchestrator
> answers (or routes to operator) here so Claude2 can proceed without
> guessing.

## 2026-05-14 — U-2 vs H-3 file overlap on the top bar widget

**Raised by:** Claude2 (lane orchestrator), worktree `pensive-bhabha-256874`.

**Conflict:**

- **U-2** (Claude2, auto-gate): "Ops Console — Top bar redesign + hierarchy-map location selector." Source: debug.md:102-107 (OW-0c).
- **H-3** (Main, operator-gate): "Top bar location selector — hierarchy-map picker (NOT a flat list) on operator-web + admin." Source: debug.md:106 (OW-0c, deeper part).

Both rows cite OW-0c and both touch the operator-web top-bar widget(s) and the location selector. Concurrent workers would collide at the file level.

**Working interpretation (Claude2 deferring to confirmation):**

- U-2 = the **cosmetic redesign** half of OW-0c (top bar bigger, sign-out + user email bigger, subtitle/copy cleanup).
- H-3 = the **hierarchy-tree picker implementation** half of OW-0c (replace flat-list location selector with hierarchy-map picker on operator-web + admin).

If this is correct, the two slices share files but not lines, and the right move is to serialize: ship H-3 first, then layer U-2's cosmetic polish on top.

**Action taken by Claude2:**

- U-2 **deferred out of batch 1**. Batch 1 ships the rest of the U-Ops bundle (U-1, U-3, U-4) plus V-1, D-1, D-2.
- U-2 picked up in a later batch once (a) H-3 is merged, or (b) Main confirms the split above and we can dispatch in parallel with an explicit no-overlap file carve-out.

**Asking:**

1. Is the cosmetic / hierarchy-picker split above the correct read of U-2 vs H-3?
2. If yes — preferred sequencing: serialize (Claude2 waits for H-3 to merge before dispatching U-2 worker) or parallel-with-carveout (Claude2 dispatches U-2 worker scoped to ONLY the cosmetic top-bar work, explicitly NOT touching the location selector widget)?
3. If no — please re-scope U-2 in `WAVE_2_LEDGER.md`.

No urgency on the answer — Claude2 has 3 other batch-1 workers dispatched and the U-Mobile + MP-1 batch behind them. U-2 is the only slice blocked by this question.
