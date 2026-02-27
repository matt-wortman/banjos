You are a senior software architect conducting a pre-review analysis
of a backend codebase.

Your task is NOT to review the code. Your task is to:
1. Analyze the directory structure and file names below
2. Infer the purpose of each directory and key file
3. Group related files into logical "review modules"
4. Produce TWO outputs: root CLAUDE.md and modules.json

Each module must:
- Represent a cohesive unit of functionality
- Aim for 10-20 files max (split larger modules)
- Map to a real directory path in the repository

OUTPUT 1: Root CLAUDE.md

Use exactly this structure:

# CLAUDE.md — Project Root

## Project Overview
[1-3 sentences on type of app, inferred purpose, audience]

## Tech Stack
[Language, framework, DB, ORM, test framework, notable libraries]

## Architecture Pattern
[MVC / layered / hexagonal / microservices — infer from structure]

## Repository Structure
[Annotated directory tree — one line per major dir explaining its role]

## Review Modules
| # | Module Name | Path | Key Concern |
|---|-------------|------|-------------|
[one row per module]

## Cross-Cutting Concerns
[Logging, error handling, config/secrets, validation, auth checks]

## Recommended Review Order
[Ordered list, most foundational first, with one-line rationale each]

## Known Patterns & Conventions
[Infer from naming: e.g. routes→controllers→services→repos]

## What Claude Should NOT Review
[Generated code, vendor dirs, build artifacts]

---

OUTPUT 2: modules.json

Output valid JSON with exactly this schema:

{
  "repo_root": ".",
  "generated_at": "[ISO timestamp]",
  "review_order": [1, 2, 3, ...],
  "modules": [
    {
      "id": 1,
      "name": "Authentication",
      "path": "src/auth",
      "claude_md_path": "src/auth/CLAUDE.md",
      "description": "Handles login, JWT issuance and validation",
      "key_concerns": ["security", "token handling"],
      "depends_on": [],
      "depended_on_by": ["src/api", "src/middleware"],
      "file_patterns": ["src/auth/**/*"],
      "estimated_file_count": 8
    }
  ]
}

Rules:
- Every module MUST have a real path that exists in the repo
- review_order lists module IDs in recommended sequence
- depends_on and depended_on_by use directory paths
- No comments in the JSON — pure valid JSON only

---

Delimit your outputs EXACTLY as follows:

===== BEGIN CLAUDE.md =====
[content]
===== END CLAUDE.md =====

===== BEGIN modules.json =====
[content]
===== END modules.json =====

---

Repository structural snapshot:

[SNAPSHOT_CONTENT]
