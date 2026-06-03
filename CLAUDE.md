# .github — AI Instructions

This repository contains the GitHub organisation profile and shared developer documentation
for the [track-any-device](https://github.com/track-any-device) organisation.

---

## What lives here

| Path | Purpose |
|---|---|
| `profile/README.md` | Organisation homepage — shown publicly on github.com/track-any-device |

---

## Rule 1 — Plan before implementing

Before making any change, ask clarifying questions to reach a shared understanding.
Present a plan and get explicit agreement. Only begin once the approach is confirmed.

---

## Rule 2 — profile/README.md is the source of truth for org structure

When a new repository is added to the organisation, the repository table in `profile/README.md`
must be updated in the same PR that creates the repo. Never let the README drift from the
actual set of repositories.

When a repository is renamed, removed, or changes purpose, update `profile/README.md` immediately.

---

## Rule 3 — Cross-repo changes require a GitHub issue first

If work here requires a change in another repository (e.g. updating a CLAUDE.md, adding a
workflow template) — open a GitHub issue in that repository first, describe exactly what is
needed and why, then reference the issue number here.

---

## Rule 4 — Release order must stay accurate

The release order section in `profile/README.md` reflects the real package dependency graph.
If a new package is added or a dependency relationship changes, update the graph here to match.

---

## Tone for profile/README.md

- Public-facing section first — assume the reader is evaluating the project
- Developer orientation second — assume the reader is onboarding as a contributor
- English only
- No marketing superlatives — describe what the system does, not how amazing it is
- Keep the architecture diagram accurate — if a service is added or removed, update the diagram
