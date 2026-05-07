# Cloud Run Environment Variables Reference

Updated: 2026-05-08  
Owner: PF4 (performance hardening) + general ops  
Status: Authority for runtime env configuration

## Overview

This document lists the required and optional environment variables that must
be set on Cloud Run services (proxy, sync worker, admin console) to ensure
correct runtime behavior, connection pooling, and performance.

All environment variables are injected at Cloud Run deployment time and stored
in Cloud Run Secret Manager where sensitive values (API keys, database URLs)
are stored.

## Required Variables

### POSTGRES_POOL_MAX_CONNECTIONS

**Type:** Integer  
**Default fallback:** 20 (as of PF4)  
**Range:** 1 to 200 (upper bound enforced by `kPostgresMaxConnectionsPerPoolUpperBound`)  
**Location:** `lib/infrastructure/persistence/postgres/postgres_executor.dart`

Sets the maximum number of concurrent connections a Cloud Run instance maintains
in its `package:postgres` connection pool.

**PF4 hardening (B6):**
- Bumped from 4 → 20 to handle concurrent request bursts without pool exhaustion.
- Load tests showed pool exhaustion at ~10 rps per instance under the old default.
- New default of 20 is safe for the Forge & Flow deployment footprint:
  - Azure DB Flexible Server (PG 16, 2 vCores) supports ~100 `max_connections`.
  - Up to 3 Cloud Run services (proxy + sync worker + admin console).
  - Up to 2 instances per service.
  - Peak: 3 × 2 × 20 = 120 sessions (within 150-connection soft ceiling).

**Deploy time:**
```bash
# In deployment script or Cloud Run UI:
gcloud run deploy <service-name> \
  --set-env-vars POSTGRES_POOL_MAX_CONNECTIONS=20 \
  ...
```

**Troubleshooting:**
- If you see "pool exhausted" errors or `SQLSTATE 53300`, check instance count
  and burst traffic patterns. Increase `POSTGRES_POOL_MAX_CONNECTIONS` or add
  Cloud Run instances.
- If you see "too many connections" from the database, sum peak sessions across
  all services and check against PostgreSQL `max_connections` setting.

## Optional Variables

### (Future env vars go here as phases land)

## Verification Checklist

Before deploying a Cloud Run service:

1. [ ] `POSTGRES_POOL_MAX_CONNECTIONS` is set explicitly (not relying on fallback).
2. [ ] All Secret Manager references in the deployment manifest are valid.
3. [ ] No plaintext secrets appear in the deployment command or logs.
4. [ ] After deploy, verify the service boots by checking Cloud Run logs for
       connection errors.

## See Also

- `lib/infrastructure/persistence/postgres/postgres_executor.dart` — connection
  pool initialization and fallback logic.
- `runbooks/audit_anchor_job.yaml` — example Cloud Run Job manifest with env
  var injection via Secret Manager.
- Azure DB Flexible Server tuning guide — max_connections limits and
  connection pooling best practices.
