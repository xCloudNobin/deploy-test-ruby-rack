# Ruby / Rack Taskboard

A meaningful **plain Ruby Rack** application for the xCloud app-compatibility
suite: a project/task board served by the **Rack** interface (no Rails and no
web framework beyond the `rack`/`rackup` gems), run with the **WEBrick**
production server, with **SQLite** persistence via the `sqlite3` gem.

It is a production-process fixture, not a success-page shell: every workflow
reads and writes through parameterized SQLite queries, all input is validated
server-side with meaningful error payloads, and `scripts/verify.sh` exercises
the real production process end to end.

## Feature summary

- Plain **Rack** app (`config.ru` + `src/app.rb`); `server.rb` loads the
  canonical `config.ru` and serves it on **WEBrick** through the exact
  `Rackup::Handler` path the `rackup` CLI uses. No Rails, no Sinatra.
- Stateless cookie session + **CSRF** protection (`src/security.rb`): every
  mutating request must echo the per-session token in the `X-CSRF-Token`
  header or `_csrf` body field.
- Projects and tasks with status/priority, search (`q`), and status/priority/
  project filters — all over a JSON API consumed by a small DOM-rendered client.
- Validated CRUD: blank/over-long/mistyped fields, invalid status/priority,
  malformed JSON, missing references and not-found resources all return
  meaningful JSON errors (400/404/405/503); output is escaped client-side by
  rendering via `textContent` only (no `innerHTML` with user data).
- Parameterized SQL everywhere (LIKE wildcards escaped) — no string-built
  queries from user input. Static assets are served from a fixed allowlist
  (`app.js`, `style.css`).
- Idempotent schema setup (`CREATE TABLE IF NOT EXISTS`) and repeatable seed
  data, guarded by a one-time seed flag so re-opens never duplicate rows.
- Persistence: explicit SQLite file (`DATA_DIR`/`DATABASE_PATH`); the app
  never stores permanent state in an ephemeral release directory.
- `/api/health/live` (process alive) and `/api/health/ready` (does a real
  database open + write; **503** while the database is unavailable).
- Non-sensitive release marker: `scripts/build.sh` writes a generated
  `VERSION` file (git SHA by default — `BUILD_MARKER` to override); the marker
  is served by `/api/meta` and shown in the UI. `VERSION` is a **build
  artifact** (gitignored) so the served marker always reflects the deployed
  revision rather than a frozen file.
- Graceful SIGTERM/SIGINT shutdown, one log line per request to stdout.

## Runtime and dependencies

- Ruby **3.2.3** validated (Ruby >= 3.1 supported; `Gemfile` pins the floor).
- **rack 3.2.7** (Rack interface), **rackup 2.3.1** + **webrick 1.9.2**
  (production server), **sqlite3 2.9.6** (SQLite persistence).
- `Gemfile.lock` pins the toolchain; `bundle install` reproduces it
  (`scripts/verify.sh` provisions a vendored bundle under `vendor/bundle`).

Runtime versions (this verification):

| Component | Version |
|-----------|---------|
| Ruby      | 3.2.3 |
| rack      | 3.2.7 |
| rackup    | 2.3.1 |
| webrick   | 1.9.2 |
| sqlite3   | 2.9.6 |
| SQLite    | 3.53.2 (bundled with the sqlite3 gem) |

## Quick start (development)

```bash
bundle install
cp .env.example .env       # review and adjust
bundle exec ruby server.rb            # or: bundle exec rackup -s webrick -o "$BIND_HOST" -p "$PORT" config.ru
```

Open http://localhost:8080 — the seeder has already created two demo projects
and a few tasks on first boot.

## Production start

```bash
bundle install             # or reuse the vendored bundle from scripts/verify.sh
scripts/build.sh           # writes VERSION release marker + runtime preflight
bundle exec ruby server.rb # production process (WEBrick -> config.ru)
```

- Binds to `BIND_HOST:PORT` (defaults **0.0.0.0:8080**).
- Run from the repository root so `./static` (UI assets), `VERSION` and the
  default `./data` directory resolve correctly.
- Logs go to stdout/stderr; the process answers SIGTERM/SIGINT with a clean
  exit.

## Health and readiness

| Endpoint | Meaning |
|----------|---------|
| `GET /api/health/live`  | Process is alive (always 200 while serving). |
| `GET /api/health/ready` | Opens the SQLite file and performs a write + read; **503** when the database is unavailable, with a `status: "unavailable"` body and the underlying reason. |

`/api/health/ready` is a genuine dependency probe (fresh connection, real
write), not a static marker. `scripts/smoke.sh` proves it: it starts the
process against a database path that cannot be opened (its parent is a regular
file), observes readiness drop to 503 while liveness stays 200 and the static
UI keeps serving, then repairs the path and proves readiness recovers.

## Environment variables

See `.env.example` for the full commented list.

| Variable | Required | Default | Purpose |
|----------|----------|---------|---------|
| `PORT` | no | `8080` | bind port |
| `BIND_HOST` | no | `0.0.0.0` | bind address |
| `DATA_DIR` | no | `<repo>/data` | base data directory |
| `DATABASE_PATH` | no | `<DATA_DIR>/taskboard.db` | **persistent SQLite path** |
| `BUILD_MARKER` | no | git SHA | release marker in `/api/meta` and the UI footer |
| `BASE_PATH` | no | `` | optional URL prefix the app is served under |

No credentials or secrets are committed or required.

## Persistence

Data lives in the SQLite file at `DATABASE_PATH`, which defaults under
`DATA_DIR` (gitignored). For redeploys that reuse or replace the release
directory, mount a persistent volume at `DATA_DIR`/`DATABASE_PATH` so the
file survives. `scripts/smoke.sh` proves persistence: it creates a
"PERSIST" survivor task over HTTP, gracefully stops the production process,
restarts it on the **same database path**, and verifies the record is still
served with stable counts.

## Schema

Created by `src/db.rb` (`CREATE TABLE IF NOT EXISTS`, idempotent):

- `project` — id, name, description, status (`active|archived`), timestamps.
- `task` — id, `project_id` FK (`ON DELETE CASCADE`), title, description,
  status (`todo|in_progress|done`), priority (`low|medium|high`), timestamps.
- `seed_flag` — marks the one-time seed as applied.
- `heartbeat` — backing table for the readiness write probe.

Seeding is repeatable: the second and subsequent `open` calls never add rows
(`tests/run_tests.rb` asserts seed idempotency).

## API

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/health/live` | liveness |
| GET | `/api/health/ready` | readiness (DB probe) |
| GET | `/api/meta` | release marker + runtime versions |
| GET | `/api/csrf` | echo the session CSRF token |
| GET/POST | `/api/projects` | list / create projects |
| GET/PATCH/DELETE | `/api/projects/:id` | read / update / delete a project |
| GET/POST | `/api/tasks` | list (filters `q`, `status`, `priority`, `project_id`) / create tasks |
| GET/PATCH/DELETE | `/api/tasks/:id` | read / update / delete a task |

The UI at `/` consumes the same JSON API.

## Automated verification

```bash
scripts/verify.sh
```

Runs, in order:

1. Provisions the vendored bundle (`vendor/bundle` via `Gemfile.lock`) if
   missing.
2. `scripts/build.sh` — writes the `VERSION` release marker.
3. Ruby syntax check on `src/**/*.rb`, `config.ru`, `server.rb`,
   `tests/run_tests.rb` (plus a client JS check when `node` is available).
4. `ruby tests/run_tests.rb` — dependency-free unit/integration suite against
   the exact `API.dispatch` router with a real SQLite file: CRUD,
   search/filter, validation negatives (blank/over-long/mistyped fields,
   invalid status/priority, malformed JSON, missing project, empty PATCH,
   404s), LIKE-wildcard escaping, schema/seed idempotency, restart-style
   persistence, and readiness that genuinely drops to 503 when the database
   is unavailable.
5. `scripts/smoke.sh` — real production process (WEBrick -> config.ru):
   liveness/readiness, CRUD over HTTP with CSRF, search/status filters,
   release marker, negative cases, graceful stop → restart persistence,
   database-unavailable readiness (503) and recovery.

Exit 0 only when every check passes.

## Repository layout

```
config.ru       canonical Rack entry point (served by server.rb / rackup)
server.rb       production launcher (WEBrick via Rackup::Handler)
src/            config.rb (env), db.rb (schema/seed/probe), security.rb
                (cookie session + CSRF), app.rb (Rack callable/router),
                api.rb (JSON router + validated CRUD)
tests/          run_tests.rb dependency-free suite against API.dispatch
scripts/        build.sh (VERSION marker + preflight), smoke.sh (production
                check with guaranteed cleanup), verify.sh (full verification)
static/         DOM-rendered UI (app.js, style.css)
Gemfile         Ruby >= 3.1 + pinned rack/rackup/webrick/sqlite3
Gemfile.lock    locked toolchain (committed)
```

## License

MIT — see [LICENSE](LICENSE). This fixture is part of the MIT-licensed
[xCloud app-compatibility suite](https://github.com/xCloudNobin/app-compatibility).