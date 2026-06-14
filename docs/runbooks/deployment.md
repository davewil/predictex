# Deployment

Predictex deploys to the homelab Docker host (`192.168.1.102`, reached over Tailscale)
behind caddy-docker-proxy, served at **https://wc-predict.davewil.dev**. The pattern
mirrors slackex, stripped to a single app node + Postgres.

## How it works

`.github/workflows/ci-deploy.yml` has two jobs:

- **Quality** — runs on every push/PR to `main`: `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix deps.unlock --check-unused`, `mix test` (against a
  Postgres service).
- **Deploy** — runs only on a `v*` tag: builds the release image, pushes it to
  `ghcr.io/davewil/predictex` (`:latest` + `:vX.Y.Z`), connects to the host over Tailscale,
  then over SSH: backs up the DB, pulls the image, **boot-checks the release**, migrates,
  recreates the app container, and smoke-tests `/health`. The boot check aborts the deploy
  before any change if the release can't start.

caddy-docker-proxy auto-discovers the app via its labels and issues a TLS cert for
`wc-predict.davewil.dev` through the existing Cloudflare DNS challenge — no proxy restart
needed.

## Release a deploy

```bash
git tag v0.1.0
git push origin v0.1.0
```

## Required GitHub Actions secrets

Set on the `davewil/predictex` repo (Settings → Secrets → Actions). The homelab-shared
ones are the same values used by slackex.

| Secret | What |
|---|---|
| `DEPLOY_HOST` | Docker host address (Tailscale name/IP of 192.168.1.102) |
| `DEPLOY_SSH_KEY` | Private SSH key authorized as `root` on the host |
| `TS_OAUTH_CLIENT_ID` | Tailscale OAuth client id (tag:ci) |
| `TAILSCALE_AUTHKEY` | Tailscale OAuth secret |
| `SECRET_KEY_BASE` | Phoenix secret — generate with `mix phx.gen.secret` |
| `POSTGRES_PASSWORD` | Password for the prod `postgres` role (avoid `\|` — used as a sed delimiter) |

`GITHUB_TOKEN` is provided automatically and is used to push/pull the GHCR image.

## Server prerequisites (already true for the homelab)

- **caddy-docker-proxy** running at `/root/caddy/` on the `proxy` (external) network, with
  `CF_API_TOKEN` in `/root/caddy/.env` for the Cloudflare DNS challenge.
- The external `proxy` Docker network exists (`docker network create proxy`).
- `fix-dns.service` keeps DNS working after VM reboots (installed by the slackex deploys).
- DNS: `wc-predict.davewil.dev` resolves (record created in Cloudflare).

The app's own `/root/predictex/.env` (`SECRET_KEY_BASE`, `POSTGRES_PASSWORD`) and
`docker-compose.prod.yml` are written/synced by the deploy job — nothing to set up by hand.

## First deploy notes

- The app container creates `predictex_prod` and runs migrations automatically (boot check
  → `Predictex.Release.migrate()`), so no manual `ecto.create` is needed.
- Seed fixtures after the first deploy by running the ingest inside the container:
  `docker compose -f docker-compose.prod.yml exec app bin/predictex eval "Predictex.Results.Ingest.sync_from_url()"`.
