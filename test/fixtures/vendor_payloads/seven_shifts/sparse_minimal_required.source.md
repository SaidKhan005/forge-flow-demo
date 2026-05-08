# Source

- URL: https://developers.7shifts.com/reference/listtimepunches
- Retrieved: 2026-05-08
- API version: v2 (pinned `v2-2026-05-04`)
- Endpoint: `time_punch.created` webhook envelope
- Notes: minimal documented payload — only the fields required to
  uniquely identify and timestamp a punch. Optional fields (role,
  shift_id, location_id, department_id, hourly_wage, tips, breaks)
  are omitted to exercise the adapter's lenient parsing path. The
  canonical fact still resolves: `vendor_entity_id` from `id`,
  `employee_id` from `user_id`, `shift_start` from `clocked_in`,
  `shift_end` null (open punch), `is_approved=false`, `role_name`
  empty, `shift_id` null. Wage provenance falls through to
  `vendor_seven_shifts_dollars_unavailable_target_wage_substituted`.
