# Dashboard live tick — auto-enable Match Preview at −30 min

**Date:** 2026-06-19
**Surface:** `/predictions` (`PredictexWeb.MyPredictionsLive`)
**Status:** design approved, pending implementation plan

## Problem

On the `/predictions` dashboard, each fixture card shows a "Match preview" drill-down
link only once the fixture is within 30 minutes of kickoff; before that it shows the
"Edit on FIFA" fallback. The gate is a pure clock predicate:

```elixir
# my_predictions_live.ex
live_cta?={Predictions.cta_window?(fx.fixture, @now)}

# predictions.ex
@cta_lead_seconds 30 * 60
def cta_window?(%Fixture{kickoff_at: ko}, now),
  do: DateTime.compare(now, DateTime.add(ko, -@cta_lead_seconds, :second)) != :lt
```

The defect is `@now`: it is captured once at `mount` (`DateTime.utc_now()`) and never
advances. A player who loads the page 40 minutes before kickoff sees `cta_window?` as
`false` for the life of the LiveView process — the preview link never auto-enables. They
must manually refresh past the −30 min mark. The websocket is connected and idle; nothing
tells the server the clock moved.

The same frozen `@now` (and the `dash` struct built from it at mount) means the
Open → 🔒 Locked badge, live scores, and the post-match recap state are all static until a
manual refresh.

## Goal

The dashboard re-renders itself over the existing websocket as wall-clock thresholds pass:

- "Match preview" auto-enables at −30 min (the originating request),
- Open → 🔒 Locked flips at kickoff,
- live scores refresh while a match is in play,
- recap state appears at full time,

with no page refresh, and **self-terminating** once the round is settled so an idle tab
stops polling.

## Decisions

- **Full re-pull on each tick (Option B).** The tick re-runs `Dashboard.for_player/2`, so
  every `now`-derived field refreshes (preview link, lock badge, scores, recap), not just
  the preview link. Cost is ~7 queries per tick per connected tab — trivial at private-league
  scale (≈7 players).
- **Self-pacing timer, not a fixed-interval poll.** A fixed 30s poll cannot honor both
  "30s cadence" and "self-terminate when idle": during the tournament a tab open overnight
  with fixtures scheduled for the next day is never `completed`, so a naive `settled?` guard
  would poll all night. Instead a pure `next_tick_delay/2` sleeps exactly until the next
  thing that can change — 30s while a match is live, the exact gap to the next −30 min /
  kickoff threshold otherwise, and `nil` (stop) once every fixture is completed.
- **All-rounds scope.** `next_tick_delay/2` considers fixtures across every round in the
  dash, not just the active one — the next-match banner spans rounds and the user can switch
  round tabs without a remount.

## Design

### 1. `Predictex.Dashboard.next_tick_delay/2` (pure)

Lives beside `next_match/2` and `upcoming?/2`. Keeps the timing decision in the domain
layer so the LiveView stays a thin pipe over validated data (per the anti-corruption rule
in CLAUDE.md). Returns the ms until the soonest re-render this dashboard needs, or `nil`
when nothing ever will.

```elixir
@live_poll_ms 30_000
@preview_lead 30 * 60

# ms until this fixture next changes what we render, or nil
defp fixture_delay(%{status: :completed}, _now), do: nil
defp fixture_delay(%{fixture: %{kickoff_at: nil}}, _now), do: nil

defp fixture_delay(%{fixture: %{kickoff_at: ko}}, now) do
  preview_at = DateTime.add(ko, -@preview_lead, :second)

  cond do
    DateTime.compare(now, ko) != :lt -> @live_poll_ms              # in play → poll score
    DateTime.compare(now, preview_at) != :lt -> ms_until(ko, now)  # preview open → next event is lock
    true -> ms_until(preview_at, now)                              # next event is preview opening
  end
end

def next_tick_delay(dash, now) do
  dash.rounds
  |> Enum.flat_map(& &1.fixtures)
  |> Enum.map(&fixture_delay(&1, now))
  |> Enum.reject(&is_nil/1)
  |> case do
    [] -> nil
    delays -> max(Enum.min(delays), 1_000)
  end
end

defp ms_until(at, now), do: DateTime.diff(at, now, :millisecond)
```

Notes:

- "In play" is `now >= kickoff and status != :completed` — the first `cond` branch is only
  reached for non-completed fixtures (completed short-circuits in `fixture_delay/2`), so a
  passed kickoff that is not yet completed is live and polls at 30s until it completes.
- The `max(_, 1_000)` floor avoids a busy-spin when `now` is within a second of a threshold
  (`ms_until` can be ≤ 0 by the time the handler runs).
- A nil-kickoff fixture (e.g. a knockout slot before teams are known) contributes no
  threshold — consistent with the existing `kickoff_at: nil` guards in `cta_window?/2`,
  `locked?/2`, and `upcoming?/2`.

### 2. `PredictexWeb.MyPredictionsLive`

```elixir
def mount(_params, _session, socket) do
  now = DateTime.utc_now()
  dash = Dashboard.for_player(socket.assigns.current_scope.player, now)
  # ... existing assigns ...
  if connected?(socket), do: schedule_next_tick(dash, now)
  {:ok, socket}
end

defp schedule_next_tick(dash, now) do
  case Dashboard.next_tick_delay(dash, now) do
    nil -> :ok
    ms -> Process.send_after(self(), :tick, ms)
  end
end

def handle_info(:tick, socket) do
  now = DateTime.utc_now()
  dash = Dashboard.for_player(socket.assigns.current_scope.player, now)
  schedule_next_tick(dash, now)

  {:noreply,
   socket
   |> assign(now: now, dash: dash)
   |> assign(:next_match, Dashboard.next_match(dash, now))}
end
```

- `connected?/1` guard → no timer during the dead static mount.
- The tick refreshes `now`, `dash`, and `next_match` only. It deliberately does **not**
  reassign `active_ordinal` — that holds the user's round-tab selection. Confirmed safe: the
  round-tab highlight reads `@active_ordinal` (not `dash.rounds[].active?`), so a re-pull
  cannot yank the user's tab.
- When the last pending fixture completes, that tick's `next_tick_delay` returns `nil` and no
  further tick is scheduled — polling stops on its own.

### 3. Data flow

```
self-paced timer → :tick → DateTime.utc_now()
  → Dashboard.for_player(player, now)        # fresh now-derived view model
  → re-render → LiveView diff pushed over the existing websocket
  → schedule_next_tick(dash, now)            # sleep until the next threshold, or stop
```

The clock-crossing logic is unchanged — `cta_window?/2` and `locked?/2` already take an
injected `now`. The change feeds them a *fresh* `now` periodically instead of a frozen one.

### 4. Error handling

`Dashboard.for_player/2` is the same call `mount` already trusts; the tick adds no new
failure surface. The guard chain short-circuits on an empty dashboard: `rounds == []` →
`flat_map` yields `[]` → `next_tick_delay` returns `nil` → no tick scheduled.

### 5. Testing

**Domain (`test/predictex/dashboard_test.exs`)** — `next_tick_delay/2` table:

| dashboard state | expected |
| --- | --- |
| no rounds (`[]`) | `nil` |
| all fixtures completed | `nil` |
| upcoming, before −30 min window | ms until `kickoff − 30 min` |
| upcoming, inside −30 min window | ms until `kickoff` |
| in play (kickoff passed, not completed) | `30_000` |
| nil-kickoff fixtures only | `nil` |
| mixed | the minimum of the above, floored at `1_000` |

**LiveView (`test/predictex_web/live/my_predictions_live_test.exs`)** — mount connected,
mutate the fixture in the DB (mark live / set score / mark completed), `send(lv.pid, :tick)`,
assert the re-rendered HTML reflects the new state. This proves the tick re-pulls and
re-renders without depending on wall-clock advancement (non-flaky). The "preview link flips
at exactly −30 min" guarantee is carried by the existing `cta_window?/2` unit tests plus the
`next_tick_delay/2` threshold table above.

## Deferred option — PubSub for live scores

Live-score changes are already a *data* event broadcast on the `fifa:snapshots` PubSub topic,
which `FixtureLive` subscribes to (`fixture:#{id}`). If `MyPredictionsLive` subscribed too,
the timer's only responsibility would be the two clock thresholds (−30 min and kickoff) — the
30s score-polling branch in `next_tick_delay/2` would be removed, giving instant live updates
and zero polling.

Not built now: it is more than the originating request needs, and the 30s poll is cheap at
league scale. **Requirements to take it later:**

- Subscribe `MyPredictionsLive` to the relevant fixture/snapshot topic(s) on connected mount
  (the dashboard spans many fixtures, so either a single aggregate topic or per-fixture
  subscriptions for the in-play set).
- Add a `handle_info` for the snapshot/live-update message that re-pulls (or patches) `dash`.
- Drop the `@live_poll_ms` branch from `fixture_delay/2`; the timer then only ever sleeps to
  the next −30 min or kickoff threshold.
- A live match would no longer hold the timer awake at 30s — confirm `next_tick_delay/2`
  still schedules correctly when the only pending work is clock thresholds.

## Out of scope

- Changes to `FixtureLive` (already live via its own PubSub subscription).
- Changes to the client-side `.Countdown` hook (cosmetic countdown text; unrelated to the
  server-rendered link/badge flip).
- Any change to the scoring or capture pipeline.
