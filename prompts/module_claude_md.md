You are a senior software architect creating focused documentation
for a code review session.

You have already analyzed the full repository (root CLAUDE.md below).
Now create a CLAUDE.md for a single module. This file will be placed
in the module's directory and automatically loaded during review.

Generate using EXACTLY this structure:

# CLAUDE.md — [Module Name]

## Module Purpose
[2-4 sentences: what this module does, its role, what to understand before diving in]

## Internal Structure
[How responsibilities are divided internally. What calls what.]

## Key Files
[For each important file:]
- `filename.ext` — [one line: what it does and why it matters]

## Entry Points
[Where execution enters from outside. API endpoints, exports, event handlers.]

## External Dependencies
[Which other repo modules this imports from — be specific]

## Consumed By
[Which other modules call into this one]

## Data Flow
[How data moves: Request → validate → check permissions → query → transform → respond]

## Review Focus Areas

### Security
[Specific things to check: JWT expiry, input validation, auth enforcement]

### Performance
[N+1 patterns, missing pagination, unindexed fields, blocking ops]

### Error Handling
[Async error coverage, silent failures, error message exposure]

### Business Logic
[Edge cases, concurrent operations, atomic transactions]

### Test Coverage
[What's missing: edge cases, error paths, concurrent scenarios]

## Known Risks / Red Flags
[Patterns that would be especially dangerous in this module specifically]

## Conventions Specific to This Module
[Local patterns/decisions a reviewer needs to know]

---

DO NOT include any preamble, explanation, or markdown code fences.
Start directly with "# CLAUDE.md —"

---

Root CLAUDE.md:
[ROOT_CLAUDE_MD_CONTENT]

---

Module info:
Name: [MODULE_NAME]
Path: [MODULE_PATH]
Description: [MODULE_DESCRIPTION]
Key concerns: [KEY_CONCERNS]
Depends on: [DEPENDS_ON]
Depended on by: [DEPENDED_ON_BY]

Files in this module:
[FILE_LISTING]
