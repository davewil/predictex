# FIFA Cohort Auto-Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-populate each fixture's `cohort_*_pct` (the risky-bonus inputs) from FIFA's `matchStats.json`, on an hourly Oban cron, via a pure mapper — removing the manual `a02` cohort entry and the silently-skipped risky bonus.

**Architecture:** A pure `Predictex.Fifa.Cohort.plan/3` joins FIFA cohort to our fixtures by `{utc_date, unordered team-set}` and orients home/away by the first-listed-is-home convention (logged swap guard). A `Predictex.Workers.CohortSync` Oban worker (on the `mt6` substrate, hourly) fetches `rounds.json` + `matchStats.json`, runs the pure plan, and upserts cohort via `Tournament.update_fixture/2`. FIFA overwrites; openfootball stays the fixture/result source.

**Tech Stack:** Elixir 1.20 / OTP 28 (via `mise`), Oban 2.23, Req, Ecto/Postgres. All `mix` via `mise exec -- mix …`.

**Spec:** `docs/superpowers/specs/2026-06-16-cohort-sync-design.md`

---

## File structure

| File | Responsibility | Action |
|------|----------------|--------|
| `lib/predictex/fifa/cohort.ex` | pure: `plan/3`, `norm/1`, alias table, date key | Create |
| `test/predictex/fifa/cohort_test.exs` | pure mapper tests | Create |
| `lib/predictex/workers/cohort_sync.ex` | Oban worker: fetch + plan + commit | Create |
| `test/predictex/workers/cohort_sync_test.exs` | worker behavior + risky-bonus fires | Create |
| `config/config.exs` | add cron entry | Modify |
| `config/test.exs` | `:cohort_source_fun` stub (no network) | Modify |
| `test/predictex/oban_config_test.exs` | assert CohortSync cron registered | Modify |

Task order: pure mapper → worker → cron wiring → gate. Each leaves the suite green.

---

## Task 1: Pure mapper `Predictex.Fifa.Cohort`

**Files:**
- Create: `lib/predictex/fifa/cohort.ex`
- Create: `test/predictex/fifa/cohort_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/predictex/fifa/cohort_test.exs`:

```elixir
defmodule Predictex.Fifa.CohortTest do
  use ExUnit.Case, async: true

  alias Predictex.Fifa.Cohort
  alias Predictex.Tournament.Fixture

  defp fixture(id, team1, team2, kickoff) do
    %Fixture{id: id, team1: team1, team2: team2, kickoff_at: kickoff}
  end

  defp fifa_match(id, home, away, date) do
    %{"id" => id, "homeSquadName" => home, "awaySquadName" => away, "date" => date}
  end

  defp rounds(matches), do: [%{"id" => 1, "stage" => "group", "tournaments" => matches}]

  test "maps cohort onto the matching fixture (positional, no swap)" do
    fx = fixture(7, "Mexico", "South Africa", ~U[2026-06-11 19:00:00Z])
    rounds = rounds([fifa_match(1, "Mexico", "South Africa", "2026-06-11T20:00:00+01:00")])
    stats = %{"1" => %{"homeWin" => 52, "draw" => 32, "awayWin" => 16}}

    assert [u] = Cohort.plan(rounds, stats, [fx])
    assert u == %{fixture_id: 7, cohort_home_pct: 52, cohort_draw_pct: 32, cohort_away_pct: 16}
  end

  test "orients home/away when the sources order the pair oppositely (swap)" do
    # Our fixture lists Spain first (home); FIFA lists Iran first (home).
    fx = fixture(9, "Spain", "Iran", ~U[2026-06-20 19:00:00Z])
    rounds = rounds([fifa_match(5, "Iran", "Spain", "2026-06-20T20:00:00+01:00")])
    stats = %{"5" => %{"homeWin" => 30, "draw" => 20, "awayWin" => 50}}

    assert [u] = Cohort.plan(rounds, stats, [fx])
    # cohort_home_pct must be OUR home (Spain) share = FIFA awayWin = 50
    assert u.cohort_home_pct == 50
    assert u.cohort_away_pct == 30
    assert u.cohort_draw_pct == 20
  end

  test "matches across FIFA<->openfootball name aliases" do
    fx = fixture(3, "Iran", "Spain", ~U[2026-06-20 19:00:00Z])
    rounds = rounds([fifa_match(5, "IR Iran", "Spain", "2026-06-20T20:00:00+01:00")])
    stats = %{"5" => %{"homeWin" => 30, "draw" => 20, "awayWin" => 50}}

    assert [u] = Cohort.plan(rounds, stats, [fx])
    assert u.fixture_id == 3
    assert u.cohort_home_pct == 30
  end

  test "omits a FIFA match with no matching fixture" do
    fx = fixture(1, "Brazil", "Serbia", ~U[2026-06-12 19:00:00Z])
    rounds = rounds([fifa_match(9, "France", "Denmark", "2026-06-13T20:00:00+01:00")])
    stats = %{"9" => %{"homeWin" => 40, "draw" => 30, "awayWin" => 30}}

    assert [] = Cohort.plan(rounds, stats, [fx])
  end

  test "omits a FIFA match that has no matchStats entry yet (knockout not open)" do
    fx = fixture(1, "Brazil", "Serbia", ~U[2026-06-12 19:00:00Z])
    rounds = rounds([fifa_match(2, "Brazil", "Serbia", "2026-06-12T20:00:00+01:00")])
    assert [] = Cohort.plan(rounds, %{}, [fx])
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mise exec -- mix test test/predictex/fifa/cohort_test.exs`
Expected: FAIL — `Predictex.Fifa.Cohort` is undefined.

- [ ] **Step 3: Implement the pure mapper**

Create `lib/predictex/fifa/cohort.ex`:

```elixir
defmodule Predictex.Fifa.Cohort do
  @moduledoc """
  Pure mapping of FIFA Match Predictor cohort percentages (`matchStats.json`) onto our
  fixtures, for the risky bonus. No DB, no network — the worker (`Workers.CohortSync`)
  does the I/O and calls `plan/3`.

  Match identity is the `{utc_date, unordered team-set}` of a fixture vs a FIFA match
  (`rounds.json` `tournaments[]`). Home/away is then oriented by the first-listed-is-home
  convention (our `team1` == FIFA `homeSquadName`); a source that orders a pair oppositely
  is handled by a logged swap so the win-shares still land on the correct team.

  FIFA `matchId` (`tournaments[].id`) keys `matchStats`. See
  `docs/superpowers/research/2026-06-16-xox-fifa-import-spike.md`.
  """
  require Logger

  # FIFA -> normalized openfootball name divergences (shared artifact with predictex-c9s).
  @aliases %{
    "ir iran" => "iran"
  }

  @doc """
  Pure. Returns `[%{fixture_id, cohort_home_pct, cohort_draw_pct, cohort_away_pct}]` for
  every FIFA match that resolves to a fixture and has a `matchStats` entry. Unmatched
  matches are omitted.
  """
  def plan(rounds, match_stats, fixtures)
      when is_list(rounds) and is_map(match_stats) and is_list(fixtures) do
    index = Map.new(fixtures, fn f -> {key(f.kickoff_at, f.team1, f.team2), f} end)

    rounds
    |> Enum.flat_map(fn r -> r["tournaments"] || [] end)
    |> Enum.flat_map(fn m ->
      stats = match_stats[to_string(m["id"])]
      fixture = Map.get(index, key(m["date"], m["homeSquadName"], m["awaySquadName"]))

      if is_map(stats) and fixture, do: [orient(m, stats, fixture)], else: []
    end)
  end

  defp orient(m, stats, f) do
    {home, away} =
      if norm(m["homeSquadName"]) == norm(f.team1) do
        {stats["homeWin"], stats["awayWin"]}
      else
        Logger.warning(
          "cohort orientation swap for fixture #{f.id} (#{f.team1} v #{f.team2}); " <>
            "FIFA home=#{m["homeSquadName"]}"
        )

        {stats["awayWin"], stats["homeWin"]}
      end

    %{
      fixture_id: f.id,
      cohort_home_pct: home,
      cohort_draw_pct: stats["draw"],
      cohort_away_pct: away
    }
  end

  defp key(datetime, a, b), do: {utc_date(datetime), MapSet.new([norm(a), norm(b)])}

  @doc false
  def norm(nil), do: ""

  def norm(name) when is_binary(name) do
    n = name |> String.downcase() |> String.trim() |> String.replace(~r/\s+/, " ")
    Map.get(@aliases, n, n)
  end

  # FIFA `date` is offset-bearing ISO8601 ("...+01:00"); from_iso8601 returns a UTC
  # DateTime. Fixture kickoff_at is already UTC. Both reduce to a UTC Date for the key.
  defp utc_date(%DateTime{} = dt), do: DateTime.to_date(dt)

  defp utc_date(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> DateTime.to_date(dt)
      _ -> nil
    end
  end

  defp utc_date(_), do: nil
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mise exec -- mix test test/predictex/fifa/cohort_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/fifa/cohort.ex test/predictex/fifa/cohort_test.exs
git commit -m "feat: pure Fifa.Cohort.plan maps FIFA cohort to fixtures (predictex-7ux)"
```

---

## Task 2: The `CohortSync` worker

**Files:**
- Create: `lib/predictex/workers/cohort_sync.ex`
- Create: `test/predictex/workers/cohort_sync_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/predictex/workers/cohort_sync_test.exs`:

```elixir
defmodule Predictex.Workers.CohortSyncTest do
  use Predictex.DataCase, async: true
  use Oban.Testing, repo: Predictex.Repo

  alias Predictex.{Scoring, Tournament}
  alias Predictex.Predictions.Prediction
  alias Predictex.Workers.CohortSync

  defp put_source(fun) do
    Application.put_env(:predictex, :cohort_source_fun, fun)
    on_exit(fn -> Application.delete_env(:predictex, :cohort_source_fun) end)
  end

  test "applies FIFA cohort to the matching fixture and the risky bonus then fires" do
    {:ok, round} = Tournament.create_round(%{name: "Round 1", stage: :group, ordinal: 1})

    {:ok, fixture} =
      Tournament.create_fixture(%{
        external_ref: "ref-1",
        team1: "Mexico",
        team2: "South Africa",
        status: :completed,
        home_goals: 2,
        away_goals: 0,
        kickoff_at: ~U[2026-06-11 19:00:00Z],
        round_id: round.id
      })

    rounds = [
      %{
        "id" => 1,
        "stage" => "group",
        "tournaments" => [
          %{
            "id" => 1,
            "homeSquadName" => "Mexico",
            "awaySquadName" => "South Africa",
            "date" => "2026-06-11T20:00:00+01:00"
          }
        ]
      }
    ]

    stats = %{"1" => %{"homeWin" => 15, "draw" => 30, "awayWin" => 55}}
    put_source(fn -> {:ok, %{rounds: rounds, match_stats: stats}} end)

    assert :ok = perform_job(CohortSync, %{})

    f = Tournament.get_fixture!(fixture.id)
    assert f.cohort_home_pct == 15
    assert f.cohort_draw_pct == 30
    assert f.cohort_away_pct == 55

    # A correct home-win pick whose cohort share (15) is below the risky threshold (20)
    # now earns the risky bonus that was previously skipped (cohort was nil).
    pred = %Prediction{home_goals: 1, away_goals: 0, booster: false}
    assert Scoring.score(pred, f, :group).components.risky_bonus == 10
  end

  test "returns {:error, reason} when the source fails (so Oban retries)" do
    put_source(fn -> {:error, :boom} end)
    assert {:error, :boom} = perform_job(CohortSync, %{})
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mise exec -- mix test test/predictex/workers/cohort_sync_test.exs`
Expected: FAIL — `Predictex.Workers.CohortSync` is undefined.

- [ ] **Step 3: Implement the worker (fetch is the edge; pure mapper is reused)**

Create `lib/predictex/workers/cohort_sync.ex`:

```elixir
defmodule Predictex.Workers.CohortSync do
  @moduledoc """
  Oban worker (hourly) that pulls FIFA cohort data and upserts `cohort_*_pct` on fixtures.

  Gather → Decide → Act: `fetch/0` reads `rounds.json` + `matchStats.json` (the only I/O,
  injectable via `:cohort_source_fun` for tests), `Fifa.Cohort.plan/3` is the pure join,
  and `Tournament.update_fixture/2` commits. FIFA is the source — cohort is overwritten.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Predictex.{Fifa, Tournament}

  @rounds_url "https://play.fifa.com/json/match_predictor/rounds.json"
  @stats_url "https://play.fifa.com/json/match_predictor/matchStats.json"

  @impl Oban.Worker
  def perform(_job) do
    case source().() do
      {:ok, %{rounds: rounds, match_stats: stats}} ->
        fixtures = Tournament.list_fixtures()
        updates = Fifa.Cohort.plan(rounds, stats, fixtures)
        {ok, err} = commit(updates, Map.new(fixtures, &{&1.id, &1}))
        Logger.info("cohort sync: #{ok} updated, #{err} errors (#{length(updates)} matched)")
        :ok

      {:error, reason} ->
        Logger.error("cohort sync fetch failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "Fetch FIFA reference + cohort JSON. Returns {:ok, %{rounds, match_stats}} | {:error, _}."
  def fetch do
    with {:ok, rounds} <- get_json(@rounds_url),
         {:ok, stats} <- get_json(@stats_url) do
      {:ok, %{rounds: rounds, match_stats: stats}}
    end
  end

  defp get_json(url) do
    {:ok, _} = Application.ensure_all_started(:req)

    case Req.get(url, receive_timeout: 15_000) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) or is_list(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, Jason.decode!(body)}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp commit(updates, by_id) do
    Enum.reduce(updates, {0, 0}, fn u, {ok, err} ->
      fixture = Map.fetch!(by_id, u.fixture_id)
      attrs = Map.take(u, [:cohort_home_pct, :cohort_draw_pct, :cohort_away_pct])

      case Tournament.update_fixture(fixture, attrs) do
        {:ok, _} -> {ok + 1, err}
        {:error, _} -> {ok, err + 1}
      end
    end)
  end

  defp source, do: Application.get_env(:predictex, :cohort_source_fun, &fetch/0)
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mise exec -- mix test test/predictex/workers/cohort_sync_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/workers/cohort_sync.ex test/predictex/workers/cohort_sync_test.exs
git commit -m "feat: CohortSync Oban worker fetches + applies FIFA cohort (predictex-7ux)"
```

---

## Task 3: Schedule it (hourly cron) + network-free test default

**Files:**
- Modify: `config/config.exs`
- Modify: `config/test.exs`
- Modify: `test/predictex/oban_config_test.exs`

- [ ] **Step 1: Write the failing test**

In `test/predictex/oban_config_test.exs`, add a second test inside the module:

```elixir
  test "the cohort sync worker is registered on an hourly cron" do
    plugins = Application.fetch_env!(:predictex, Oban)[:plugins]

    {_mod, opts} =
      Enum.find(plugins, fn
        {Oban.Plugins.Cron, _opts} -> true
        _ -> false
      end)

    assert {"0 * * * *", Predictex.Workers.CohortSync} in opts[:crontab]
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex/oban_config_test.exs`
Expected: FAIL — the cohort cron entry isn't in the crontab yet.

- [ ] **Step 3: Add the cron entry and the test-env stub source**

In `config/config.exs`, extend the Oban `Cron` crontab:

```elixir
    {Oban.Plugins.Cron,
     crontab: [
       {"*/15 * * * *", Predictex.Workers.ResultSync},
       {"0 * * * *", Predictex.Workers.CohortSync}
     ]}
```

In `config/test.exs`, add a no-network default so the worker never hits FIFA in tests that
don't set their own stub:

```elixir
# Cohort sync source stubbed in tests (no network); worker tests override per-test.
config :predictex, :cohort_source_fun, fn -> {:ok, %{rounds: [], match_stats: %{}}} end
```

- [ ] **Step 4: Run the cron test, then the full suite (Cron validates the worker at boot)**

Run: `mise exec -- mix test test/predictex/oban_config_test.exs`
Expected: PASS (both cron tests).

Run: `mise exec -- mix test`
Expected: full suite PASS — a green boot confirms Oban Cron accepts `CohortSync` as a valid worker.

- [ ] **Step 5: Commit**

```bash
git add config/config.exs config/test.exs test/predictex/oban_config_test.exs
git commit -m "feat: schedule CohortSync hourly via Oban Cron (predictex-7ux)"
```

---

## Task 4: Full gate & close-out

- [ ] **Step 1: Run the full quality gate**

```bash
mise exec -- mix test
mise exec -- mix format --check-formatted
mise exec -- mix compile --warnings-as-errors
mise exec -- mix deps.unlock --check-unused
```
Expected: all green.

- [ ] **Step 2: Local boot sanity (optional)**

`mise exec -- mix phx.server`, confirm no Oban errors and the endpoint comes up, then stop.
(In dev the cron actually schedules; `:cohort_source_fun` is not set in dev, so it would hit
FIFA on the next `:00` — fine, the static JSON is public and the fetch is idempotent.)

- [ ] **Step 3: Close the issue**

```bash
bd close predictex-7ux --reason="FIFA cohort auto-sync: hourly Oban CohortSync worker, pure Fifa.Cohort.plan joins matchStats by {utc_date, team-set} with orientation guard, overwrites cohort_*_pct. Removes manual a02 cohort entry / silent-skip risky bonus."
```

> Deploy is a separate operator step (push `main` → tag `vX.Y.Z`). No migration in this issue,
> so no DB change to ship — just code + config.

---

## Self-review notes (author)

- **Spec coverage:** pure `plan/3` with `{utc_date, team-set}` key + first-listed-is-home
  orientation and logged swap (Task 1); `CohortSync` worker fetch/plan/commit with `:cohort_source_fun`
  injection + `max_attempts: 3` (Task 2); hourly cron + network-free test default + cron-registered
  test (Task 3); gate + close (Task 4). FIFA-overwrites is inherent (the worker calls
  `update_fixture` unconditionally). Unmatched-skip → existing "cohort not set" badge (no code).
- **Dropped the strict `sum == 100` property** per the advisor (rounding can sum to 99); not asserted.
- **Orientation is value-asserting:** Task 1's swap test checks `cohort_home_pct` is OUR `team1`'s
  share, not merely that the match succeeded.
- **No migration:** `cohort_*_pct` columns already exist; this only writes them.
- **Verify-before-assume:** `@risky_threshold` is 20 and risky points 10 (confirmed in `scoring.ex`),
  so the worker test's cohort 15 → risky 10 is real. `Req` auto-decodes JSON (body is map/list);
  the binary-body clause is a defensive fallback.
