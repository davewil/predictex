# Auth design — predictex (predictex-5gw)

## Context

predictex is a private ~15-person FIFA World Cup 2026 predictor league on a public
URL (`wc-predict.davewil.dev`). Today there is **no application auth**: the leaderboard
is public, and `players` is a minimal table (`display_name`, `is_admin`, optional
`email`) with nothing authenticating against it. We need login so members can own and
self-manage their predictions, with the admin able to act on their behalf later.

This auth work (`5gw`) is the gate before the *My Predictions* (`79q`) and *Admin*
(`a02`) LiveViews.

## Settled decisions

| Decision | Choice |
|---|---|
| Who logs in | **Hybrid** — members self-manage; admin can act on their behalf (the on-behalf editing lands in `a02`, this lays the foundation) |
| Mechanism | **Email + password, register-and-go** (same as slackex): Bcrypt, **no email confirmation** |
| Mailer | **None.** No email is sent anywhere. Magic-link/email login is a deliberate *later* upgrade |
| Registration gate | **Shared league invite code** (env `LEAGUE_INVITE_CODE`) — keeps strangers off a public URL |
| Leaderboard `/` | Stays **public** |
| Admin | `is_admin` boolean on player; enforced by an `on_mount` for admin-only LiveViews |

## Approach: `phx.gen.auth`, password path, auto-confirm

Phoenix 1.8 `phx.gen.auth` is magic-link + mandatory email confirmation **by default**;
password registration is a documented optional add-on. Vanilla gen.auth therefore needs
email, which we don't have. Fastest path that meets the requirements:

1. Run `mix phx.gen.auth Accounts Player players` for the **security-sensitive plumbing**
   (token table, `PlayerAuth` plug + `on_mount` hooks, session controller, generated
   tests) — the parts not worth hand-writing.
2. Apply Phoenix's documented **"mixing magic link and password registration"** option so
   registration takes a password.
3. **Auto-confirm on registration** — set `confirmed_at = now` at create time, so a member
   registers and is logged straight in with no email round-trip.
4. Leave the magic-link/email code in place but **hidden** (the "add email later" path).

Because there is **no data anywhere yet** (prod DB is created fresh on first deploy; dev/
test are disposable), we **regenerate the `players` table** rather than reconcile an
`ALTER`: delete the placeholder `players` migration + minimal `Player`/`Accounts`, let the
generator own `players`, then re-add `display_name` + `is_admin`, and **renumber** the
generated migration so `players` precedes `fixtures` and `predictions` (which FK to it).

This is judged faster and lower-risk than porting slackex's modules (copy-and-strip its
Cloak-encrypted email, separate `username`, Guardian/API, FunWithFlags by hand) or
hand-rolling token/session security.

## Components

### Schema — `players` (regenerated) + `players_tokens`
Final `players` columns: `email` (citext, unique, required), `hashed_password` (required —
password reg enabled), `display_name`, `is_admin` (default false), `confirmed_at`,
timestamps. `players_tokens` is the generated session/token table. `predictions.player_id`
FK is unchanged. We drop slackex's `username` and email-at-rest encryption (YAGNI for a
friends game): log in by email, display `display_name`.

### Registration — invite-code gated, auto-confirm
`RegistrationLive`: `email`, `password`, `display_name`, and an **invite code** field. The
changeset/context rejects the registration unless the code matches `LEAGUE_INVITE_CODE`
(read from env via runtime config). On success, set `confirmed_at = now` and start a
session — no email.

### Login
Email + password → session token via the generated `PlayerAuth`. The magic-link UI is
removed from the login page for now.

### Routing / auth plumbing
- `/` (leaderboard) stays in a public scope.
- A `:require_authenticated` scope for prediction routes (built out in `79q`).
- `current_scope` / `current_player` assigned by the generated `fetch_current_player`
  plug and `on_mount`.

### Admin gating + bootstrap
- An `on_mount(:require_admin)` hook checks `current_scope.player.is_admin` for admin-only
  LiveViews (the Admin LiveView itself is `a02`).
- Bootstrap: a `mix predictex.promote_admin <email>` task (and an equivalent release-eval
  for prod) so you promote yourself after registering. No "first user is admin" magic.

## Data-contract / test reconciliation
Existing tests create players via `Accounts.create_player(%{display_name: ...})`. After
regeneration, players require `email` + `password`, so those call sites move to the
generated `Accounts` registration / test fixture (`player_fixture`). Standings and
Predictions tests are updated to build players through the real registration path, not a
hand-crafted insert — keeping test fixtures honest about how players are actually created.

## Configuration
- New secret **`LEAGUE_INVITE_CODE`** — added to the GitHub Actions secrets, the prod
  compose env, and dev/test config (a known value in test).

## Out of scope (deferred)
- **Email / magic-link login** — the generated code stays but stays hidden until a mailer
  (provider + SPF/DKIM/DMARC on `davewil.dev`) is set up. Tracked as a follow-up.
- **Admin-acts-on-behalf editing** — belongs to the Admin LiveView (`a02`).
- Password reset (needs email), avatars, profiles.

## Testing
- Keep the generator's auth tests (registration, login, session, token expiry).
- Add: invite-code accept/reject, auto-confirm (registered player can log in immediately
  with no confirmation step), `on_mount(:require_admin)` allows admin / blocks non-admin,
  and that `/` remains reachable while logged out.
