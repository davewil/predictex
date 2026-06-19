# Dashboard live tick Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `/predictions` re-render itself over the existing websocket as wall-clock thresholds pass, so the "Match preview" link auto-enables 30 min before kickoff (and the lock badge, scores, and recap state all update) with no page refresh.

**Architecture:** A new pure `Dashboard.next_tick_delay/2` returns the milliseconds until the dashboard next needs a re-render — 30s while a match is live, the exact gap to the next −30 min / kickoff threshold otherwise, `nil` once settled. `MyPredictionsLive` schedules a `Process.send_after(self(), :tick, ms)` off that delay on connected mount and reschedules from each `:tick` (which re-pulls `Dashboard.for_player`), self-terminating when `next_tick_delay` returns `nil`.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto. Spec: `docs/superpowers/specs/2026-06-19-dashboard-live-tick-design.md`.

## Global Constraints

- The pre-commit gate (`mix precommit`) runs automatically on any commit that stages `*.{ex,exs}`: `compile --warnings-as-errors`, `deps.unlock --check-unused`, `format --check-formatted`, `credo --strict`, `test`. Never bypass it (`--no-verify` is blocked).
- Credo: max nesting depth 3 (a single `cond` inside a function is fine).
- Run `mix format` before committing Elixir changes so `format --check-formatted` passes in the gate.
- **Do not `git push` and do not tag** — commits stay local; push/deploy is the user's explicit call.
- `test/predictex/dashboard_test.exs` is `async: true`; `test/predictex_web/live/my_predictions_live_test.exs` is `async: false`. Keep both as-is.
- The preview/CTA lead time has one source of truth: `Predictex.Predictions`'s `@cta_lead_seconds` (`30 * 60`). Do not re-introduce a second literal.

---

## File Structure

- `lib/predictex/predictions.ex` — expose the existing `@cta_lead_seconds` via a public `cta_lead_seconds/0` accessor (no behaviour change to `cta_window?/2`).
- `lib/predictex/dashboard.ex` — add pure `next_tick_delay/2` plus a private `fixture_delay/2`, beside `next_match/2`/`upcoming?/2`.
- `lib/predictex_web/live/my_predictions_live.ex` — schedule the self-paced tick on connected mount; add `handle_info(:tick, ...)` and a private `schedule_next_tick/2`.
- `test/predictex/dashboard_test.exs` — `describe "next_tick_delay/2"` table.
- `test/predictex_web/live/my_predictions_live_test.exs` — one test proving the tick re-pulls and re-renders.

---

## Task 1: Domain timing — `Predictions.cta_lead_seconds/0` + `Dashboard.next_tick_delay/2`

**Files:**
- Modify: `lib/predictex/predictions.ex` (near `@cta_lead_seconds`, ~line 132)
- Modify: `lib/predictex/dashboard.ex` (after `next_match/2` and the `upcoming?/2` clauses, ~line 97–101)
- Test: `test/predictex/dashboard_test.exs` (new `describe` block at end of file)

**Interfaces:**
- Produces: `Predictex.Predictions.cta_lead_seconds() :: integer` (seconds, `1800`).
- Produces: `Predictex.Dashboard.next_tick_delay(dash :: map, now :: DateTime.t()) :: non_neg_integer() | nil` — ms until the next re-render is needed, floored at `1_000`; `nil` when no fixture is time-sensitive.
- Consumes: the dashboard view model from `Dashboard.build/4` — `dash.rounds` is a list of `%{fixtures: [...]}`, each fixture-view is `%{fixture: %Fixture{kickoff_at:}, status:, ...}`.

- [ ] **Step 1: Write the failing tests**

Append to `test/predictex/dashboard_test.exs` (the file already aliases `Predictex.Dashboard` and `Predictex.Tournament.{Round, Fixture}`, and defines `dt/1` and `round_with/3`). First add a module-level helper next to `dt/1`/`round_with/3` (a `defp` must live at module level, NOT inside `describe`):

```elixir
  defp build_dash(rounds),
    do: Dashboard.build(rounds, %{}, %{entry: nil, rank: 1, of: 1}, ~U[2026-06-15 12:00:00Z])
```

Then add the `describe` block at the end of the file:

```elixir
  describe "next_tick_delay/2" do
    test "nil when there are no rounds" do
      dash = build_dash([])
      assert Dashboard.next_tick_delay(dash, dt(0)) == nil
    end

    test "nil when every fixture is completed" do
      done = %Fixture{
        id: 1,
        round_id: 1,
        status: :completed,
        home_goals: 1,
        away_goals: 0,
        kickoff_at: dt(-3600)
      }

      dash = build_dash([round_with(1, :group, [done])])
      assert Dashboard.next_tick_delay(dash, dt(0)) == nil
    end

    test "nil when the only fixtures have no kickoff time" do
      tbc = %Fixture{id: 1, round_id: 1, status: :scheduled, kickoff_at: nil}
      dash = build_dash([round_with(1, :group, [tbc])])
      assert Dashboard.next_tick_delay(dash, dt(0)) == nil
    end

    test "gap to the preview window when more than 30 min before kickoff" do
      # kickoff in 1h; the preview opens 30 min before → 1_800_000 ms away
      fx = %Fixture{id: 1, round_id: 1, status: :scheduled, kickoff_at: dt(3600)}
      dash = build_dash([round_with(1, :group, [fx])])
      assert Dashboard.next_tick_delay(dash, dt(0)) == 1_800_000
    end

    test "gap to kickoff once inside the 30 min preview window" do
      # kickoff in 10m; preview already open → next event is the lock at kickoff
      fx = %Fixture{id: 1, round_id: 1, status: :scheduled, kickoff_at: dt(600)}
      dash = build_dash([round_with(1, :group, [fx])])
      assert Dashboard.next_tick_delay(dash, dt(0)) == 600_000
    end

    test "30s while a match is in play (kickoff passed, not completed)" do
      fx = %Fixture{id: 1, round_id: 1, status: :live, kickoff_at: dt(-60)}
      dash = build_dash([round_with(1, :group, [fx])])
      assert Dashboard.next_tick_delay(dash, dt(0)) == 30_000
    end

    test "takes the soonest threshold across all rounds" do
      near = %Fixture{id: 1, round_id: 1, status: :scheduled, kickoff_at: dt(2400)}
      far = %Fixture{id: 2, round_id: 2, status: :scheduled, kickoff_at: dt(7200)}
      dash = build_dash([round_with(1, :group, [near]), round_with(2, :group, [far])])
      # near: preview opens in 2400 - 1800 = 600s → 600_000 ms (the minimum)
      assert Dashboard.next_tick_delay(dash, dt(0)) == 600_000
    end

    test "floors a sub-second threshold at 1000 ms" do
      ko = ~U[2026-06-15 12:00:00Z]
      now = ~U[2026-06-15 11:59:59.500Z]
      fx = %Fixture{id: 1, round_id: 1, status: :scheduled, kickoff_at: ko}
      dash = build_dash([round_with(1, :group, [fx])])
      # preview opened 30 min ago; the lock is 500 ms away → floored
      assert Dashboard.next_tick_delay(dash, now) == 1_000
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/predictex/dashboard_test.exs`
Expected: FAIL — `(UndefinedFunctionError) function Predictex.Dashboard.next_tick_delay/2 is undefined`.

- [ ] **Step 3: Expose the CTA lead constant in `Predictions`**

In `lib/predictex/predictions.ex`, the constant already exists:

```elixir
  # The live drill-down (FixtureLive) CTA opens this long before kickoff.
  @cta_lead_seconds 30 * 60
```

Add a public accessor directly beneath it (leave `cta_window?/2` unchanged):

```elixir
  @doc "Seconds before kickoff that the preview / live drill-down CTA window opens."
  def cta_lead_seconds, do: @cta_lead_seconds
```

- [ ] **Step 4: Implement `next_tick_delay/2` in `Dashboard`**

In `lib/predictex/dashboard.ex`, after the `upcoming?/2` clauses (around line 101), add. `Predictex.Predictions` is already aliased as `Predictions` in this module (used by `fixture_view/4`).

```elixir
  @live_poll_ms 30_000

  @doc """
  Milliseconds until this dashboard next needs a re-render, or `nil` when nothing
  time-sensitive remains (every fixture completed or without a kickoff).

  Drives the self-paced tick on `/predictions` (predictex live-tick): `30_000` while a
  match is in play (score refresh), otherwise the exact gap to the next preview-open
  (`kickoff − cta_lead_seconds`) or kickoff-lock threshold across all rounds, floored at
  `1_000` ms. Pure — the caller supplies `now`.
  """
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

  defp fixture_delay(%{status: :completed}, _now), do: nil
  defp fixture_delay(%{fixture: %{kickoff_at: nil}}, _now), do: nil

  defp fixture_delay(%{fixture: %{kickoff_at: ko}}, now) do
    preview_at = DateTime.add(ko, -Predictions.cta_lead_seconds(), :second)

    cond do
      DateTime.compare(now, ko) != :lt -> @live_poll_ms
      DateTime.compare(now, preview_at) != :lt -> DateTime.diff(ko, now, :millisecond)
      true -> DateTime.diff(preview_at, now, :millisecond)
    end
  end
```

- [ ] **Step 5: Format**

Run: `mix format lib/predictex/predictions.ex lib/predictex/dashboard.ex test/predictex/dashboard_test.exs`

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix test test/predictex/dashboard_test.exs`
Expected: PASS (all `next_tick_delay/2` tests green, existing tests still green).

- [ ] **Step 7: Commit**

```bash
git add lib/predictex/predictions.ex lib/predictex/dashboard.ex test/predictex/dashboard_test.exs
git commit -m "feat(dashboard): next_tick_delay/2 — ms until the next live-tick re-render

Pure domain fn: 30s while a match is live, exact gap to the next preview-open
(kickoff − cta_lead_seconds) or kickoff-lock threshold across all rounds, nil
once settled. Exposes Predictions.cta_lead_seconds/0 so the 30-min lead has one
source of truth.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

(The pre-commit gate runs `mix precommit` automatically; it must pass.)

---

## Task 2: Wire the self-paced tick into `MyPredictionsLive`

**Files:**
- Modify: `lib/predictex_web/live/my_predictions_live.ex` (`mount/3` ~line 13–26; add `handle_info/2` and `schedule_next_tick/2`)
- Test: `test/predictex_web/live/my_predictions_live_test.exs` (new test; file imports `Phoenix.LiveViewTest` and `Predictex.AccountsFixtures`, aliases `Predictex.{Predictions, Tournament}`, defines `fixture!/2`, `setup` yields `%{round: round}`)

**Interfaces:**
- Consumes: `Dashboard.next_tick_delay/2` (Task 1) and the existing `Dashboard.for_player/2` and `Dashboard.next_match/2`.
- Produces: `MyPredictionsLive` now responds to `:tick` messages by re-pulling and re-rendering; no public interface for later tasks.

- [ ] **Step 1: Write the failing test**

Append to `test/predictex_web/live/my_predictions_live_test.exs` (before the final `end`):

```elixir
  test "a :tick re-pulls and re-renders the dashboard without a page reload",
       %{conn: conn, round: round} do
    player = player_fixture(%{display_name: "Ticker"})
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    fx = fixture!(round, %{team1: "Spain", team2: "Japan", kickoff_at: future})

    {:ok, _} =
      Predictions.admin_upsert_prediction(%{
        player_id: player.id,
        fixture_id: fx.id,
        home_goals: 0,
        away_goals: 0
      })

    {:ok, lv, html} = conn |> log_in_player(player) |> live(~p"/predictions")
    refute html =~ "LIVE"

    # the match goes live in the DB after mount …
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

    fx
    |> Ecto.Changeset.change(%{
      kickoff_at: past,
      status: :live,
      is_live: true,
      live_home_goals: 2,
      live_away_goals: 1,
      live_minute: "67'"
    })
    |> Predictex.Repo.update!()

    # … and the next tick reflects it over the socket, no remount
    send(lv.pid, :tick)
    rendered = render(lv)

    assert rendered =~ "LIVE"
    assert rendered =~ "2-1"
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/predictex_web/live/my_predictions_live_test.exs:NN` (use the new test's line number)
Expected: FAIL — the assertion `rendered =~ "LIVE"` is false, because with no `handle_info(:tick, …)` the message is ignored and the view never re-pulls the now-live fixture.

- [ ] **Step 3: Schedule the tick on connected mount**

In `lib/predictex_web/live/my_predictions_live.ex`, change `mount/3` so it schedules a tick once connected. Current body computes `now`, `dash`, `active`, then returns `{:ok, socket |> assign(...)}`. Insert the guard after `active` is computed and before the return:

```elixir
  @impl true
  def mount(_params, _session, socket) do
    now = DateTime.utc_now()
    dash = Dashboard.for_player(socket.assigns.current_scope.player, now)
    active = Enum.find_value(dash.rounds, fn r -> r.active? && r.round.ordinal end)

    if connected?(socket), do: schedule_next_tick(dash, now)

    {:ok,
     socket
     |> assign(:page_title, "My Predictions")
     |> assign(:dash, dash)
     |> assign(:active_ordinal, active)
     |> assign(:now, now)
     |> assign(:next_match, Dashboard.next_match(dash, now))
     |> assign(:fifa_url, Application.get_env(:predictex, :fifa_predictor_url))}
  end
```

- [ ] **Step 4: Add the `:tick` handler and scheduler**

Add immediately after the existing `handle_event("select_round", …)` clause in the same module:

```elixir
  @impl true
  def handle_info(:tick, socket) do
    now = DateTime.utc_now()
    dash = Dashboard.for_player(socket.assigns.current_scope.player, now)
    schedule_next_tick(dash, now)

    {:noreply,
     socket
     |> assign(:now, now)
     |> assign(:dash, dash)
     |> assign(:next_match, Dashboard.next_match(dash, now))}
  end

  defp schedule_next_tick(dash, now) do
    case Dashboard.next_tick_delay(dash, now) do
      nil -> :ok
      ms -> Process.send_after(self(), :tick, ms)
    end
  end
```

Note: the handler deliberately does **not** reassign `:active_ordinal`, preserving the user's selected round tab (the tab highlight reads `@active_ordinal`, not `dash.rounds[].active?`).

- [ ] **Step 5: Format**

Run: `mix format lib/predictex_web/live/my_predictions_live.ex test/predictex_web/live/my_predictions_live_test.exs`

- [ ] **Step 6: Run the test to verify it passes**

Run: `mix test test/predictex_web/live/my_predictions_live_test.exs`
Expected: PASS (the new tick test green, all existing dashboard LiveView tests still green).

- [ ] **Step 7: Run the full suite**

Run: `mix test`
Expected: PASS — no regressions.

- [ ] **Step 8: Commit**

```bash
git add lib/predictex_web/live/my_predictions_live.ex test/predictex_web/live/my_predictions_live_test.exs
git commit -m "feat(predictions): self-paced live tick re-renders the dashboard

On connected mount, schedule Process.send_after(:tick, Dashboard.next_tick_delay).
Each :tick re-pulls Dashboard.for_player and reschedules, self-terminating when
the delay is nil. Flips the Match-preview link at −30 min and refreshes the lock
badge, scores and recap over the socket — no page reload. Preserves the user's
selected round tab.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Frozen `@now` defect → fixed by Task 2 (re-pull on tick). ✓
- `next_tick_delay/2` (30s live / threshold gap / nil) → Task 1. ✓
- Self-terminate when settled → Task 1 `nil` branch + Task 2 `schedule_next_tick` no-op on `nil`. ✓
- All-rounds scope → Task 1 `flat_map` over `dash.rounds`. ✓
- Preserve `@active_ordinal` → Task 2 Step 4 note + handler omits it. ✓
- Connected-mount guard → Task 2 Step 3. ✓
- Domain test table + non-flaky LiveView test (`send(lv.pid, :tick)` after DB mutation) → Task 1 Step 1, Task 2 Step 1. ✓
- DRY on the 30-min lead → `Predictions.cta_lead_seconds/0`, Task 1 Steps 3–4. ✓
- Deferred PubSub option → recorded in the spec; intentionally not built here. ✓

**Placeholder scan:** none — every step has concrete code/commands.

**Type consistency:** `next_tick_delay/2` returns `non_neg_integer | nil`; `schedule_next_tick/2` matches on exactly `nil` vs `ms`. `cta_lead_seconds/0` returns seconds and is consumed via `DateTime.add(ko, -…, :second)`. `fixture_delay/2` clauses match the `%{status:, fixture: %{kickoff_at:}}` shape produced by `fixture_view/4`. Consistent across tasks.
