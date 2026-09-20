# Verification record

Fixture: **deploy-test-ruby-rack** (plain Ruby Rack app served by WEBrick via
`Rackup::Handler`, SQLite persistence via the `sqlite3` gem).

## Command

```bash
bash scripts/verify.sh
```

## Environment

| Component | Version |
|-----------|---------|
| Ruby      | 3.2.3 |
| rack      | 3.2.7 |
| rackup    | 2.3.1 |
| webrick   | 1.9.2 |
| sqlite3 gem | 2.9.6 |
| SQLite    | 3.53.2 (bundled with the sqlite3 gem) |
| GNU bash  | 5.x (set -euo pipefail) |
| curl      | 8.5.0 |
| node      | 22.23.2 (client JS syntax check) |

## Steps and outcome (exit 0 = all passed)

1. `scripts/verify.sh` — provisions the vendored bundle (`vendor/bundle`,
   gitignored) from `Gemfile.lock` and reuses it on subsequent runs:
   **passed**.
2. `scripts/build.sh` — writes the `VERSION` release marker (git short SHA,
   `40c604d`; `VERSION` is a gitignored build artifact) + runtime preflight +
   Ruby syntax check on `src/**/*.rb`, `config.ru`, `server.rb`,
   `tests/run_tests.rb` + client JS check: **passed**.
3. Unit/integration suite — `bundle exec ruby tests/run_tests.rb` against the
   exact `API.dispatch` router with a real SQLite file: **126 checks,
   0 failed** (routing/health/meta/csrf, project & task CRUD, search + status/
   priority/project filters, LIKE-wildcard escaping, validation negatives
   incl. blank/over-long/mistyped fields and unknown references, empty PATCH,
   non-positive ids, 404s, CSRF enforcement incl. `_csrf` body fallback,
   malformed JSON, schema/seed idempotency, restart-style persistence,
   cascade delete, readiness that genuinely drops to 503 when the database
   path is unusable).
4. Production smoke — `scripts/smoke.sh` against the real production process
   (`bundle exec ruby server.rb` -> WEBrick -> config.ru): **55 checks,
   0 failed**, including:
   - liveness/readiness, release marker and runtime in `/api/meta`, static UI
     + assets, nested UI route;
   - session bootstrap + CSRF token capture over HTTP;
   - project/task CRUD over real HTTP, read-back, search and filters,
     patch/delete, 400/403/404/405 negatives;
   - sqlite file written to the configured persistent path;
   - persistence survivor survives graceful SIGTERM stop -> restart on the
     **same** SQLite path with stable counts;
   - database-unavailable readiness: `503` with `status: "unavailable"`
     while liveness stays `200` and the static UI keeps serving;
   - recovery: readiness returns to `200` once the database path is valid
     again.

Every server started by the smoke is terminated on success AND failure
(SIGTERM, SIGKILL fallback, `trap ... EXIT`); a post-run process check found
no leftover Ruby/WEBrick processes.

## Candidate commit

- Branch: `feat/compatibility-ruby`
- Tested commit: `40c604df1da07a457393ac137d62f0f391a5375d`
- Release marker served by `/api/meta` at that commit: `40c604d`

## Notes

- No live platform/deployment qualification was performed; this is local
  production verification only. `deployment-verified` is intentionally not
  claimed.
- No credentials or secrets are committed; `.env.example` contains safe
  placeholder values only.