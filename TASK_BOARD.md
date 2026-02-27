# TASK_BOARD.md

Purpose: task ownership and lock/state tracking.

Rules:
- Each agent edits only rows where `Claimed By` is themselves.
- Exception: stale-lock reclaim is allowed per reclaim rule below.
- One commit-producing task per agent at a time.
- Keep timestamps in UTC ISO 8601.

Status enums:
- `PLANNED`: task recorded, not started
- `IN_PROGRESS`: active implementation
- `BLOCKED`: cannot proceed due to dependency/decision
- `DONE`: implementation complete, lock still held for verification/handoff
- `RELEASED`: lock dropped; other agent may edit

Stale-lock reclaim rule:
- If lock age is greater than 2 hours and no owner handoff update in that window,
  either agent may set status to `RELEASED` and fill reclaim metadata.
- Reclaiming agent must also add a reclaim entry in `HANDOFF.md`.

## Active Tasks / Locks

| Task ID | Scope (File/Dir/Module) | Claimed By | Claimed At (UTC) | Status | Updated At (UTC) | Reclaimed By | Reclaimed At (UTC) | Reclaim Reason | Notes |
|---|---|---|---|---|---|---|---|---|---|
| A-YYYYMMDD-001 | [path or module] | Agent A | [timestamp] | PLANNED | [timestamp] |  |  |  |  |
| B-YYYYMMDD-001 | [path or module] | Agent B | [timestamp] | PLANNED | [timestamp] |  |  |  |  |
| B-20260227-001 | Phase 1: directory structure + toolkit.conf + Contracts 1/3/5 proposals | Agent B | 2026-02-27T16:25:08Z | RELEASED | 2026-02-27T16:26:46Z |  |  |  | Completed and released for Agent A review |
| B-20260227-002 | Contract 2 acknowledgment (C-20260227-001) + Active Contracts update | Agent B | 2026-02-27T16:34:03Z | RELEASED | 2026-02-27T16:34:03Z |  |  |  | Completed |
| A-20260227-002 | Contract 4 proposal (C-20260227-005: JSON output schemas) | Agent A | 2026-02-27T17:30:00Z | RELEASED | 2026-02-27T17:30:00Z |  |  |  | Awaiting Agent B ack |
| B-20260227-003 | Contract 4 acknowledgment + implement scripts/01_generate_snapshot.sh | Agent B | 2026-02-27T16:38:58Z | RELEASED | 2026-02-27T16:41:22Z |  |  |  | Completed and released |
| B-20260227-004 | Implement bootstrap.sh (Section 7) | Agent B | 2026-02-27T16:42:01Z | RELEASED | 2026-02-27T16:43:03Z |  |  |  | Completed and released |
| B-20260227-005 | Implement scripts/02_root_claude_md.sh (Section 2/Phase 2) | Agent B | 2026-02-27T16:43:03Z | RELEASED | 2026-02-27T16:43:46Z |  |  |  | Completed and released |
| B-20260227-006 | Harden scripts/02_root_claude_md.sh parsing + implement scripts/03_module_claude_mds.sh | Agent B | 2026-02-27T17:09:38Z | RELEASED | 2026-02-27T17:09:38Z |  |  |  | Completed and released |
| B-20260227-007 | Implement scripts/04_static_analysis.sh + scripts/05_ai_review.sh + master_review.sh | Agent B | 2026-02-27T17:17:22Z | RELEASED | 2026-02-27T17:17:22Z |  |  |  | Completed and released |
| A-20260227-003 | All Agent A deliverables: 5 prompts, 4 agent defs, scripts/06_synthesis.sh, README.md | Agent A | 2026-02-27T17:04:43Z | RELEASED | 2026-02-27T17:04:43Z |  |  |  | All 11 files created and validated |

## Released / Closed (Optional History)

| Task ID | Scope (File/Dir/Module) | Completed By | Released At (UTC) | Final Status | Notes |
|---|---|---|---|---|---|
| [task-id] | [scope] | [agent] | [timestamp] | RELEASED | [optional] |
| B-20260227-001 | Phase 1: directory structure + toolkit.conf + Contracts 1/3/5 proposals | Agent B | 2026-02-27T16:26:46Z | RELEASED | Waiting on Agent A acknowledgment/amendments for C-20260227-002/003/004 |
| B-20260227-002 | Contract 2 acknowledgment (C-20260227-001) + Active Contracts update | Agent B | 2026-02-27T16:34:03Z | RELEASED | Contract 2 now acknowledged by Agent B |
| B-20260227-003 | Contract 4 acknowledgment + implement scripts/01_generate_snapshot.sh | Agent B | 2026-02-27T16:41:22Z | RELEASED | C-20260227-005 acknowledged; script 01 implemented and smoke-tested |
| B-20260227-004 | Implement bootstrap.sh (Section 7) | Agent B | 2026-02-27T16:43:03Z | RELEASED | Script implemented, executable, and smoke-tested in check mode |
| B-20260227-005 | Implement scripts/02_root_claude_md.sh (Section 2/Phase 2) | Agent B | 2026-02-27T16:43:46Z | RELEASED | Script implemented with token substitution + delimiter parsing + validation |
| B-20260227-006 | Harden scripts/02_root_claude_md.sh parsing + implement scripts/03_module_claude_mds.sh | Agent B | 2026-02-27T17:09:38Z | RELEASED | Phase 2 fence-handling fixed; Phase 3 implemented with parallel execution, token substitution, and progress tracking |
| B-20260227-007 | Implement scripts/04_static_analysis.sh + scripts/05_ai_review.sh + master_review.sh | Agent B | 2026-02-27T17:17:22Z | RELEASED | Phase 4 and 5 scripts implemented with contract fallbacks and schema validation; master orchestrator implemented with option parsing and phase execution |
| A-20260227-003 | All Agent A deliverables: 5 prompts, 4 agent defs, scripts/06_synthesis.sh, README.md | Agent A | 2026-02-27T17:04:43Z | RELEASED | All 11 Agent A files created, validated against spec and contracts |

## Notes

- Use `Scope` entries specific enough to avoid collisions (file path > module > broad area).
- If two tasks touch adjacent code, record expected overlap in `Notes` before implementation.
