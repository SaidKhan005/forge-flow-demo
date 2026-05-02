# Source Ownership Matrix

Field-level ownership for operational truth in the Forge & Flow app.

Authority source: `docs/DATA_ALIGNMENT_TRACKER.md` Section "Source Ownership Matrix".

## POS-Owned Fields

| Field | Canonical App Concept | Owning System | Precedence / Fallback | Notes |
| --- | --- | --- | --- | --- |
| Business date | `businessDate` on `ClosedShiftInput` | POS | POS is the source of business-date truth when POS is the source of sales | Business date maps to the POS closed batch or finalized period |
| Sales | `actualSales` on `ClosedShiftInput` | POS | POS only — no fallback | Gross sales in dollars from POS |
| Covers / guest count | `covers` on `ClosedShiftInput` | POS | POS when reliable; forecast covers as fallback if POS covers unavailable | Availability varies by vendor — must be confirmed per connector |
| Checks / tickets | Not yet canonical | POS | POS when exposed | Not currently used in app formulas; available for future reconciliation |
| Voids / comps | Not yet canonical | POS | POS when exposed | Not currently used in app formulas |
| Revenue center / order channel | Not yet canonical | POS | POS when available | Not currently used in daypart mapping; app owns daypart rules |

## Labor-System-Owned Fields

| Field | Canonical App Concept | Owning System | Precedence / Fallback | Notes |
| --- | --- | --- | --- | --- |
| Schedules | `scheduledFohHours`, `scheduledBohHours` | Labor | Labor when available; manual input as fallback | Schedule granularity must match shift/daypart level |
| Actual worked hours | `actualFohHours`, `actualBohHours` | Labor | Labor only — no fallback | Core labor input for all labor % and model-hour math |
| Overtime state | Not yet canonical | Labor | Labor when exposed | Not currently used in app formulas |
| Labor dollars | `actualFohLaborDollars`, `actualBohLaborDollars` | Labor | Labor when exposed; otherwise treat as unavailable/unknown in source-truth consumers | The q-lane removed the old "hours × wage" teaching fallback from live truth paths |
| Job / role assignments | Not yet canonical | Labor | Labor when exposed | Not currently used; may be useful for future FOH/BOH split accuracy |
| Time punches | Not yet canonical | Labor | Labor | Underlying source for actual worked hours |

## App-Owned Derived Fields

| Field | Canonical App Concept | Owning System | Precedence / Fallback | Notes |
| --- | --- | --- | --- | --- |
| Daypart mapping rules | Daypart config on restaurant scope | App | App only | App defines lunch/dinner/late_night boundaries |
| Rolling 60-day baseline | `BaselineBuild` (future), currently `BaselineData` | App | App only — derived from eligible closed shifts | System baseline is the default target source |
| Active target profile | `ActiveTargetProfile` | App | App only — projected from the active `TargetCycle` | Persisted per restaurant; canonical source types are cycle-backed (`cycle_recommended`, `cycle_manager_override`, `cycle_admin_replacement`) |
| OPZ bounds | `opzFloorCPLH`, `opzCeilingCPLH` | App | App only — derived from baseline records | Jim Taylor Ch. 11 |
| Variance math | Dollar gap, labor % variance, lever detection | App | App only | Jim Taylor Ch. 10 formulas in `LaborModel` |
| History / Learn derivations | `HistoryPatternRecord`, `LearnTeachingSummary` | App | App only — derived from tracked closed shifts | Teaching surfaces, not source facts |
| Manager override state | Override selection keys + active target profile | App | App only | Persisted in `baseline_selected_records` + `active_target_profiles` |
| Forecast covers | `forecastCovers` on `ClosedShiftInput` | App or POS | App owns default; POS or schedule system can override | Currently app-owned from fixture data |

## Overlapping Fields — Precedence Rules

| Field | Overlap | Precedence Rule |
| --- | --- | --- |
| Covers | POS vs forecast | Use POS actual covers when available and reliable; fall back to forecast covers only when POS covers are absent or unreliable |
| Labor dollars | Labor system vs unavailable | Use labor-system dollars when exposed; otherwise degrade honestly instead of fabricating computed dollar truth |
| Business date | POS vs calendar | POS business date takes precedence over wall-clock date when POS defines the business period |
| Schedule hours | Labor system vs manual | Use labor-system schedule when available; allow manual entry as fallback |

## Notes

- Vendor selection is TBD for both POS and labor. Ownership rules above are structural and apply regardless of which specific vendor is connected.
- Widgets must not decide field ownership ad hoc. All ownership decisions flow through the adapter and canonical input model.
- When a new vendor is connected, its capability profile should be updated to confirm which fields it actually exposes.
