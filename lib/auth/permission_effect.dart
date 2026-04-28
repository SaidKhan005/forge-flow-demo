// Phase 9.6 - PermissionEffect enum.
//
// Mirrors the `role_permissions.effect CHECK IN ('allow', 'deny')`
// constraint from the Phase 9.0 schema. Kept in its own file so the
// resolver, cache, and management policy can import it without
// pulling in the full kernel.

enum PermissionEffect { allow, deny }
