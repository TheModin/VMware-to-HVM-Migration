---
title: "ADR-0002: Treating Morpheus 404 as Migration Success During Plan Polling"
status: "Accepted"
date: "2026-06-05"
authors: "Migration Script Architect"
tags: ["architecture", "decision", "morpheus", "api", "polling"]
supersedes: ""
superseded_by: ""
---

# ADR-0002: Treating Morpheus 404 as Migration Success During Plan Polling

## Status

Proposed | **Accepted** | Rejected | Superseded | Deprecated

## Context

After a Morpheus migration plan is started via `POST /api/migrations/{id}/run`, the script polls `GET /api/migrations/{id}` at 30-second intervals to track progress. The Morpheus VM Essentials REST API has a documented but counter-intuitive behavior:

> **Completed migration plans are automatically deleted by Morpheus.** Once a plan reaches `complete` / `completed` status, the Morpheus backend removes the plan record from its database. Subsequent `GET /api/migrations/{id}` requests return HTTP `404 Not Found`.

This creates an ambiguous signal: both a 404 from a legitimate "plan doesn't exist" scenario (e.g. wrong plan ID, plan was manually deleted) and a 404 from a successfully completed migration look identical to the HTTP client.

Additional complexity: Morpheus also returns HTTP `200 OK` with a JSON body of `{ "success": false, "msg": "Migration Plan not found" }` in some versions — a non-throwing success response that semantically means "not found".

The polling loop must distinguish completion-via-deletion from genuine error conditions (network failures, auth failures, server errors) without access to a completion-confirmation endpoint.

## Decision

**Treat `404 Not Found` (and the `success: false` + `"not found"` body pattern) as a SUCCESS signal** during migration plan polling, with the following guard conditions:

1. The 404 response is only interpreted as success if the plan ID was previously confirmed to exist (i.e., the `POST /api/migrations` create call succeeded and returned a valid plan ID, and `GET /api/migrations/{id}` was successfully polled at least once before the 404 appeared).
2. The catch block pattern-matches the exception message for `"not found"`, `"404"`, or `"Migration Plan not found"` strings before treating it as completion — all other exceptions are re-thrown.
3. A `{ success: false, msg: "not found" }` body returned with HTTP 200 is checked explicitly as a secondary completion signal.
4. Failed plans (status = `failed`) are **not** auto-deleted. A `failed` status response causes an immediate throw — it is never confused with 404-as-success.

Bearer token `401 Unauthorized` during polling is handled separately: the token is refreshed and the current poll interval is retried (not treated as completion).

## Consequences

### Positive

- **POS-001**: Correctly handles the Morpheus auto-deletion behavior without requiring a separate "check if plan still exists" pre-flight or a Morpheus-specific completion webhook.
- **POS-002**: The polling loop terminates promptly when migration completes instead of waiting for the full timeout period.
- **POS-003**: The pattern is resilient to both the HTTP 404 and the HTTP 200 + `success:false` body variants observed across Morpheus API versions.
- **POS-004**: Failed plans are correctly differentiated — status `failed` triggers rollback, not silent success treatment.

### Negative

- **NEG-001**: If the plan is manually deleted from the Morpheus UI mid-migration, the script will incorrectly treat the resulting 404 as success and proceed to post-migration steps against a VM that was never fully migrated.
- **NEG-002**: The pattern depends on string-matching exception messages (`"not found"`, `"404"`), which could break if Morpheus changes its error message format in a future release.
- **NEG-003**: There is a theoretical race condition: if the migration completes and the record is deleted between the final `run` call and the first poll, the very first poll interval would return 404. The guard condition (item 1 in the Decision section) mitigates this since the poll loop only begins after a confirmed plan ID is obtained.

## Alternatives Considered

### Poll with Timeout Until 404, Then Verify by Checking Instance Existence

- **ALT-001**: **Description**: After receiving a 404, do not treat it as success immediately. Instead, query `/api/instances?name=<vmname>` to confirm the migrated instance exists in Morpheus before declaring success.
- **ALT-002**: **Rejection Reason**: The instance lookup is already performed as a post-success step (Step 6: `Get-MorpheusInstanceIdByName`). Adding it as a success guard inside the poll loop duplicates that logic and adds latency. More importantly, the instance record may take time to appear in Morpheus after the plan completes — polling for it as a completion gate could cause false timeouts for large VMs.

### Require Explicit `complete` Status Before Terminating

- **ALT-003**: **Description**: Only exit the poll loop on an explicit `complete` or `completed` status body. Treat all 404s as errors.
- **ALT-004**: **Rejection Reason**: This approach fundamentally cannot work given the Morpheus API behavior — for plans that complete quickly, the `complete` status may never be observed because the record is deleted before the next 30-second poll fires. The script would always time out on fast migrations.

### Use Morpheus Webhooks / Event Bus

- **ALT-005**: **Description**: Subscribe to Morpheus task completion events via webhooks or the Morpheus message bus to receive a push notification when the migration plan finishes.
- **ALT-006**: **Rejection Reason**: Requires the management host running the script to be reachable from the Morpheus server (inbound webhook), introduces a dependency on Morpheus webhook configuration, and significantly complicates the script architecture for a single async event. Polling is simpler, stateless, and does not require Morpheus configuration changes.

## Implementation Notes

- **IMP-001**: The poll interval is 30 seconds (`Start-Sleep -Seconds 30`). The default timeout is 4 hours (`-MorpheusMigrationTimeoutHours 4`), configurable per run.
- **IMP-002**: The rollback path (`Remove-MorpheusArtifacts`) uses `DELETE /api/migrations/{id}`. If the plan was already auto-deleted (404 during rollback), the DELETE is treated as a no-op success — consistent with the same 404-as-completion logic.
- **IMP-003**: Token expiry during a long migration poll is handled by catching `401 Unauthorized` in the poll loop, calling `Get-MorpheusAuthHeaders` to refresh, and issuing `continue` to retry the current interval rather than `break` or `throw`.
- **IMP-004**: `$planAlreadyFailed` flag is set to `$true` when status = `failed`. This flag prevents the catch block from calling `Remove-MorpheusArtifacts` — failed plans must remain in the Morpheus UI for diagnostics and must be deleted manually.

## References

- **REF-001**: `Invoke-MorpheusMigration` function, poll loop (line ~1085)
- **REF-002**: [Morpheus Migration API — addMigration](https://apidocs.morpheusdata.com/reference/addmigration)
- **REF-003**: AGENTS.md — Morpheus API Quirks table
- **REF-004**: ADR-0003 — SecureString credential routing (bearer token handling)
