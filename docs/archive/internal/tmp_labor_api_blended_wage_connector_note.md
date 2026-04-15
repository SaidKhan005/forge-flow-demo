# Temporary Note: Labor API Inputs Needed To Derive Blended Wage

## Why this note exists

This is a compact internal reference for connector planning.

It captures:

- the raw labor facts the app actually needs in order to derive blended wage
- the split between actual blended wage and target/theoretical blended wage
- what the current public official docs support for 7shifts, Toast, Square,
  Clover, and Push Operations

This is **not** a roadmap slice by itself. It is a planning aid for future
connector work and partner-doc follow-up.

## Core app rule

The app should **derive** blended wage in-app.

We do **not** want vendor adapters to be built around a vendor-provided
"blended wage" field as source truth.

### Actual blended wage

```text
actual blended wage =
(FOH labor dollars + BOH labor dollars) / (FOH hours + BOH hours)
```

Minimum raw inputs:

- actual FOH hours
- actual BOH hours
- actual FOH labor dollars or FOH wage/rate truth
- actual BOH labor dollars or BOH wage/rate truth
- role/job/department mapping so hours and dollars can be bucketed FOH vs BOH
- approval/finalization state for historical truth

### Target / theoretical blended wage

```text
target blended wage =
((FOH target hours × FOH target wage) + (BOH target hours × BOH target wage))
/ total target hours
```

Minimum raw inputs:

- planned/scheduled FOH hours
- planned/scheduled BOH hours
- FOH target wage
- BOH target wage
- role/job/department mapping so scheduled hours can be bucketed FOH vs BOH
- effective-date wage truth where the labor system supports it

## Canonical connector mapping

| Derived metric | Raw labor facts we need | Why |
| --- | --- | --- |
| Actual blended wage | worked hours, breaks, role/job/department, actual labor dollars or hourly wage, approval/finalization status | We need actual FOH/BOH hours plus actual FOH/BOH labor dollars to compute what was really paid per hour |
| Target/theoretical blended wage | scheduled/planned hours, role/job/department, wage-rate truth, effective dates | We need planned FOH/BOH hours plus FOH/BOH wage standards to compute what blended wage should have been |

## Vendor status snapshot

### 7shifts

Public official docs support this strongly.

Can consume:

- time punches with `clocked_in`, `clocked_out`, `breaks`, `role_id`,
  `department_id`, `hourly_wage`, `approved`
- wage records with `wage_cents`, `wage_type`, `effective_date`, `role_id`
- scheduled shifts with start/end datetime and role/department references

Practical verdict:

- strong fit for deriving actual blended wage
- strong fit for deriving target/theoretical blended wage

Official docs:

- [Time Punch Data](https://developers.7shifts.com/docs/read-time-punch-data)
- [Wage Data](https://developers.7shifts.com/docs/read-employee-wage-data)
- [List Shifts](https://developers.7shifts.com/reference/listshift)

### Toast Labor

Public official docs support this well.

Can consume:

- time entries with worked hours, breaks, and `hourlyWage`
- jobs / employees for role context
- scheduled labor shifts

Practical verdict:

- strong fit for deriving actual blended wage
- strong fit for deriving target/theoretical blended wage

Official docs:

- [Payroll / Labor guide](https://doc.toasttab.com/doc/cookbook/apiIntegrationChecklistPayroll.html)
- [Labor shifts API](https://doc.toasttab.com/openapi/labor/operation/shiftsGet/)

### Square Labor

Public official docs support this at a higher level.

Can consume:

- timecards with hours worked, breaks, and wages
- scheduled shifts
- assigned jobs

Practical verdict:

- strong fit for deriving actual blended wage
- strong fit for deriving target/theoretical blended wage

Official docs:

- [Labor API overview](https://developer.squareup.com/docs/labor-api/what-it-does)

### Clover

Public official docs are weaker for this use case.

Official docs clearly support:

- employee shifts / in-time / out-time style labor tracking

But public docs do **not** clearly prove the same wage/schedule richness as
7shifts / Toast / Square.

Practical verdict:

- partial for actual blended wage
- weak / unclear for target/theoretical blended wage

Official docs:

- [Employee shifts](https://docs.clover.com/dev/reference/employeegetemployeeshifts)

### Push Operations

Public official docs do **not** expose developer/API reference material that
proves the exact fields or endpoints we would consume.

Public official sites do show product/support coverage for:

- scheduling
- time tracking
- clock approvals
- breaks / break compliance
- payroll
- labour & sales
- POS integrations
- export flows

So Push is a plausible labor-system candidate at the product level, but the
public docs are **not enough** to confirm:

- exact API field names
- exact endpoint names
- auth model
- webhook support
- incremental sync fields
- whether actual labor dollars are exposed directly
- whether wage rates are exposed directly

Practical verdict:

- product-level plausibility: yes
- API-level proof from public docs: no
- partner docs required before connector design is honest

Official public sources:

- [Push Help Center](https://support.pushoperations.com/hc/en-us)
- [Time Tracking category](https://support.pushoperations.com/hc/en-us/categories/115000128691-Time-Tracking)
- [Push pricing / product overview](https://www.pushoperations.com/us/pushpricing)

## Important architectural reminder

The app's wage authority contract is still:

- FOH wage and BOH wage are source-backed standards
- blended wage is always derived

That means:

- labor integrations should provide wage truth and/or labor dollars
- the app should map vendor role structure into FOH/BOH buckets
- the app should compute blended wage from those canonical inputs
- Settings fallback roles remain the app-owned fallback when labor wage truth
  is incomplete or unavailable

## Best next use of this note

Use this when:

- reading partner-only labor API docs
- filling vendor-specific connector checklists
- deciding whether a labor system can support actual vs target blended wage
- drafting field-by-field canonical mappings once private schemas are available
