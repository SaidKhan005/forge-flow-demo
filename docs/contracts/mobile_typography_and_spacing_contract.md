# Mobile Typography & Spacing Contract

Status: active. Tier-2 contract. Origin: 2026-05-17 mobile-readability pass.
Authority: binds operator-facing mobile UI copy/layout alongside the UX
Writing Standard and the Metric Honesty Doctrine.

## Why this exists

The mobile app had a real design system (`lib/theme/app_theme.dart`) but it
was (a) too small for comfortable on-phone reading, (b) mislabeled (style
names named a historical pixel size, not the current one), and (c) bypassed
by ad-hoc inline `TextStyle(...)` and raw `fontFamily: 'monospace'`. The net
effect was inconsistent, hard-to-scan screens. This contract pins the rules
so the scale stays small, honest, and readable.

## Type scale — seven semantic roles

New code MUST use the semantic role getters on `AppTextStyles`. Each role is
the single place its size/weight lives.

| Role | Getter | Size | Use for |
|------|--------|------|---------|
| Screen title | `screenTitle()` | 28 | One per screen, top of page |
| Section heading | `sectionHeading()` | 16 / w700 | Group/section labels |
| Body | `bodyText()` | 15 | Default reading text |
| Body strong | `bodyStrong()` | 15 / w600 | Emphasised reading text |
| Caption | `caption()` | 13 | Secondary / helper text |
| Metric large | `metricLarge()` | 22 mono | Hero numeric figures |
| Metric small | `metricSmall()` | 14 mono | Inline numbers, table cells |

The legacy primitive names (`body11`, `mono10`, `display28`, …) remain ONLY
so existing call sites compile. Their name is historical; the `fontSize:` in
`app_theme.dart` is authoritative. Do not add new call sites against the raw
names — use the semantic role.

### Hard rules

1. **No inline font sizing.** No `TextStyle(fontSize: N)` /
   `.copyWith(fontSize: N)` in `lib/screens/**` or `lib/widgets/**`. Pick a
   role.
2. **No raw `fontFamily: 'monospace'`.** Numbers/IDs use `metricSmall()` /
   `metricLarge()` (IBM Plex Mono) so the app has one mono face.
3. **Body text floor is 15px.** Reading text never below 15. Captions never
   below 13. (Phone legibility floor.)
4. **No default italics on small text.** Small italic is the least scannable
   treatment. `body11`/`body12` are upright by default; callers opt into
   italic explicitly via `style: FontStyle.italic` only for genuine emphasis.
5. **Three faces, disciplined:** Playfair (display only), IBM Plex Sans
   (everything textual), IBM Plex Mono (numeric/IDs only). No fourth face.

## Spacing scale — `AppSpacing`

4/8pt rhythm. Use the tokens, not literals, for padding/gaps/insets.

| Token | px | Use |
|-------|----|-----|
| `xs` | 4 | Hairline gap inside a control |
| `sm` | 8 | Tight gap between related rows |
| `md` | 12 | Default gap between list/stack items |
| `lg` | 16 | Screen edge gutter, card inner padding |
| `xl` | 24 | Between distinct sections |
| `xxl` | 32 | Major block break |

Helpers: `AppSpacing.screenH`, `AppSpacing.card`, `AppSpacing.row`. New
screens MUST use these; ad-hoc `EdgeInsets` literals are a review finding.

## Accessibility — OS text scaling

The app root (`lib/forge_flow_app.dart`) clamps the OS font-size setting to
0.9x–1.3x via a `MediaQuery` `builder`. This means the user's accessibility
font setting is respected but cannot break dense metric layouts. Do not
override `textScaler` per-screen.

## Scope / status of the sweep

The 2026-05-17 pass landed: the central scale fix (propagates to every
screen using `AppTextStyles`), `AppSpacing`, the semantic roles, the
text-scale clamp, and removed every raw `'monospace'` literal in `lib/**`.

Remaining inline `TextStyle(fontSize: N)` cleanup in auth (`totp_*`) and
MFA (`settings_mfa_section`) surfaces is a SEPARATE, operator-approval-gated
follow-up (auth-critical surface rule) — it is cosmetic-only and must not
touch the deliberate transparent-input technique in the TOTP view.
