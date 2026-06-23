# FIFA-capture result fallback (predictex-iy1) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When openfootball has no result for a fixture but our FIFA capture shows it finished, settle the fixture provisionally from the captured score — so a lagging openfootball feed no longer leaves a played match unscored.

**Architecture:** Two coordinated changes. (1) An `Ingest` *no-downgrade guard* so a `:completed` fixture is never reverted to `:scheduled` by a sync that carries no result — establishing the invariant the fallback relies on. (2) A new pure-core + thin-edge `Predictex.Results.FifaFallback` module, run by `ResultSync` after the openfootball sync each tick, that settles unsettled **group** fixtures from a captured FIFA finished frame (`MatchStatus 0`). openfootball stays primary and overwrites the provisional the instant it carries a real result.

**Tech Stack:** Elixir 1.20 / Phoenix, Ecto/Postgres, Oban. Run all mix via `mise exec -- mix …`.

## Global Constraints

- Run mix as `mise exec -- mix …` (mise pins Elixir 1.20.1 / OTP 28).
- The gate is `mix precommit` (compile --warnings-as-errors, deps.unlock --check-unused, format --check-formatted, credo --strict, test). It runs on every Elixir-staging commit via lefthook; never `--no-verify`.
- Two-writer rule: FIFA drives `live_*`; openfootball owns `status`/final score. The fallback is the one **bounded, deliberate exception** — it writes `status`/`home_goals`/`away_goals` only for an unsettled **group** fixture from a FIFA finished frame.
- Group stage only (v1). Knockouts (ET/penalties) are out of scope (`predictex-uyf`).
- No migration. Approach A (silent settle); no provenance column.
- Tests are network-free via injected funs (`:fifa_fallback_body_fun`, `:fifa_fallback_fun`), mirroring the existing `:result_sync_fun` pattern.
- Spec: `docs/superpowers/specs/2026-06-23-iy1-fifa-result-fallback-design.md`.

---

### Task 1: `Ingest` no-downgrade guard

Establish the invariant: a `:completed` fixture never reverts to `:scheduled` via a sync. Without this, every 15-min `ResultSync` tick reverts a fallback-settled fixture (openfootball parses a scoreless match as `:scheduled / nil / nil`) and the fallback re-settles it — a match-day flicker.

**Files:**
- Modify: `lib/predictex/results/ingest.ex` (add `@result_fields`; guard in `upsert_fixture/2`)
- Test: `test/predictex/results/ingest_test.exs`

**Interfaces:**
- Consumes: nothing new.
- Produces: behaviour only — `Ingest.sync/1` no longer downgrades a `:completed` fixture's result fields when the feed entry has no result.

- [ ] **Step 1: Write the failing tests**

Add to `test/predictex/results/ingest_test.exs` (the existing `@doc_fixture` and aliases are already in the file):

```elixir
describe "no-downgrade guard" do
  @scored %{
    "matches" => [
      %{
        "round" => "Matchday 1",
        "date" => "2026-06-11",
        "time" => "13:00 UTC-6",
        "group" => "Group A",
        "team1" => "Mexico",
        "team2" => "South Africa",
        "score" => %{"ft" => [2, 0]}
      }
    ]
  }
  @no_score put_in(@scored, ["matches", Access.at(0), "score"], nil)

  test "a settled fixture is not reverted when a later sync carries no result" do
    Ingest.sync(@scored)
    fx = Tournament.get_fixture_by_ref("2026-06-11 Mexico v South Africa")
    assert fx.status == :completed and {fx.home_goals, fx.away_goals} == {2, 0}

    # openfootball momentarily drops the score for the same fixture
    Ingest.sync(@no_score)

    fx2 = Tournament.get_fixture_by_ref("2026-06-11 Mexico v South Africa")
    assert fx2.status == :completed
    assert {fx2.home_goals, fx2.away_goals} == {2, 0}
  end

  test "a real result still overwrites a settled fixture (authoritative correction)" do
    Ingest.sync(@scored)
    corrected = put_in(@scored, ["matches", Access.at(0), "score"], %{"ft" => [3, 1]})

    Ingest.sync(corrected)

    fx = Tournament.get_fixture_by_ref("2026-06-11 Mexico v South Africa")
    assert {fx.home_goals, fx.away_goals} == {3, 1}
  end

  test "non-result fields still update on a no-result sync (g8m path preserved)" do
    Ingest.sync(@scored)
    # same fixture identity (external_ref derives from date+teams), kickoff time moved, no score
    moved = put_in(@no_score, ["matches", Access.at(0), "time"], "20:00 UTC-6")

    Ingest.sync(moved)

    fx = Tournament.get_fixture_by_ref("2026-06-11 Mexico v South Africa")
    assert fx.status == :completed
    assert fx.kickoff_at == ~U[2026-06-12 02:00:00Z]
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mise exec -- mix test test/predictex/results/ingest_test.exs`
Expected: the first and third tests FAIL (the settled fixture reverts to `:scheduled / nil`); the second PASSES already.

- [ ] **Step 3: Implement the guard**

In `lib/predictex/results/ingest.ex`, add the module attribute near the top of the module body (after the `@default_url` line):

```elixir
  # Result-derived fields. openfootball only ever produces these when it actually has a result
  # (Openfootball.ft_score returns :completed + integer goals only for an integer `ft` score).
  @result_fields [
    :status,
    :home_goals,
    :away_goals,
    :first_scorer_side,
    :first_scorer_player,
    :first_goal_owngoal,
    :goals
  ]
```

Replace the update branch in `upsert_fixture/2`:

```elixir
    case find_fixture(attrs) do
      nil -> %Fixture{} |> Fixture.changeset(attrs) |> Repo.insert()
      %Fixture{} = existing -> existing |> Fixture.changeset(attrs) |> Repo.update()
    end
```

with:

```elixir
    case find_fixture(attrs) do
      nil -> %Fixture{} |> Fixture.changeset(attrs) |> Repo.insert()
      %Fixture{} = existing -> existing |> Fixture.changeset(preserve_settled(existing, attrs)) |> Repo.update()
    end
```

And add these private clauses (next to `find_fixture/1`):

```elixir
  # A :completed fixture never reverts to :scheduled via a sync. When openfootball carries no
  # result for an already-settled fixture (status != :completed), keep its result fields and
  # update only the non-result fields (teams / kickoff / source_num — the predictex-g8m
  # bracket-resolution path). A real result (status :completed) writes through normally.
  defp preserve_settled(%Fixture{status: :completed}, %{status: status} = attrs)
       when status != :completed do
    Map.drop(attrs, @result_fields)
  end

  defp preserve_settled(_existing, attrs), do: attrs
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mise exec -- mix test test/predictex/results/ingest_test.exs`
Expected: PASS (all, including the existing suite).

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/results/ingest.ex test/predictex/results/ingest_test.exs
git commit -m "fix(ingest): a completed fixture never reverts to scheduled via a no-result sync (predictex-iy1)"
```

---

### Task 2: `FifaFallback.settle_attrs/2` — the pure decision

**Files:**
- Create: `lib/predictex/results/fifa_fallback.ex`
- Test: `test/predictex/results/fifa_fallback_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces: `Predictex.Results.FifaFallback.settle_attrs(fixture, body) :: {:ok, %{status: :completed, home_goals: integer, away_goals: integer}} | :skip`. `fixture` is any map/struct with `:round` (carrying `:stage`) and `:status`; `body` is a FIFA `/detail` map (or nil).

- [ ] **Step 1: Write the failing tests**

Create `test/predictex/results/fifa_fallback_test.exs`:

```elixir
defmodule Predictex.Results.FifaFallbackTest do
  use ExUnit.Case, async: true

  alias Predictex.Results.FifaFallback

  defp group_fixture(status \\ :scheduled),
    do: %{round: %{stage: :group}, status: status}

  defp finished_body(h, a),
    do: %{"MatchStatus" => 0, "HomeTeam" => %{"Score" => h}, "AwayTeam" => %{"Score" => a}}

  test "settles an unsettled group fixture from a finished frame" do
    assert {:ok, %{status: :completed, home_goals: 3, away_goals: 0}} =
             FifaFallback.settle_attrs(group_fixture(), finished_body(3, 0))
  end

  test "skips when the match is not finished (MatchStatus 3)" do
    body = %{"MatchStatus" => 3, "HomeTeam" => %{"Score" => 1}, "AwayTeam" => %{"Score" => 0}}
    assert :skip = FifaFallback.settle_attrs(group_fixture(), body)
  end

  test "skips when a score is missing" do
    body = %{"MatchStatus" => 0, "HomeTeam" => %{"Score" => 1}, "AwayTeam" => %{}}
    assert :skip = FifaFallback.settle_attrs(group_fixture(), body)
  end

  test "skips a knockout fixture (ET/penalties out of scope)" do
    ko = %{round: %{stage: :knockout}, status: :scheduled}
    assert :skip = FifaFallback.settle_attrs(ko, finished_body(1, 0))
  end

  test "skips an already-completed fixture" do
    assert :skip = FifaFallback.settle_attrs(group_fixture(:completed), finished_body(3, 0))
  end

  test "skips when there is no captured body" do
    assert :skip = FifaFallback.settle_attrs(group_fixture(), nil)
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mise exec -- mix test test/predictex/results/fifa_fallback_test.exs`
Expected: FAIL — `Predictex.Results.FifaFallback.settle_attrs/2 is undefined (module not available)`.

- [ ] **Step 3: Write the module with the pure core**

Create `lib/predictex/results/fifa_fallback.ex`:

```elixir
defmodule Predictex.Results.FifaFallback do
  @moduledoc """
  Provisionally settle a fixture from our FIFA capture when openfootball lags (predictex-iy1).

  openfootball stays the authoritative result source (the two-writer rule). This is the bounded
  exception: for an unsettled **group** fixture whose captured FIFA `/detail` shows the match
  finished (`MatchStatus` 0) with both scores, write the FIFA final score + `status: :completed`.
  openfootball reclaims authority on its next sync that carries a real result (`Ingest`'s
  no-downgrade guard keeps a no-result sync from reverting the provisional in the meantime).

  Knockouts (extra-time / penalties) are out of scope — `predictex-uyf`.
  """

  @doc """
  Decide whether a captured FIFA `/detail` body finalizes `fixture`. Pure.

  Returns `{:ok, %{status: :completed, home_goals: h, away_goals: a}}` only for an unsettled
  group fixture whose `body` is a finished frame with both integer scores; `:skip` otherwise.
  """
  @spec settle_attrs(map(), map() | nil) :: {:ok, map()} | :skip
  def settle_attrs(%{round: %{stage: :group}, status: status}, body)
      when status != :completed and is_map(body) do
    with 0 <- body["MatchStatus"],
         h when is_integer(h) <- get_in(body, ["HomeTeam", "Score"]),
         a when is_integer(a) <- get_in(body, ["AwayTeam", "Score"]) do
      {:ok, %{status: :completed, home_goals: h, away_goals: a}}
    else
      _ -> :skip
    end
  end

  def settle_attrs(_fixture, _body), do: :skip
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mise exec -- mix test test/predictex/results/fifa_fallback_test.exs`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/results/fifa_fallback.ex test/predictex/results/fifa_fallback_test.exs
git commit -m "feat(fifa-fallback): pure settle_attrs decision for group fixtures (predictex-iy1)"
```

---

### Task 3: `FifaFallback.run/0` — the Gather/Act edge

**Files:**
- Modify: `lib/predictex/results/fifa_fallback.ex`
- Test: `test/predictex/results/fifa_fallback_test.exs`

**Interfaces:**
- Consumes: `settle_attrs/2` (Task 2); `Predictex.Capture.latest_detail_body/1`; `Predictex.Tournament.update_fixture/2`, `Predictex.Tournament.broadcast_change/0`.
- Produces: `FifaFallback.run() :: %{candidates: non_neg_integer, settled: non_neg_integer}`. Body source injectable via `Application.get_env(:predictex, :fifa_fallback_body_fun, &Capture.latest_detail_body/1)`.

- [ ] **Step 1: Write the failing test**

Add to `test/predictex/results/fifa_fallback_test.exs` (add `use Predictex.DataCase, async: true` is NOT compatible with the existing `use ExUnit.Case` — instead append a second describe that creates DB fixtures; change the top `use ExUnit.Case, async: true` to `use Predictex.DataCase, async: true`, which provides the Repo sandbox and keeps the pure tests working):

First change the module header line:

```elixir
  use Predictex.DataCase, async: true
```

Then add:

```elixir
  alias Predictex.Tournament

  defp db_group_fixture(attrs) do
    round =
      Tournament.get_round_by_ordinal(1) ||
        (
          {:ok, r} = Tournament.create_round(%{name: "R1", stage: :group, ordinal: 1})
          r
        )

    {:ok, f} =
      Tournament.create_fixture(
        Map.merge(
          %{
            external_ref: "ref-#{System.unique_integer([:positive])}",
            team1: "A",
            team2: "B",
            round_id: round.id,
            kickoff_at: DateTime.add(DateTime.utc_now(), -200 * 60)
          },
          attrs
        )
      )

    f
  end

  defp put_body_fun(map) do
    Application.put_env(:predictex, :fifa_fallback_body_fun, fn id -> Map.get(map, id) end)
    on_exit(fn -> Application.delete_env(:predictex, :fifa_fallback_body_fun) end)
  end

  describe "run/0" do
    test "settles an eligible candidate and leaves others alone" do
      eligible = db_group_fixture(%{fifa_match_id: "100", status: :scheduled})
      not_finished = db_group_fixture(%{fifa_match_id: "101", status: :scheduled})
      already = db_group_fixture(%{fifa_match_id: "102", status: :completed, home_goals: 1, away_goals: 1})

      put_body_fun(%{
        "100" => %{"MatchStatus" => 0, "HomeTeam" => %{"Score" => 3}, "AwayTeam" => %{"Score" => 0}},
        "101" => %{"MatchStatus" => 3, "HomeTeam" => %{"Score" => 1}, "AwayTeam" => %{"Score" => 0}},
        "102" => %{"MatchStatus" => 0, "HomeTeam" => %{"Score" => 5}, "AwayTeam" => %{"Score" => 5}}
      })

      assert %{settled: 1} = FifaFallback.run()

      assert %{status: :completed, home_goals: 3, away_goals: 0} = Tournament.get_fixture!(eligible.id)
      assert %{status: :scheduled} = Tournament.get_fixture!(not_finished.id)
      # already-completed is untouched by the fallback (1-1 stays, not 5-5)
      assert %{home_goals: 1, away_goals: 1} = Tournament.get_fixture!(already.id)
    end

    test "broadcasts a change when something settles" do
      db_group_fixture(%{fifa_match_id: "200", status: :scheduled})
      Tournament.subscribe_changes()

      put_body_fun(%{
        "200" => %{"MatchStatus" => 0, "HomeTeam" => %{"Score" => 1}, "AwayTeam" => %{"Score" => 0}}
      })

      FifaFallback.run()
      assert_received :fixtures_changed
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise exec -- mix test test/predictex/results/fifa_fallback_test.exs`
Expected: FAIL — `FifaFallback.run/0 is undefined`.

- [ ] **Step 3: Implement `run/0`**

In `lib/predictex/results/fifa_fallback.ex`, add the imports/aliases under the `@moduledoc` and the function. Full additions:

```elixir
  import Ecto.Query, only: [from: 2]

  alias Predictex.{Capture, Repo, Tournament}
  alias Predictex.Tournament.Fixture

  # Don't trust an early/abandoned MatchStatus 0 frame; a group match can't finish before this.
  @min_elapsed_min 100

  @doc """
  Settle every eligible candidate from its latest captured FIFA finished frame. Returns a summary
  `%{candidates: n, settled: m}` and broadcasts a fixtures-changed signal when anything settled.
  """
  @spec run() :: %{candidates: non_neg_integer(), settled: non_neg_integer()}
  def run do
    cutoff = DateTime.add(DateTime.utc_now(), -@min_elapsed_min * 60)

    candidates =
      Repo.all(
        from f in Fixture,
          where: not is_nil(f.fifa_match_id) and f.status != :completed and f.kickoff_at < ^cutoff,
          preload: :round
      )

    settled =
      Enum.flat_map(candidates, fn f ->
        case settle_attrs(f, body_fun().(f.fifa_match_id)) do
          {:ok, attrs} ->
            Tournament.update_fixture(f, attrs)
            [f.id]

          :skip ->
            []
        end
      end)

    if settled != [], do: Tournament.broadcast_change()

    %{candidates: length(candidates), settled: length(settled)}
  end

  defp body_fun do
    Application.get_env(:predictex, :fifa_fallback_body_fun, &Capture.latest_detail_body/1)
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mise exec -- mix test test/predictex/results/fifa_fallback_test.exs`
Expected: PASS (all — the pure tests from Task 2 still pass under `DataCase`).

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/results/fifa_fallback.ex test/predictex/results/fifa_fallback_test.exs
git commit -m "feat(fifa-fallback): run/0 settles eligible group fixtures from captured finished frames (predictex-iy1)"
```

---

### Task 4: Wire the fallback into `ResultSync`

**Files:**
- Modify: `lib/predictex/workers/result_sync.ex`
- Modify: `config/test.exs` (stub `:fifa_fallback_fun`)
- Test: `test/predictex/workers/result_sync_test.exs`

**Interfaces:**
- Consumes: `FifaFallback.run/0` (Task 3).
- Produces: `ResultSync.perform/1` runs the fallback unconditionally after the openfootball sync; fallback fn injectable via `Application.get_env(:predictex, :fifa_fallback_fun, &FifaFallback.run/0)`.

- [ ] **Step 1: Add the test-env stub so existing ResultSync tests stay network-free**

In `config/test.exs`, after the `:result_sync_fun` block (around line 56), add:

```elixir
config :predictex, :fifa_fallback_fun, fn -> %{candidates: 0, settled: 0} end
```

- [ ] **Step 2: Write the failing test**

Add to `test/predictex/workers/result_sync_test.exs`:

```elixir
  test "perform runs the FIFA fallback after the openfootball sync" do
    test_pid = self()

    Application.put_env(:predictex, :fifa_fallback_fun, fn ->
      send(test_pid, :fallback_ran)
      %{candidates: 0, settled: 0}
    end)

    on_exit(fn ->
      Application.put_env(:predictex, :fifa_fallback_fun, fn -> %{candidates: 0, settled: 0} end)
    end)

    assert :ok = perform_job(ResultSync, %{})
    assert_received :fallback_ran
  end

  test "the FIFA fallback still runs when the openfootball sync fails" do
    test_pid = self()
    Application.put_env(:predictex, :result_sync_fun, fn -> {:error, :boom} end)
    Application.put_env(:predictex, :fifa_fallback_fun, fn ->
      send(test_pid, :fallback_ran)
      %{candidates: 0, settled: 0}
    end)

    on_exit(fn ->
      restore_result_sync_fun()
      Application.put_env(:predictex, :fifa_fallback_fun, fn -> %{candidates: 0, settled: 0} end)
    end)

    assert {:error, :boom} = perform_job(ResultSync, %{})
    assert_received :fallback_ran
  end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `mise exec -- mix test test/predictex/workers/result_sync_test.exs`
Expected: FAIL — `:fallback_ran` never received (the fallback isn't wired in yet).

- [ ] **Step 4: Wire the fallback into `perform/1`**

In `lib/predictex/workers/result_sync.ex`, add the alias:

```elixir
  alias Predictex.Results.{FifaFallback, Ingest}
```

(replace the existing `alias Predictex.Results.Ingest`).

Replace `perform/1`:

```elixir
  @impl Oban.Worker
  def perform(_job) do
    result = sync_fun().()
    # Run the FIFA-capture fallback unconditionally — it's most valuable exactly when openfootball
    # is down, so it must not be gated on the sync succeeding (predictex-iy1).
    fallback = fallback_fun().()

    case result do
      {:error, reason} ->
        Logger.error("result sync failed: #{inspect(reason)} (fifa_fallback: #{inspect(fallback)})")
        {:error, reason}

      summary ->
        Logger.info("result sync ok: #{inspect(summary)} (fifa_fallback: #{inspect(fallback)})")
        :ok
    end
  end

  defp fallback_fun do
    Application.get_env(:predictex, :fifa_fallback_fun, &FifaFallback.run/0)
  end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mise exec -- mix test test/predictex/workers/result_sync_test.exs`
Expected: PASS (all).

- [ ] **Step 6: Run the full gate**

Run: `mise exec -- mix precommit`
Expected: PASS — compile clean, credo `--strict` clean, all tests green.

- [ ] **Step 7: Commit**

```bash
git add lib/predictex/workers/result_sync.ex config/test.exs test/predictex/workers/result_sync_test.exs
git commit -m "feat(result-sync): run the FIFA-capture fallback after each openfootball sync (predictex-iy1)"
```

---

### Task 5: Document the fallback in CONTEXT.md and close the bead

**Files:**
- Modify: `CONTEXT.md`
- Beads: `predictex-iy1`

- [ ] **Step 1: Add the domain term**

In `CONTEXT.md`, under the "Standings & live buzz" section's result vocabulary (after the `Result` term in the Core section, or near `Ranking core`), add:

```markdown
**FIFA result fallback**:
A bounded exception to openfootball's result authority (`Predictex.Results.FifaFallback`): when
openfootball has no **result** for a played **group** **fixture** but our FIFA capture shows it
finished (`MatchStatus 0`), settle the fixture provisionally from the captured score. openfootball
reclaims authority on its next real-result sync; a `:completed` fixture never reverts to scheduled.
_Avoid_: result source, scraper.
```

- [ ] **Step 2: Commit the doc**

```bash
git add CONTEXT.md
git commit -m "docs(context): add the FIFA result fallback term (predictex-iy1)"
```

- [ ] **Step 3: Close the bead**

```bash
bd close predictex-iy1
```

---

## Self-Review

**Spec coverage:**
- Change 1 (Ingest no-downgrade guard) → Task 1. ✓
- Change 2 pure `settle_attrs/2` → Task 2. ✓
- `run/0` Gather/Decide/Act + injectable body source → Task 3. ✓
- `ResultSync` integration, unconditional-after-sync, injectable fun → Task 4. ✓
- Group-only / `MatchStatus 0` + both scores / min-elapsed guard → Tasks 2 & 3. ✓
- Two-writer exception, never touches `:completed`, `is_live` untouched → enforced by `settle_attrs` guards (Task 2) + the candidate filter (Task 3); documented in Task 5. ✓
- Testing: pure decision (Task 2), `run/0` integration (Task 3), `Ingest` guard + durability (Task 1), fallback-runs orchestration (Task 4). ✓
- Out of scope (KO, provenance column, goals embed) — not implemented, correct. ✓

**Placeholder scan:** none — every step has concrete code/commands.

**Type consistency:** `settle_attrs/2` returns `{:ok, %{status:, home_goals:, away_goals:}}` | `:skip` (Task 2), consumed identically in `run/0` (Task 3). `run/0` returns `%{candidates:, settled:}` (Task 3), consumed in `ResultSync` log + the stub returns the same shape (Task 4). `@result_fields` (Task 1) used only within `Ingest`. ✓
