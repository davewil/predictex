# My Predictions Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a read-only personal "My Predictions" dashboard at `/predictions` showing a member's imported FIFA picks, their per-fixture scoring, and their league rank — World Cup themed.

**Architecture:** Gather → Decide → Act with a pure core. `Predictex.Standings` stays the single scoring authority (enriched additively); a new pure `Predictex.Dashboard` read model consumes its numbers and assembles a fully-shaped view so `PredictexWeb.MyPredictionsLive` only renders. No prediction *entry* anywhere here — that lives in `predictex-a02` (admin) and `predictex-xox` (import).

**Tech Stack:** Elixir 1.20 / OTP 28 (via `mise exec -- mix …`), Phoenix 1.8 LiveView, Ecto/Postgres, daisyUI/Tailwind. Spec: `docs/superpowers/specs/2026-06-15-my-predictions-design.md`.

**Conventions:**
- Always run mix via `mise exec -- mix …` (plain `mix` is the wrong version).
- Build test data through real paths only: players via `player_fixture`, fixtures via `Tournament.create_fixture`, predictions via `Predictions.create_prediction` (test-fixture-honesty rule).
- Commit after each task. Do not push (project rule: push only when the user asks).

---

## File Structure

- Modify `lib/predictex/standings.ex` — add `fixture_id` to breakdown entries + a `bonus_by_round` map (additive).
- Modify `test/predictex/standings_test.exs` — assert the enrichment.
- Modify `lib/predictex/predictions.ex` — add `list_player_predictions/1`.
- Create `lib/predictex/dashboard.ex` — read model (`for_player/2` edge + pure `build/4`).
- Create `test/predictex/dashboard_test.exs` — pure `build/4` + DB `for_player/2`.
- Create `lib/predictex_web/flags.ex` — `flag/1` (team name → emoji).
- Create `test/predictex_web/flags_test.exs`.
- Modify `config/config.exs` — `:fifa_predictor_url` default.
- Modify `config/runtime.exs` — `FIFA_PREDICTOR_URL` override.
- Modify `lib/predictex_web/player_auth.ex` — `signed_in_path/1` → `/predictions`.
- Modify auth tests (`registration_test`, `login_test`, `confirmation_test`, `player_session_controller_test`).
- Modify `lib/predictex_web/router.ex` — add `/predictions` route.
- Create `lib/predictex_web/live/my_predictions_live.ex` — the dashboard LiveView.
- Create `test/predictex_web/live/my_predictions_live_test.exs`.
- Modify `lib/predictex_web/components/layouts/root.html.heex` — cross-nav links.
- Issue hygiene: update `predictex-79q` and `predictex-a02` via `bd`.

---

## Task 1: Enrich `Standings` with per-fixture and per-round detail

**Files:**
- Modify: `lib/predictex/standings.ex:50-98`
- Test: `test/predictex/standings_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/predictex/standings_test.exs` (inside the existing `describe`/module — reuse its existing setup that creates players, a round, completed fixtures, and predictions). Append this test:

```elixir
test "breakdown entries carry fixture_id and bonus_by_round sums to round_bonus_total" do
  standings = Standings.leaderboard()
  first = hd(standings)

  # every scored entry knows which fixture it came from
  assert Enum.all?(first.breakdown, fn e -> is_integer(e.fixture_id) end)

  # the per-round bonus map sums back to the headline round_bonus_total
  assert first.bonus_by_round |> Map.values() |> Enum.sum() == first.round_bonus_total
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec -- mix test test/predictex/standings_test.exs`
Expected: FAIL — `first.breakdown` entries have no `:fixture_id` key (KeyError) and/or `bonus_by_round` is undefined.

- [ ] **Step 3: Implement the enrichment**

In `lib/predictex/standings.ex`, replace `score_player/3` and `round_bonus_total/2` with:

```elixir
  defp score_player(player, fixtures_by_id, rounds_meta) do
    scored =
      for prediction <- player.predictions,
          fixture = Map.get(fixtures_by_id, prediction.fixture_id),
          not is_nil(fixture) and fixture.status == :completed do
        %{
          ordinal: fixture.round.ordinal,
          fixture_id: prediction.fixture_id,
          result: Scoring.score(prediction, fixture, fixture.round.stage)
        }
      end

    fixtures_total = scored |> Enum.map(& &1.result.fixture_total) |> Enum.sum()
    bonus_by_round = bonus_by_round(scored, rounds_meta)
    round_bonus_total = bonus_by_round |> Map.values() |> Enum.sum()

    %{
      player_id: player.id,
      name: player.display_name,
      fixtures_total: fixtures_total,
      round_bonus_total: round_bonus_total,
      total: fixtures_total + round_bonus_total,
      bonus_by_round: bonus_by_round,
      breakdown: scored
    }
  end

  # Round Bonus per round ordinal (one computation feeds both the per-round figure and
  # the total, so they cannot drift).
  defp bonus_by_round(scored, rounds_meta) do
    scored
    |> Enum.group_by(& &1.ordinal)
    |> Map.new(fn {ordinal, entries} ->
      meta = Map.get(rounds_meta, ordinal)
      results = Enum.map(entries, & &1.result)

      complete? =
        not is_nil(ordinal) and meta != nil and meta.complete? and
          length(entries) == meta.count

      {ordinal, Scoring.round_total(results, complete?).round_bonus}
    end)
  end
```

(Delete the old `round_bonus_total/2` private function — its logic now lives in `bonus_by_round/2`.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mise exec -- mix test test/predictex/standings_test.exs`
Expected: PASS (all existing assertions on `fixtures_total`/`round_bonus_total`/`total` still hold, plus the new one).

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/standings.ex test/predictex/standings_test.exs
git commit -m "Enrich Standings with breakdown fixture_id + bonus_by_round (predictex-79q)"
```

---

## Task 2: Flag helper (`PredictexWeb.Flags`)

**Files:**
- Create: `lib/predictex_web/flags.ex`
- Test: `test/predictex_web/flags_test.exs`

- [ ] **Step 1: Fetch the real openfootball team strings (do NOT guess them)**

Run:

```bash
curl -s https://raw.githubusercontent.com/openfootball/worldcup.json/master/2026/worldcup.json \
  | jq -r '[.. | objects | .team1?.name // .team2?.name // empty] | unique[]' 2>/dev/null \
  | sort -u
```

If that jq path yields nothing (feed shape differs), fall back to grabbing every name field and eyeball the team names:

```bash
curl -s https://raw.githubusercontent.com/openfootball/worldcup.json/master/2026/worldcup.json \
  | jq -r '[.. | .name? // empty] | unique[]'
```

Keep the printed list — these exact strings are the map keys. Note any placeholder entries (e.g. "Winner Play-off A") — those are expected to fall back to ⚽.

- [ ] **Step 2: Write the failing test**

Create `test/predictex_web/flags_test.exs`:

```elixir
defmodule PredictexWeb.FlagsTest do
  use ExUnit.Case, async: true

  alias PredictexWeb.Flags

  test "known nations map to a non-default flag" do
    refute Flags.flag("Mexico") == "⚽"
    refute Flags.flag("Argentina") == "⚽"
  end

  test "unknown / placeholder strings fall back to the ball" do
    assert Flags.flag("Winner Play-off A") == "⚽"
    assert Flags.flag(nil) == "⚽"
    assert Flags.flag("") == "⚽"
  end
end
```

> Note: this unit test only proves the fallback works and that a couple of keys exist. It is NOT data-contract verification (a test that iterates the same list used to build the map only proves the map contains its own keys). The real check is Step 5 below.

- [ ] **Step 3: Run it to verify it fails**

Run: `mise exec -- mix test test/predictex_web/flags_test.exs`
Expected: FAIL — `PredictexWeb.Flags` is undefined.

- [ ] **Step 4: Write the module, keyed on the strings from Step 1**

Create `lib/predictex_web/flags.ex`. Use the exact strings printed in Step 1 as keys. Example shape (replace/extend the map with the real fetched names — the entries below are illustrative of the format, fill in all qualified teams):

```elixir
defmodule PredictexWeb.Flags do
  @moduledoc """
  Maps a team name (the exact strings the openfootball 2026 feed emits) to a flag
  emoji for display. Presentation-only and best-effort: any unmapped string —
  including playoff-winner placeholders — falls back to ⚽, so an unknown team never
  breaks the page. Keys are verified against the live feed (see the data-contract
  snapshot test).
  """

  @fallback "⚽"

  # KEY on the exact openfootball strings from Step 1. Emoji are the country's two
  # regional-indicator characters. Fill in every qualified nation from the feed.
  @flags %{
    "Mexico" => "🇲🇽",
    "Canada" => "🇨🇦",
    "USA" => "🇺🇸",
    "Argentina" => "🇦🇷",
    "Brazil" => "🇧🇷"
    # … all remaining qualified nations from the Step 1 output …
  }

  @doc "Flag emoji for a team name; ⚽ when unmapped."
  @spec flag(String.t() | nil) :: String.t()
  def flag(team) when is_binary(team), do: Map.get(@flags, team, @fallback)
  def flag(_), do: @fallback

  @doc "All mapped team strings (used by the data-contract snapshot test)."
  def known, do: Map.keys(@flags)
end
```

- [ ] **Step 5: Fetch-and-diff verification (one-time, honest data-contract check)**

Re-run the Step 1 command and diff its output against `PredictexWeb.Flags.known/0`:

```bash
mise exec -- mix run -e '
  feed = System.cmd("bash", ["-c", "curl -s https://raw.githubusercontent.com/openfootball/worldcup.json/master/2026/worldcup.json | jq -r \"[.. | objects | .team1?.name // .team2?.name // empty] | unique[]\""]) |> elem(0) |> String.split("\n", trim: true)
  missing = feed -- PredictexWeb.Flags.known()
  IO.inspect(missing, label: "feed teams with NO flag (verify these are placeholders, not real nations)")
'
```

Confirm every entry in `missing` is a genuine placeholder (not a real nation that should have a flag). Fix any real-nation misses by adding them to `@flags`. This is the step that actually validates the map against production data.

- [ ] **Step 6: Run the unit test to verify it passes**

Run: `mise exec -- mix test test/predictex_web/flags_test.exs`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add lib/predictex_web/flags.ex test/predictex_web/flags_test.exs
git commit -m "Add team-name → flag emoji helper, keyed on openfootball strings (predictex-79q)"
```

---

## Task 3: FIFA predictor URL config

**Files:**
- Modify: `config/config.exs` (add before the final `import_config` line)
- Modify: `config/runtime.exs`

- [ ] **Step 1: Add the compile-time default**

In `config/config.exs`, add just above the `# Import environment specific config` comment block:

```elixir
# Outbound link to the official FIFA Match Predictor (My Predictions dashboard).
# Overridable at runtime via FIFA_PREDICTOR_URL.
config :predictex, :fifa_predictor_url, "https://play.fifa.com/match-predictor/match"
```

- [ ] **Step 2: Add the runtime override**

In `config/runtime.exs`, near the other `config :predictex, …` runtime lines (after the endpoint config block), add:

```elixir
if fifa_url = System.get_env("FIFA_PREDICTOR_URL") do
  config :predictex, :fifa_predictor_url, fifa_url
end
```

- [ ] **Step 3: Verify it loads**

Run: `mise exec -- mix run -e 'IO.inspect(Application.get_env(:predictex, :fifa_predictor_url))'`
Expected: prints `"https://play.fifa.com/match-predictor/match"`

- [ ] **Step 4: Commit**

```bash
git add config/config.exs config/runtime.exs
git commit -m "Add :fifa_predictor_url config (default + FIFA_PREDICTOR_URL override) (predictex-79q)"
```

---

## Task 4: `Predictions.list_player_predictions/1`

**Files:**
- Modify: `lib/predictex/predictions.ex`
- Test: `test/predictex/predictions_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `test/predictex/predictions_test.exs`:

```elixir
test "list_player_predictions returns only that player's predictions", %{round: round, player: player} do
  other = player_fixture(%{display_name: "Other"})
  f1 = fixture!(round)
  f2 = fixture!(round)

  {:ok, _} = Predictions.create_prediction(%{player_id: player.id, fixture_id: f1.id, home_goals: 1, away_goals: 0})
  {:ok, _} = Predictions.create_prediction(%{player_id: other.id, fixture_id: f2.id, home_goals: 2, away_goals: 2})

  preds = Predictions.list_player_predictions(player.id)
  assert length(preds) == 1
  assert hd(preds).fixture_id == f1.id
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec -- mix test test/predictex/predictions_test.exs`
Expected: FAIL — `list_player_predictions/1` undefined.

- [ ] **Step 3: Implement**

In `lib/predictex/predictions.ex`, after `list_predictions/0`, add:

```elixir
  @doc "All of one player's predictions (any round, any fixture state)."
  def list_player_predictions(player_id) do
    Repo.all(from p in Prediction, where: p.player_id == ^player_id)
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mise exec -- mix test test/predictex/predictions_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/predictions.ex test/predictex/predictions_test.exs
git commit -m "Add Predictions.list_player_predictions/1 (predictex-79q)"
```

---

## Task 5: `Predictex.Dashboard` — pure `build/4`

**Files:**
- Create: `lib/predictex/dashboard.ex`
- Test: `test/predictex/dashboard_test.exs`

- [ ] **Step 1: Write the failing test (pure, no DB)**

Create `test/predictex/dashboard_test.exs`. This builds plain structs/maps and asserts `build/4` does only presentation — points/total/rank come straight from the supplied standings entry:

```elixir
defmodule Predictex.DashboardTest do
  use ExUnit.Case, async: true

  alias Predictex.Dashboard
  alias Predictex.Tournament.{Round, Fixture}
  alias Predictex.Predictions.Prediction

  defp dt(offset), do: DateTime.add(~U[2026-06-15 12:00:00Z], offset, :second)

  defp round_with(ordinal, stage, fixtures),
    do: %Round{id: ordinal, ordinal: ordinal, stage: stage, name: "R#{ordinal}", fixtures: fixtures}

  test "build assembles per-fixture view and takes points/total/rank from the standings entry" do
    now = ~U[2026-06-15 12:00:00Z]

    completed = %Fixture{id: 1, round_id: 1, team1: "Mexico", team2: "Poland", status: :completed,
                         home_goals: 2, away_goals: 1, kickoff_at: dt(-3600)}
    locked = %Fixture{id: 2, round_id: 1, team1: "France", team2: "Denmark", status: :scheduled,
                      kickoff_at: dt(-60)}
    open_unpredicted = %Fixture{id: 3, round_id: 1, team1: "Brazil", team2: "Serbia", status: :scheduled,
                                kickoff_at: dt(3600)}

    rounds = [round_with(1, :group, [completed, locked, open_unpredicted])]

    preds = %{
      1 => %Prediction{fixture_id: 1, home_goals: 2, away_goals: 1, booster: true},
      2 => %Prediction{fixture_id: 2, home_goals: 1, away_goals: 1, booster: false}
    }

    entry = %{
      player_id: 7, name: "Dave", total: 70, fixtures_total: 50, round_bonus_total: 20,
      bonus_by_round: %{1 => 20},
      breakdown: [%{ordinal: 1, fixture_id: 1, result: %{fixture_total: 50}}]
    }

    view = Dashboard.build(rounds, preds, %{entry: entry, rank: 9, of: 14}, now)

    assert view.rank == 9 and view.of == 14
    assert view.total == 70 and view.fixtures_total == 50 and view.round_bonus_total == 20

    [r1] = view.rounds
    assert r1.active? and r1.round_bonus == 20
    [fc, fl, fo] = r1.fixtures

    assert fc.points == 50 and fc.booster? and fc.exact?
    assert fl.locked? and fl.points == nil and fl.prediction
    assert fo.prediction == nil and fo.locked? == false
  end

  test "build with no standings entry yields zeroes, never crashes" do
    now = ~U[2026-06-15 12:00:00Z]
    f = %Fixture{id: 1, round_id: 1, team1: "A", team2: "B", status: :scheduled, kickoff_at: dt(3600)}
    rounds = [round_with(1, :group, [f])]

    view = Dashboard.build(rounds, %{}, %{entry: nil, rank: 1, of: 1}, now)
    assert view.total == 0
    assert [%{points: nil, prediction: nil}] = hd(view.rounds).fixtures
  end

  test "active round is the lowest-ordinal not fully complete" do
    now = ~U[2026-06-15 12:00:00Z]
    done = %Fixture{id: 1, round_id: 1, status: :completed, home_goals: 0, away_goals: 0, kickoff_at: dt(-99)}
    todo = %Fixture{id: 2, round_id: 2, status: :scheduled, kickoff_at: dt(99)}
    rounds = [round_with(1, :group, [done]), round_with(2, :group, [todo])]

    view = Dashboard.build(rounds, %{}, %{entry: nil, rank: 1, of: 1}, now)
    assert Enum.find(view.rounds, & &1.active?).round.ordinal == 2
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec -- mix test test/predictex/dashboard_test.exs`
Expected: FAIL — `Predictex.Dashboard` undefined.

- [ ] **Step 3: Implement `build/4` and helpers (the DB edge comes in Task 6)**

Create `lib/predictex/dashboard.ex`:

```elixir
defmodule Predictex.Dashboard do
  @moduledoc """
  Read model for the member's personal "My Predictions" dashboard.

  Gather → Decide: `for_player/2` is the I/O edge (loads rounds+fixtures, the player's
  predictions, and the player's `Predictex.Standings` entry); `build/4` is pure and
  DB-free. `Predictex.Standings` is the single scoring authority — `build/4` does NO
  scoring arithmetic, only joining, lock state, display flags, and tab selection, so the
  headline total can never disagree with the leaderboard rank.
  """
  import Ecto.Query, warn: false

  alias Predictex.{Repo, Predictions, Standings}
  alias Predictex.Tournament.{Round, Fixture}

  @doc """
  Load and assemble the dashboard for `player`. `standing` is `%{entry, rank, of}` where
  `entry` is the player's `Standings.leaderboard/0` map (or nil if absent).
  """
  def for_player(player, now \\ DateTime.utc_now()) do
    fixtures_q = from(f in Fixture, order_by: [asc: f.kickoff_at, asc: f.id])

    rounds =
      Repo.all(from r in Round, order_by: r.ordinal, preload: [fixtures: ^fixtures_q])

    predictions_by_fixture =
      player.id
      |> Predictions.list_player_predictions()
      |> Map.new(&{&1.fixture_id, &1})

    standings = Standings.leaderboard()
    index = Enum.find_index(standings, &(&1.player_id == player.id))

    standing = %{
      entry: index && Enum.at(standings, index),
      rank: (index && index + 1) || length(standings) + 1,
      of: length(standings)
    }

    build(rounds, predictions_by_fixture, standing, now)
  end

  @doc "Pure assembly of the view model. See module doc."
  def build(rounds, predictions_by_fixture, standing, now) do
    entry = standing.entry

    points_by_fixture =
      case entry do
        nil -> %{}
        e -> Map.new(e.breakdown, &{&1.fixture_id, &1.result.fixture_total})
      end

    bonus_by_round = (entry && entry.bonus_by_round) || %{}

    round_views =
      Enum.map(rounds, fn round ->
        %{
          round: round,
          round_bonus: Map.get(bonus_by_round, round.ordinal, 0),
          complete?: round.fixtures != [] and Enum.all?(round.fixtures, &(&1.status == :completed)),
          fixtures:
            Enum.map(round.fixtures, &fixture_view(&1, predictions_by_fixture, points_by_fixture, now))
        }
      end)

    active = active_ordinal(round_views)

    %{
      rank: standing.rank,
      of: standing.of,
      total: (entry && entry.total) || 0,
      fixtures_total: (entry && entry.fixtures_total) || 0,
      round_bonus_total: (entry && entry.round_bonus_total) || 0,
      rounds: Enum.map(round_views, &Map.put(&1, :active?, &1.round.ordinal == active))
    }
  end

  defp fixture_view(fixture, predictions_by_fixture, points_by_fixture, now) do
    prediction = Map.get(predictions_by_fixture, fixture.id)

    %{
      fixture: fixture,
      prediction: prediction,
      status: fixture.status,
      locked?: Predictions.locked?(fixture, now),
      points: Map.get(points_by_fixture, fixture.id),
      booster?: prediction != nil and prediction.booster == true,
      exact?: exact?(prediction, fixture)
    }
  end

  defp exact?(nil, _fixture), do: false
  defp exact?(_prediction, %{status: status}) when status != :completed, do: false
  defp exact?(prediction, fixture),
    do: prediction.home_goals == fixture.home_goals and prediction.away_goals == fixture.away_goals

  # Lowest-ordinal round not fully complete; if every round is complete, the highest ordinal.
  defp active_ordinal([]), do: nil

  defp active_ordinal(round_views) do
    case Enum.find(round_views, &(not &1.complete?)) do
      nil -> round_views |> List.last() |> Map.fetch!(:round) |> Map.fetch!(:ordinal)
      rv -> rv.round.ordinal
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mise exec -- mix test test/predictex/dashboard_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/dashboard.ex test/predictex/dashboard_test.exs
git commit -m "Add pure Dashboard.build/4 read model (predictex-79q)"
```

---

## Task 6: `Dashboard.for_player/2` integration test (DB)

**Files:**
- Test: `test/predictex/dashboard_test.exs` (add a DB describe block)

- [ ] **Step 1: Write the failing integration test**

Add to `test/predictex/dashboard_test.exs` a DB-backed block (note the new `use` line is per-module; instead add a second module to keep async pure-vs-DB separation):

Create the block as a separate module at the bottom of the same file:

```elixir
defmodule Predictex.DashboardDBTest do
  use Predictex.DataCase, async: true

  import Predictex.AccountsFixtures
  alias Predictex.{Dashboard, Predictions, Tournament}

  defp fixture!(round, attrs) do
    base = %{external_ref: "ref-#{System.unique_integer([:positive])}", team1: "Mexico",
             team2: "Poland", status: :scheduled, round_id: round.id}
    {:ok, f} = Tournament.create_fixture(Map.merge(base, attrs))
    f
  end

  test "for_player assembles rounds, picks, points and rank from real data" do
    {:ok, round} = Tournament.create_round(%{name: "Matchday 1", stage: :group, ordinal: 1})
    player = player_fixture(%{display_name: "Dave"})

    past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    completed = fixture!(round, %{kickoff_at: past, status: :completed, home_goals: 2, away_goals: 1})
    _open = fixture!(round, %{kickoff_at: future})

    {:ok, _} = Predictions.create_prediction(
      %{player_id: player.id, fixture_id: completed.id, home_goals: 2, away_goals: 1}, past
    )

    view = Dashboard.for_player(player)

    assert view.of >= 1
    assert is_integer(view.rank)
    [r1] = view.rounds
    assert length(r1.fixtures) == 2
    scored = Enum.find(r1.fixtures, &(&1.fixture.id == completed.id))
    assert scored.points > 0 and scored.exact?
    unp = Enum.find(r1.fixtures, &(&1.fixture.id != completed.id))
    assert unp.prediction == nil
  end
end
```

> Note: `create_prediction/2` rejects a locked fixture, so the prediction for the already-completed fixture is created with `past` as the clock (before its kickoff) — the same trick the existing predictions tests use.

- [ ] **Step 2: Run it to verify it fails or passes**

Run: `mise exec -- mix test test/predictex/dashboard_test.exs`
Expected: PASS (the implementation from Task 5 already covers `for_player/2`). If it fails on the locked-fixture insert, confirm the `past` clock argument is passed to `create_prediction/2`.

- [ ] **Step 3: Commit**

```bash
git add test/predictex/dashboard_test.exs
git commit -m "Add Dashboard.for_player/2 DB integration test (predictex-79q)"
```

---

## Task 7: Redirect logged-in members to `/predictions`

**Files:**
- Modify: `lib/predictex_web/player_auth.ex:277-281`
- Modify: `test/predictex_web/live/player_live/registration_test.exs`, `login_test.exs`, `confirmation_test.exs`, `test/predictex_web/controllers/player_session_controller_test.exs`

- [ ] **Step 1: Change `signed_in_path/1` to a single clause**

In `lib/predictex_web/player_auth.ex`, replace the two `signed_in_path` clauses (lines ~275-281) with:

```elixir
  @doc "Returns the path to redirect to after log in."
  def signed_in_path(_), do: ~p"/predictions"
```

Rationale: on a fresh login `current_scope` is not yet assigned, so the post-login redirect falls through to the `_` clause; `registration.ex` passes a `%Socket{}` which also only matches `_`. Changing only the typed `%Player{}` clause would leave the redirect on `/`.

- [ ] **Step 2: Update the post-login redirect assertions**

Change these specific assertions from `~p"/"` to `~p"/predictions"` (post-login redirects only):
- `test/predictex_web/live/player_live/registration_test.exs:20` (`follow_redirect(conn, ~p"/")` → `~p"/predictions"`)
- `test/predictex_web/live/player_live/registration_test.exs:56` (`redirected_to(conn) == ~p"/"` → `~p"/predictions"`)
- `test/predictex_web/live/player_live/login_test.exs:30`
- `test/predictex_web/live/player_live/confirmation_test.exs:73`
- `test/predictex_web/controllers/player_session_controller_test.exs:21, 85, 106` (the three login-`create` success redirects)

**Leave unchanged** (these are NOT post-login redirects):
- Any `redirected_to(conn) == ~p"/"` that follows a **log-out** / `delete` (`player_session_controller_test.exs:135, 142`) — logout redirects via `~p"/"` explicitly.
- `player_session_controller_test.exs:44` is the "login with remember me"/return-to case — verify in context: if it asserts the post-login landing with no `player_return_to`, change it to `~p"/predictions"`; if it asserts a `player_return_to` path, leave it. Read lines 40-60 before editing.
- The `response =~ ~p"/players/settings"` assertions (`:27, :91, :115`) — these check the nav link rendered by `root.html.heex` after a `get(conn, ~p"/")`, not a redirect. Leave them.

- [ ] **Step 3: Run the auth tests**

Run: `mise exec -- mix test test/predictex_web/live/player_live test/predictex_web/controllers/player_session_controller_test.exs`
Expected: PASS. If any redirect assertion still fails, re-read its surrounding context to classify it as login vs logout vs return-to per Step 2.

- [ ] **Step 4: Commit**

```bash
git add lib/predictex_web/player_auth.ex test/predictex_web/live/player_live test/predictex_web/controllers/player_session_controller_test.exs
git commit -m "Redirect members to /predictions after login (predictex-79q)"
```

---

## Task 8: Route + `MyPredictionsLive`

**Files:**
- Modify: `lib/predictex_web/router.ex:59-63`
- Create: `lib/predictex_web/live/my_predictions_live.ex`
- Test: `test/predictex_web/live/my_predictions_live_test.exs`

- [ ] **Step 1: Add the route**

In `lib/predictex_web/router.ex`, inside the existing `live_session :require_authenticated_player` block (the one with `on_mount: [{PredictexWeb.PlayerAuth, :require_authenticated}]`), add as the first `live` line:

```elixir
      live "/predictions", MyPredictionsLive, :index
```

- [ ] **Step 2: Write the failing LiveView test**

Create `test/predictex_web/live/my_predictions_live_test.exs`:

```elixir
defmodule PredictexWeb.MyPredictionsLiveTest do
  use PredictexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Predictex.AccountsFixtures
  alias Predictex.{Predictions, Tournament}

  defp fixture!(round, attrs) do
    base = %{external_ref: "ref-#{System.unique_integer([:positive])}", team1: "Mexico",
             team2: "Poland", status: :scheduled, round_id: round.id}
    {:ok, f} = Tournament.create_fixture(Map.merge(base, attrs))
    f
  end

  setup do
    {:ok, round} = Tournament.create_round(%{name: "Matchday 1", stage: :group, ordinal: 1})
    %{round: round}
  end

  test "redirects to login when logged out", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/players/log-in"}}} = live(conn, ~p"/predictions")
  end

  test "shows the member's pick, points and a no-pick warning", %{conn: conn, round: round} do
    player = player_fixture(%{display_name: "Dave"})
    past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    done = fixture!(round, %{kickoff_at: past, status: :completed, home_goals: 2, away_goals: 1})
    _open = fixture!(round, %{team1: "Brazil", team2: "Serbia", kickoff_at: future})
    {:ok, _} = Predictions.create_prediction(
      %{player_id: player.id, fixture_id: done.id, home_goals: 2, away_goals: 1}, past
    )

    {:ok, _lv, html} = conn |> log_in_player(player) |> live(~p"/predictions")

    assert html =~ "My Predictions"
    assert html =~ "Mexico"
    assert html =~ "No pick imported"
  end

  test "a member sees their own picks, not another player's", %{conn: conn, round: round} do
    me = player_fixture(%{display_name: "Me"})
    them = player_fixture(%{display_name: "Them"})
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    f = fixture!(round, %{kickoff_at: future})
    {:ok, _} = Predictions.create_prediction(%{player_id: them.id, fixture_id: f.id, home_goals: 4, away_goals: 4})

    {:ok, _lv, html} = conn |> log_in_player(me) |> live(~p"/predictions")
    refute html =~ "4 – 4"
  end
end
```

> `log_in_player/2` is the test helper from `PredictexWeb.ConnCase` (generated by `phx.gen.auth`). Confirm its name in `test/support/conn_case.ex`; if it differs (e.g. `log_in_player`), use that.

- [ ] **Step 3: Run it to verify it fails**

Run: `mise exec -- mix test test/predictex_web/live/my_predictions_live_test.exs`
Expected: FAIL — `MyPredictionsLive` undefined / route not found.

- [ ] **Step 4: Implement the LiveView**

Create `lib/predictex_web/live/my_predictions_live.ex`:

```elixir
defmodule PredictexWeb.MyPredictionsLive do
  @moduledoc """
  A member's read-only personal dashboard: their imported FIFA picks, per-fixture scoring,
  and league rank. No prediction entry here — that lives in the admin (predictex-a02) and
  import (predictex-xox) flows.
  """
  use PredictexWeb, :live_view

  alias Predictex.Dashboard
  alias PredictexWeb.Flags

  @impl true
  def mount(_params, _session, socket) do
    dash = Dashboard.for_player(socket.assigns.current_scope.player)
    active = Enum.find_value(dash.rounds, fn r -> r.active? && r.round.ordinal end)

    {:ok,
     socket
     |> assign(:page_title, "My Predictions")
     |> assign(:dash, dash)
     |> assign(:active_ordinal, active)
     |> assign(:fifa_url, Application.get_env(:predictex, :fifa_predictor_url))}
  end

  @impl true
  def handle_event("select_round", %{"ordinal" => ord}, socket) do
    {:noreply, assign(socket, :active_ordinal, String.to_integer(ord))}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :active, active_round(assigns.dash, assigns.active_ordinal))

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div :if={@dash.rounds == []} class="rounded-box bg-base-200 p-6 text-center">
        <p class="font-medium">No schedule yet</p>
        <p class="text-sm opacity-70">Fixtures appear once the tournament is seeded.</p>
      </div>

      <div :if={@dash.rounds != []} class="space-y-4">
        <div class="rounded-2xl p-4 text-white shadow-lg" style="background:linear-gradient(135deg,#0a7d3c,#0f9d4f)">
          <div class="flex items-center justify-between">
            <div>
              <div class="text-xs uppercase tracking-wide opacity-80">Your rank</div>
              <div class="text-3xl font-black leading-none">
                {ordinal(@dash.rank)} <span class="text-sm opacity-80">of {@dash.of}</span>
              </div>
            </div>
            <div class="text-right">
              <div class="text-xs uppercase tracking-wide opacity-80">Total points</div>
              <div class="text-3xl font-black">{@dash.total}</div>
              <div class="text-xs opacity-80">{@dash.fixtures_total} fixtures · {@dash.round_bonus_total} bonus</div>
            </div>
          </div>

          <div class="mt-3 flex flex-wrap gap-2">
            <button
              :for={r <- @dash.rounds}
              phx-click="select_round"
              phx-value-ordinal={r.round.ordinal}
              class={[
                "rounded-full px-3 py-1 text-xs font-bold",
                (r.round.ordinal == @active_ordinal && "bg-white text-[#0a7d3c]") || "bg-white/20 text-white"
              ]}
            >
              {r.round.name}
            </button>
          </div>
        </div>

        <div :if={@active} class="space-y-3">
          <div :for={fx <- @active.fixtures} class={[
            "rounded-xl bg-base-100 p-3 shadow",
            fx.prediction == nil && "border border-dashed border-error/40"
          ]}>
            <div class="flex items-center justify-between text-[11px] uppercase tracking-wide opacity-60">
              <span>{kickoff(fx.fixture.kickoff_at)}</span>
              <span>{status_label(fx)}</span>
            </div>

            <div class="mt-1 flex items-center justify-center gap-2 font-semibold">
              <span>{Flags.flag(fx.fixture.team1)} {fx.fixture.team1}</span>
              <span class="rounded-lg bg-base-200 px-3 py-1 text-lg font-black">{scoreline(fx.prediction)}</span>
              <span>{fx.fixture.team2} {Flags.flag(fx.fixture.team2)}</span>
            </div>

            <div :if={@active.round.stage == :knockout and fx.prediction} class="mt-1 text-center text-xs opacity-70">
              First team: {side_label(fx.prediction.first_scorer_side, fx.fixture)} ·
              First scorer: {fx.prediction.first_scorer_player || "—"}
            </div>

            <div class="mt-2 text-center text-xs">
              <span :if={fx.prediction == nil} class="font-semibold text-error">⚠ No pick imported yet</span>
              <span :if={fx.prediction && fx.status == :completed}>
                Actual <strong>{fx.fixture.home_goals}–{fx.fixture.away_goals}</strong>
                <span :if={fx.exact?} class="font-bold text-success">· exact ✓✓</span>
                <span class="ml-1 rounded-full bg-warning px-2 py-0.5 font-bold text-warning-content">+{fx.points}</span>
                <span :if={fx.booster?} class="ml-1 font-bold text-amber-600">⚡ boosted</span>
              </span>
              <span :if={fx.prediction && fx.status != :completed && fx.locked?} class="italic opacity-60">
                Locked — awaiting result {if fx.booster?, do: "· ⚡ boosted"}
              </span>
              <span :if={fx.prediction && fx.status != :completed && not fx.locked?} class="opacity-60">
                Open {if fx.booster?, do: "· ⚡ boosted"}
              </span>
            </div>
          </div>
        </div>

        <div :if={@fifa_url} class="text-center">
          <a href={@fifa_url} target="_blank" rel="noopener" class="btn btn-neutral btn-sm rounded-full">
            🌐 Make / update picks on FIFA →
          </a>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp active_round(dash, ordinal),
    do: Enum.find(dash.rounds, &(&1.round.ordinal == ordinal))

  defp scoreline(nil), do: "– – –"
  defp scoreline(p), do: "#{p.home_goals} – #{p.away_goals}"

  defp status_label(%{status: :completed}), do: "Full time"
  defp status_label(%{locked?: true}), do: "🔒 Locked"
  defp status_label(_), do: "Open"

  defp side_label(:home, fixture), do: fixture.team1
  defp side_label(:away, fixture), do: fixture.team2
  defp side_label(_, _), do: "—"

  defp kickoff(nil), do: "TBC"
  defp kickoff(%DateTime{} = dt), do: Calendar.strftime(dt, "%a %d %b · %H:%M")

  defp ordinal(n) when n in [11, 12, 13], do: "#{n}th"
  defp ordinal(n) do
    case rem(n, 10) do
      1 -> "#{n}st"
      2 -> "#{n}nd"
      3 -> "#{n}rd"
      _ -> "#{n}th"
    end
  end
end
```

- [ ] **Step 5: Run the LiveView tests to verify they pass**

Run: `mise exec -- mix test test/predictex_web/live/my_predictions_live_test.exs`
Expected: PASS. If the logged-out redirect target differs, confirm the login route in `router.ex` (`/players/log-in`).

- [ ] **Step 6: Commit**

```bash
git add lib/predictex_web/router.ex lib/predictex_web/live/my_predictions_live.ex test/predictex_web/live/my_predictions_live_test.exs
git commit -m "Add MyPredictionsLive read-only dashboard at /predictions (predictex-79q)"
```

---

## Task 9: Cross-nav links

**Files:**
- Modify: `lib/predictex_web/components/layouts/root.html.heex:43-60`

- [ ] **Step 1: Add Leaderboard + My Predictions links to the nav**

In `root.html.heex`, inside the `<ul>` menu, add these `<li>` items. Add the Leaderboard link unconditionally (before the `<%= if @current_scope do %>`), and the My Predictions link inside the logged-in branch:

```heex
      <li>
        <.link href={~p"/"}>Leaderboard</.link>
      </li>
      <%= if @current_scope do %>
        <li>
          <.link href={~p"/predictions"}>My Predictions</.link>
        </li>
        <li>
          {@current_scope.player.email}
        </li>
        <li>
          <.link href={~p"/players/settings"}>Settings</.link>
        </li>
        <li>
          <.link href={~p"/players/log-out"} method="delete">Log out</.link>
        </li>
      <% else %>
```

(Keep the existing `<% else %>` Register/Log in branch unchanged.)

- [ ] **Step 2: Verify the full suite still passes**

Run: `mise exec -- mix test`
Expected: PASS (the `response =~ "/players/settings"` nav assertions still hold; new "My Predictions" link present for logged-in users).

- [ ] **Step 3: Commit**

```bash
git add lib/predictex_web/components/layouts/root.html.heex
git commit -m "Add Leaderboard / My Predictions cross-nav links (predictex-79q)"
```

---

## Task 10: Full gates, manual smoke, and issue hygiene

**Files:** none (verification + tracker)

- [ ] **Step 1: Run all quality gates**

```bash
mise exec -- mix format --check-formatted
mise exec -- mix compile --warnings-as-errors
mise exec -- mix deps.unlock --check-unused
mise exec -- mix test
```

Expected: all green, 202 + new tests passing. Fix anything that fails before continuing.

- [ ] **Step 2: Manual smoke (local)**

```bash
mise exec -- mix phx.server
```

Seed a player + a couple of fixtures/predictions in `iex -S mix` if the dev DB is empty (via `Tournament.create_fixture` / `Predictions.create_prediction`), register/log in, and confirm `/predictions` renders: rank/total hero, round tabs switch, a scored fixture shows points + ⚡, an unpredicted fixture shows the warning, and the FIFA link points at the configured URL. Report what you saw — do not declare the feature production-ready (that is the user's call).

- [ ] **Step 3: Update the beads issues**

```bash
bd update predictex-79q --description "Read-only personal dashboard at /predictions: a member's imported FIFA picks, per-fixture scoring, booster marker, kickoff lock state, 'no pick imported' warning, rank/total reconciled with the leaderboard, and an outbound FIFA link. No prediction entry here (admin entry = a02, import = xox)."
bd update predictex-a02 --notes "Includes admin manual entry of predictions ON BEHALF OF players (from submitted FIFA screenshots) — the guaranteed-path fallback when auto-import (xox) is unavailable. My Predictions (79q) only displays these."
bd close predictex-79q
```

- [ ] **Step 4: Report for the user to review and decide on push**

Summarise: tasks done, test count, gate results, smoke observations, and the spec/plan paths. Ask whether to commit the brainstorm spec (still uncommitted) and whether to push + tag a release. Do not push without the user's say-so.

---

## Self-Review (completed)

- **Spec coverage:** read-only dashboard (T8), rank/total reconciled via Standings (T1, T5-impl), pure `build` no-scoring (T5), `for_player` edge (T5/T6), flags keyed on real strings + fetch-diff (T2), FIFA config (T3), post-login redirect with correct clause + test ripple (T7), page-level + per-fixture empty states (T8 render), knockout fields (T8 render), cross-nav (T9), issue hygiene (T10). All present.
- **Placeholder scan:** the only deliberate "fill from real data" is the flag map (T2) — by design, with the exact fetch command and a verification step; not a hand-wave.
- **Type consistency:** `build/4` takes `%{entry, rank, of}`; `for_player/2` constructs exactly that; `entry` carries `total`/`fixtures_total`/`round_bonus_total`/`bonus_by_round`/`breakdown[].fixture_id` — all produced by the Task 1 `Standings` enrichment. View-model keys (`rounds[].active?/round/round_bonus/fixtures[].fixture/prediction/status/locked?/points/booster?/exact?`) match between `build` and the render.
