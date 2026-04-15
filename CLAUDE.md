# Eplo — Commit conventions

All commits in this repository **must** follow these rules.

## 1. Conventional Commits

Format: `<type>(<scope>)!: <subject>`

- `type` (required): one of `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `build`, `ci`, `chore`, `revert`.
- `scope` (optional): a short identifier of the affected area (e.g. `auth`, `runners`, `billing`, `ws`, `migrations`). Omit parentheses if there is no scope.
- `!` after type/scope indicates a breaking change. The body must contain a `BREAKING CHANGE:` footer explaining the break.
- `subject`: imperative mood, lowercase, no trailing period, ≤72 chars.

Examples:

```
feat(auth): provision personal tenant on first github login
fix(ws): reconnect with exponential backoff after network drop
refactor(runners): extract pairing token hashing into service
chore(deps): bump vapor to 4.99.0
feat(billing)!: switch from per-seat to per-runner pricing
```

## 2. No `Co-Authored-By` trailers

Do **not** add `Co-Authored-By:` lines to commit messages. This applies to every commit, including those created by AI assistants.

## 3. Body and footers

- Body (optional): wrap at 72 chars, explain **why**, not **what**.
- Footers: `BREAKING CHANGE:`, `Refs:`, `Closes:` when applicable.
- No emoji, no decorations, no generated-by trailers.

## 4. Pre-push check

Before pushing, run `git log origin/main..HEAD` and verify every new commit matches the format above and contains no `Co-Authored-By` line.
