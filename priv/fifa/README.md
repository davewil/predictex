# FIFA reference snapshots (committed, grabbed once)

These are point-in-time captures of FIFA's **public, auth-free** Match Predictor reference JSON
(`https://play.fifa.com/json/match_predictor/`). They are committed so dev/test seeding is
**deterministic and offline** — nothing here is fetched live during `mix run priv/repo/seeds.exs`.

| File | Source | Used for |
|------|--------|----------|
| `rounds.json` | `.../rounds.json` | match `id` → round / teams / kickoff date (the `Fifa.Import` crosswalk) |
| `matchStats.json` | `.../matchStats.json` | `quickPicks` = the crowd's most-predicted scorelines — the demo player's "real" picks |

**Captured:** 2026-06-17 (group-stage entries populated; knockout rounds still empty upstream).

**To refresh** (only if FIFA's data changes materially):

```bash
curl -s https://play.fifa.com/json/match_predictor/rounds.json \
  | python3 -m json.tool > priv/fifa/rounds.json
curl -s https://play.fifa.com/json/match_predictor/matchStats.json \
  | python3 -m json.tool > priv/fifa/matchStats.json
```

> Live runtime fetching of `rounds.json` (for the real /import crosswalk) still happens via
> `Predictex.Fifa.Reference.fetch_rounds/0` — that path is unchanged. These files are a *seed-time*
> snapshot only.
