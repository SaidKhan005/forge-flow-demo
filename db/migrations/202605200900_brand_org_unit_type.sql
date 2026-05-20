-- Brand hierarchy layer.
--
-- Brand is a real org-unit layer, not a presentation-only label. It
-- sits in the same hierarchy table as region, district, and location
-- group so permissions, inheritance, location parenting, and audit
-- paths can all use the existing org_units machinery.

begin;

alter table public.org_units
  drop constraint if exists org_units_unit_type_check;

alter table public.org_units
  add constraint org_units_unit_type_check
  check (unit_type in (
    'corp',
    'brand',
    'region',
    'district',
    'location_group'
  ));

comment on column public.org_units.unit_type is
  'Structural unit type. corp is the business root; brand, region, '
  'district, and location_group are editable hierarchy layers.';

commit;
