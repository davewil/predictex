# FIFA-bracket third-placed R32 resolution — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fill resolved team names into R32 placeholder slots (e.g. `3B/E/F/I/J` → `Bosnia & Herzegovina`) from FIFA's `rounds.json` the moment FIFA locks them, so a `:pending` native R32 card flips `:editable` ahead of openfootball — without ever overwriting openfootball's authoritative identity.

**Architecture:** A new pure `Predictex.Fifa.KnockoutTeams` slot-matches each knockout fixture (via the proven `Crosswalk.slot_key/1` 1:1 join) to its FIFA `rounds.json` entry, reads `homeSquadName`/`awaySquadName`, normalizes them to **openfootball-canonical** names (via the existing `Crosswalk.norm/1` alias table + an index of names already in our fixtures), and emits per-fixture fills **only for placeholder sides** (`not Knockout.resolved_team?/1`). A new self-arming `Workers.KnockoutTeams` runs it on the cron. The "fill placeholders only" rule IS the no-downgrade guard — a resolved side is never in the output, so openfootball stays authoritative.

**Tech Stack:** Elixir 1.20 / OTP 28, Oban (cron), Ecto/Postgres. No new deps. **No migration.**

## Global Constraints

- Run mix via mise: **`mise exec -- mix …`** (plain `mix` is the wrong version).
- The gate is **`mix precommit`** (compile --warnings-as-errors, deps.unlock --check-unused, format --check-formatted, credo --strict, test), run on every Elixir-staging commit via lefthook. Never `--no-verify`.
- TDD: failing test first, run-to-fail, implement, run-to-pass, commit.
- New ConnCase/DataCase tests creating multiple rounds insert them **ascending by `:ordinal`** (deadlock invariant, documented in `DataCase.setup_sandbox`).
- The Oban test config is `testing: :manual` — workers are invoked directly in tests (`perform_job` / calling `perform/1`), never via the cron.
- Two-writer rule: this worker writes **only** `team1`/`team2`, never `status`/`live_*`/scores. openfootball (`Ingest`) remains the authority and reclaims on its next sync; KO fixtures key on `source_num` (`g8m`), so a team-name fill never spawns a duplicate.
- **No-downgrade invariant (the keystone):** a side only ever goes placeholder → real. A side where `Knockout.resolved_team?/1` is already true must never appear in a fill. FIFA never demotes a real name to a placeholder and never replaces one real name with a different one.
- All new code covered by tests; test output pristine.

## File Structure

| File | Responsibility |
|------|----------------|
| `lib/predictex/fifa/knockout_teams.ex` | NEW pure: `canonical_index/1`, `plan/3`, and the DB edge `assign/1`. Owns the slot-match + orient + canonical-fill logic. |
| `lib/predictex/workers/knockout_teams.ex` | NEW Oban worker: self-arming (stop when no KO fixture has a placeholder side), fetch `rounds.json` (injectable), call `assign/1`, log coverage. |
| `config/config.exs` (modify) | Add the `KnockoutTeams` cron entry next to `KnockoutIds`. |
| `lib/predictex/results/context.md`-style docs / moduledocs (Task 5) | Cross-reference the two-writer/no-downgrade discipline. |
| Test files | `test/predictex/fifa/knockout_teams_test.exs` (new, pure + DB), `test/predictex/workers/knockout_teams_test.exs` (new), `test/predictex_web/live/my_predictions_live_test.exs` (one new end-to-end flip test). |

## Reused interfaces (already in the codebase — do not re-implement)

- `Predictex.Knockout.resolved_team?(name) :: boolean` — placeholder vs real-name predicate (total).
- `Predictex.Fifa.Crosswalk.slot_key(dt_or_iso) :: {Date.t(), hour, minute} | nil` — KO slot identity (UTC, to the minute). Accepts a `%DateTime{}` (our `kickoff_at`) or FIFA offset-ISO8601 (`t["date"]`).
- `Predictex.Fifa.Crosswalk.norm(name) :: String.t()` — lowercase + collapse whitespace + **FIFA→openfootball alias** (`"bosnia and herzegovina"` → `"bosnia & herzegovina"`, etc.). `norm(nil) == ""`.
- `Predictex.Tournament.update_fixture(%Fixture{}, attrs) :: {:ok, _} | {:error, _}` — the admin/openfootball-shared write (casts only the passed attrs).
- `Predictex.Tournament.broadcast_change() :: :ok` — coarse `"fixtures:changed"` PubSub signal the dashboards re-pull on.
- `Predictex.Fifa.Reference.fetch_rounds() :: {:ok, rounds} | {:error, reason}` — the `rounds.json` fetch (same source `KnockoutIds` uses).
- FIFA `rounds.json` shape: a list of round maps `r` with `r["stage"]` (knockout stages are `~w(r32 r16 qf sf f)`) and `r["tournaments"]` (list of match maps `t` with `t["date"]` ISO8601, `t["homeSquadName"]`, `t["awaySquadName"]`).

---

### Task 1: Pure `Predictex.Fifa.KnockoutTeams` — `canonical_index/1` + `plan/3`

**Files:**
- Create: `lib/predictex/fifa/knockout_teams.ex`, `test/predictex/fifa/knockout_teams_test.exs`

**Interfaces:**
- Consumes: `Knockout.resolved_team?/1`, `Crosswalk.norm/1`, `Crosswalk.slot_key/1`.
- Produces:
  - `canonical_index(names :: [String.t()]) :: %{norm => canonical}` — `norm(name) => name` for every **resolved** name (placeholders skipped). Maps a FIFA/lowercased name back to the openfootball-canonical (properly-cased) team name.
  - `plan(rounds :: list, fixtures :: [%Fixture{}], canonical_index :: map) :: [%{fixture_id: id, optional(:team1) => String.t(), optional(:team2) => String.t()}]` — one entry per fixture that has a placeholder side AND resolves to a canonical fill; each entry carries only the placeholder side(s) it fills.

- [ ] **Step 1: Write the failing test**

Create `test/predictex/fifa/knockout_teams_test.exs`:

```elixir
defmodule Predictex.Fifa.KnockoutTeamsTest do
  use ExUnit.Case, async: true

  alias Predictex.Fifa.KnockoutTeams
  alias Predictex.Tournament.Fixture

  # A FIFA rounds.json R32 entry kicking off at `iso` between FIFA-named home/away.
  defp rounds(iso, home, away) do
    [%{"stage" => "r32", "tournaments" => [%{"date" => iso, "homeSquadName" => home, "awaySquadName" => away}]}]
  end

  # Canonical openfootball names already present in our fixtures (group stage has all 48).
  @canon KnockoutTeams.canonical_index(["USA", "Bosnia & Herzegovina", "Brazil", "Japan", "Mexico"])

  describe "canonical_index/1" do
    test "maps normalized (incl. FIFA alias) names back to the canonical name, skipping placeholders" do
      idx = KnockoutTeams.canonical_index(["Bosnia & Herzegovina", "USA", "3B/E/F/I/J", "1A"])
      # FIFA writes "Bosnia and Herzegovina"; norm aliases it to "bosnia & herzegovina".
      assert idx[Predictex.Fifa.Crosswalk.norm("Bosnia and Herzegovina")] == "Bosnia & Herzegovina"
      assert idx[Predictex.Fifa.Crosswalk.norm("USA")] == "USA"
      # placeholders are not real names → not indexed
      refute Map.has_key?(idx, Predictex.Fifa.Crosswalk.norm("3B/E/F/I/J"))
    end
  end

  describe "plan/3 — one placeholder side, anchored on the resolved side" do
    test "fills the placeholder away side from the FIFA entry matched by slot" do
      ko = ~U[2026-07-02 01:00:00Z]
      f = %Fixture{id: 7, team1: "USA", team2: "3B/E/F/I/J", kickoff_at: ko}
      r = rounds("2026-07-02T01:00:00+00:00", "USA", "Bosnia and Herzegovina")

      assert [%{fixture_id: 7, team2: "Bosnia & Herzegovina"} = fill] = KnockoutTeams.plan(r, [f], @canon)
      refute Map.has_key?(fill, :team1)
    end

    test "respects FIFA home/away orientation: anchor on the resolved side, fill the other" do
      ko = ~U[2026-07-02 01:00:00Z]
      # Our resolved side is team1=USA, but FIFA lists USA as AWAY → the placeholder team2 gets FIFA's HOME.
      f = %Fixture{id: 8, team1: "USA", team2: "3B/E/F/I/J", kickoff_at: ko}
      r = rounds("2026-07-02T01:00:00+00:00", "Bosnia and Herzegovina", "USA")

      assert [%{fixture_id: 8, team2: "Bosnia & Herzegovina"}] = KnockoutTeams.plan(r, [f], @canon)
    end
  end

  describe "plan/3 — guards" do
    test "never emits a resolved side (no-downgrade): a fully-resolved fixture yields nothing" do
      ko = ~U[2026-07-02 01:00:00Z]
      f = %Fixture{id: 9, team1: "USA", team2: "Bosnia & Herzegovina", kickoff_at: ko}
      r = rounds("2026-07-02T01:00:00+00:00", "Mexico", "Brazil")
      assert KnockoutTeams.plan(r, [f], @canon) == []
    end

    test "skips when no FIFA entry matches the fixture's slot" do
      f = %Fixture{id: 10, team1: "USA", team2: "3B/E/F/I/J", kickoff_at: ~U[2026-07-02 01:00:00Z]}
      r = rounds("2026-07-03T20:00:00+00:00", "USA", "Bosnia and Herzegovina")
      assert KnockoutTeams.plan(r, [f], @canon) == []
    end

    test "skips a side whose FIFA name is not a known canonical team (no junk written)" do
      ko = ~U[2026-07-02 01:00:00Z]
      f = %Fixture{id: 11, team1: "USA", team2: "3B/E/F/I/J", kickoff_at: ko}
      r = rounds("2026-07-02T01:00:00+00:00", "USA", "Atlantis")
      assert KnockoutTeams.plan(r, [f], @canon) == []
    end

    test "both placeholders: fills positionally home→team1, away→team2" do
      ko = ~U[2026-07-02 01:00:00Z]
      f = %Fixture{id: 12, team1: "1H", team2: "2J", kickoff_at: ko}
      r = rounds("2026-07-02T01:00:00+00:00", "Brazil", "Japan")
      assert [%{fixture_id: 12, team1: "Brazil", team2: "Japan"}] = KnockoutTeams.plan(r, [f], @canon)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex/fifa/knockout_teams_test.exs`
Expected: FAIL — `Predictex.Fifa.KnockoutTeams.canonical_index/1 is undefined` (module does not exist).

- [ ] **Step 3: Write minimal implementation**

Create `lib/predictex/fifa/knockout_teams.ex`:

```elixir
defmodule Predictex.Fifa.KnockoutTeams do
  @moduledoc """
  Resolve R32 (and later-round) bracket placeholder slots to real team names from FIFA's
  `rounds.json`, ahead of openfootball (predictex-e5o).

  openfootball owns team identity (the two-writer rule). For a knockout fixture that still holds
  a placeholder side (`"3B/E/F/I/J"`, `"1H"`, …), FIFA's `rounds.json` often carries the resolved
  name (`homeSquadName`/`awaySquadName`) earlier — it forces a third-placed slot by elimination as
  groups lock. This module slot-matches our fixture to the FIFA entry (`Crosswalk.slot_key/1`,
  the proven 1:1 knockout join), maps FIFA's name back to the **openfootball-canonical** name
  (`Crosswalk.norm/1` alias table + an index of names already in our fixtures), and fills **only
  the placeholder side(s)** — never a side `Knockout.resolved_team?/1` already calls real. That
  "placeholders only" rule IS the no-downgrade guard: a resolved side is structurally absent from
  the output, so openfootball stays authoritative and reclaims on its next sync.
  """
  import Ecto.Query, only: [from: 2]

  alias Predictex.Fifa.Crosswalk
  alias Predictex.{Knockout, Repo, Tournament}
  alias Predictex.Tournament.Fixture

  @ko_stages ~w(r32 r16 qf sf f)

  @doc "`norm(name) => name` for every resolved name; maps a FIFA/lowercased name to its canonical form."
  def canonical_index(names) do
    for n <- names, Knockout.resolved_team?(n), into: %{}, do: {Crosswalk.norm(n), n}
  end

  @doc """
  Per-fixture fills for placeholder knockout slots. One entry per fixture that has a placeholder
  side AND a canonical FIFA name to fill it with; the entry carries only the placeholder side(s).
  """
  def plan(rounds, fixtures, canonical_index) do
    slot_idx =
      for r <- rounds, r["stage"] in @ko_stages, t <- r["tournaments"] || [], into: %{} do
        {Crosswalk.slot_key(t["date"]), {t["homeSquadName"], t["awaySquadName"]}}
      end

    for f <- fixtures,
        not (Knockout.resolved_team?(f.team1) and Knockout.resolved_team?(f.team2)),
        {home, away} = Map.get(slot_idx, Crosswalk.slot_key(f.kickoff_at), {nil, nil}),
        fill = fill_for(f, home, away, canonical_index),
        map_size(fill) > 0 do
      Map.put(fill, :fixture_id, f.id)
    end
  end

  defp fill_for(f, home, away, idx) do
    t1_ph = not Knockout.resolved_team?(f.team1)
    t2_ph = not Knockout.resolved_team?(f.team2)
    c_home = canonical(idx, home)
    c_away = canonical(idx, away)

    cond do
      t1_ph and t2_ph -> %{} |> maybe_put(:team1, c_home) |> maybe_put(:team2, c_away)
      t1_ph -> anchored(f.team2, :team1, home, away, c_home, c_away)
      t2_ph -> anchored(f.team1, :team2, home, away, c_home, c_away)
      true -> %{}
    end
  end

  # Anchor on the already-resolved side: whichever FIFA side it equals fixes the orientation, so
  # the placeholder side takes the OTHER FIFA name. If the anchor matches neither, the slot match
  # is spurious → fill nothing.
  defp anchored(anchor, fill_key, fifa_home, fifa_away, c_home, c_away) do
    cond do
      Crosswalk.norm(anchor) == Crosswalk.norm(fifa_home) -> maybe_put(%{}, fill_key, c_away)
      Crosswalk.norm(anchor) == Crosswalk.norm(fifa_away) -> maybe_put(%{}, fill_key, c_home)
      true -> %{}
    end
  end

  defp canonical(_idx, nil), do: nil
  defp canonical(idx, name), do: Map.get(idx, Crosswalk.norm(name))

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
```

(`import Ecto.Query` / `Repo` / `Tournament` / `Fixture` are unused until Task 2's `assign/1`; if `--warnings-as-errors` flags them now, add them in Task 2 instead. To keep Task 1 warning-clean, OMIT the `import Ecto.Query` line and the `Repo`/`Tournament`/`Fixture` aliases here and add them in Task 2. Keep only `alias Predictex.Fifa.Crosswalk` and `alias Predictex.Knockout`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/predictex/fifa/knockout_teams_test.exs`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/fifa/knockout_teams.ex test/predictex/fifa/knockout_teams_test.exs
git commit -m "feat(fifa): KnockoutTeams.canonical_index/1 + plan/3 — slot-matched placeholder fills (predictex-e5o)"
```

---

### Task 2: `KnockoutTeams.assign/1` — the DB edge

**Files:**
- Modify: `lib/predictex/fifa/knockout_teams.ex`
- Test: `test/predictex/fifa/knockout_teams_test.exs` (add a `describe "assign/1"` block — these need the DB, so the test module gains DB support)

**Interfaces:**
- Consumes: `plan/3`, `canonical_index/1`, `Tournament.update_fixture/2`, `Tournament.broadcast_change/0`.
- Produces: `assign(rounds) :: %{resolved: n, sides: n, errors: n}` — fetches all fixtures, builds the canonical index from their resolved names, plans, writes each fill via `update_fixture/2`, broadcasts once if anything resolved.

- [ ] **Step 1: Write the failing test**

The pure tests in Task 1 are `async: true` with no DB. `assign/1` hits the Repo. Add a SECOND test module file so the pure tests stay async and DB tests use `DataCase`. Create `test/predictex/fifa/knockout_teams_assign_test.exs`:

```elixir
defmodule Predictex.Fifa.KnockoutTeamsAssignTest do
  use Predictex.DataCase, async: true

  alias Predictex.Fifa.KnockoutTeams
  alias Predictex.{Predictions, Tournament}
  alias Predictex.Tournament.Fixture

  defp ko_round! do
    # Group round first (ascending ordinal) so the canonical index has real names to draw on.
    {:ok, grp} = Tournament.create_round(%{name: "Group", stage: :group, ordinal: 1})
    past = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.truncate(:second)
    # Seed every team that will appear in the bracket as a real (openfootball-canonical) name.
    for {a, b} <- [{"USA", "Mexico"}, {"Bosnia & Herzegovina", "Brazil"}] do
      {:ok, _} = Tournament.create_fixture(grp, %{team1: a, team2: b, kickoff_at: past, status: :completed, home_goals: 1, away_goals: 0})
    end

    {:ok, ko} = Tournament.create_round(%{name: "Round of 32", stage: :knockout, ordinal: 4})
    ko
  end

  defp rounds(iso, home, away) do
    [%{"stage" => "r32", "tournaments" => [%{"date" => iso, "homeSquadName" => home, "awaySquadName" => away}]}]
  end

  test "fills a placeholder side, writes it, and reports the summary" do
    ko = ko_round!()
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    {:ok, fx} = Tournament.create_fixture(ko, %{team1: "USA", team2: "3B/E/F/I/J", kickoff_at: future})
    iso = DateTime.to_iso8601(future)

    assert %{resolved: 1, sides: 1, errors: 0} = KnockoutTeams.assign(rounds(iso, "USA", "Bosnia and Herzegovina"))
    assert Repo.get!(Fixture, fx.id).team2 == "Bosnia & Herzegovina"
  end

  test "no-downgrade: a divergent FIFA name never overwrites an already-resolved side" do
    ko = ko_round!()
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    {:ok, fx} = Tournament.create_fixture(ko, %{team1: "USA", team2: "Mexico", kickoff_at: future})
    iso = DateTime.to_iso8601(future)

    # FIFA (hypothetically) disagrees — must be ignored; openfootball-resolved names stand.
    assert %{resolved: 0} = KnockoutTeams.assign(rounds(iso, "Brazil", "Japan"))
    reloaded = Repo.get!(Fixture, fx.id)
    assert reloaded.team1 == "USA" and reloaded.team2 == "Mexico"
  end

  test "idempotent: re-running after a fill writes nothing more" do
    ko = ko_round!()
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    {:ok, _} = Tournament.create_fixture(ko, %{team1: "USA", team2: "3B/E/F/I/J", kickoff_at: future})
    iso = DateTime.to_iso8601(future)
    r = rounds(iso, "USA", "Bosnia and Herzegovina")

    assert %{resolved: 1} = KnockoutTeams.assign(r)
    assert %{resolved: 0} = KnockoutTeams.assign(r)
  end
end
```

> Note: confirm `Tournament.create_fixture/2`'s real name/arity by reading `lib/predictex/tournament.ex` — if the test helpers elsewhere use a different constructor (e.g. a `fixture!/2` support helper), mirror that. The assertion semantics (placeholder filled / resolved side untouched / idempotent) are what matter.

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex/fifa/knockout_teams_assign_test.exs`
Expected: FAIL — `KnockoutTeams.assign/1 is undefined`.

- [ ] **Step 3: Write minimal implementation**

In `lib/predictex/fifa/knockout_teams.ex`, add the `import Ecto.Query, only: [from: 2]` and `alias Predictex.{Knockout, Repo, Tournament}` + `alias Predictex.Tournament.Fixture` (alongside the existing `Crosswalk`/`Knockout` aliases — fold `Knockout` into the grouped alias), then add:

```elixir
  @doc """
  Resolve every fillable placeholder knockout slot from `rounds` and persist it. Returns
  `%{resolved: fixtures_written, sides: name_columns_written, errors: n}` and broadcasts a
  fixtures-changed signal when anything was written. openfootball reclaims authority on its next
  sync (two-writer rule).
  """
  def assign(rounds) do
    fixtures = Repo.all(from(f in Fixture))
    by_id = Map.new(fixtures, &{&1.id, &1})
    idx = canonical_index(Enum.flat_map(fixtures, &[&1.team1, &1.team2]))

    summary =
      rounds
      |> plan(fixtures, idx)
      |> Enum.reduce(%{resolved: 0, sides: 0, errors: 0}, fn fill, acc ->
        {fid, attrs} = Map.pop(fill, :fixture_id)

        case Tournament.update_fixture(Map.fetch!(by_id, fid), attrs) do
          {:ok, _} -> %{acc | resolved: acc.resolved + 1, sides: acc.sides + map_size(attrs)}
          {:error, _} -> %{acc | errors: acc.errors + 1}
        end
      end)

    if summary.resolved > 0, do: Tournament.broadcast_change()
    summary
  end
```

Note: `plan/3` already excludes group fixtures (they have no placeholder side), so passing all fixtures is safe — only knockout placeholder slots can produce a fill.

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/predictex/fifa/knockout_teams_assign_test.exs test/predictex/fifa/knockout_teams_test.exs`
Expected: PASS (3 + 6).

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/fifa/knockout_teams.ex test/predictex/fifa/knockout_teams_assign_test.exs
git commit -m "feat(fifa): KnockoutTeams.assign/1 — persist placeholder fills, no-downgrade (predictex-e5o)"
```

---

### Task 3: `Workers.KnockoutTeams` — self-arming cron worker

**Files:**
- Create: `lib/predictex/workers/knockout_teams.ex`, `test/predictex/workers/knockout_teams_test.exs`

**Interfaces:**
- Consumes: `KnockoutTeams.assign/1`, `Knockout.resolved_team?/1`, `Reference.fetch_rounds/0`.
- Produces: `Predictex.Workers.KnockoutTeams.perform/1` — when any knockout fixture still has a placeholder side, fetch `rounds.json` (injectable via `:ko_teams_rounds_fun`) and call `assign/1`; otherwise no-op without touching the network. Logs coverage.

- [ ] **Step 1: Write the failing test**

Create `test/predictex/workers/knockout_teams_test.exs`:

```elixir
defmodule Predictex.Workers.KnockoutTeamsTest do
  use Predictex.DataCase, async: true

  alias Predictex.Tournament
  alias Predictex.Tournament.Fixture
  alias Predictex.Workers.KnockoutTeams, as: Worker

  setup do
    on_exit(fn -> Application.delete_env(:predictex, :ko_teams_rounds_fun) end)
    :ok
  end

  defp stub_rounds(fun), do: Application.put_env(:predictex, :ko_teams_rounds_fun, fun)

  defp seeded_ko_fixture do
    {:ok, grp} = Tournament.create_round(%{name: "Group", stage: :group, ordinal: 1})
    past = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.truncate(:second)
    {:ok, _} = Tournament.create_fixture(grp, %{team1: "USA", team2: "Bosnia & Herzegovina", kickoff_at: past, status: :completed, home_goals: 1, away_goals: 0})
    {:ok, ko} = Tournament.create_round(%{name: "Round of 32", stage: :knockout, ordinal: 4})
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    {:ok, fx} = Tournament.create_fixture(ko, %{team1: "USA", team2: "3B/E/F/I/J", kickoff_at: future})
    {fx, DateTime.to_iso8601(future)}
  end

  test "fetches and fills when a knockout fixture has a placeholder side" do
    {fx, iso} = seeded_ko_fixture()

    stub_rounds(fn ->
      {:ok, [%{"stage" => "r32", "tournaments" => [%{"date" => iso, "homeSquadName" => "USA", "awaySquadName" => "Bosnia and Herzegovina"}]}]}
    end)

    assert :ok = Worker.perform(%Oban.Job{args: %{}})
    assert Repo.get!(Fixture, fx.id).team2 == "Bosnia & Herzegovina"
  end

  test "stop-before-fetch: no network call when every knockout fixture is fully resolved" do
    {:ok, grp} = Tournament.create_round(%{name: "Group", stage: :group, ordinal: 1})
    past = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.truncate(:second)
    {:ok, _} = Tournament.create_fixture(grp, %{team1: "USA", team2: "Mexico", kickoff_at: past, status: :completed, home_goals: 1, away_goals: 0})
    {:ok, ko} = Tournament.create_round(%{name: "Round of 32", stage: :knockout, ordinal: 4})
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    {:ok, _} = Tournament.create_fixture(ko, %{team1: "USA", team2: "Mexico", kickoff_at: future})

    stub_rounds(fn -> raise "must not fetch when nothing is pending" end)
    assert :ok = Worker.perform(%Oban.Job{args: %{}})
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex/workers/knockout_teams_test.exs`
Expected: FAIL — `Predictex.Workers.KnockoutTeams.perform/1 is undefined` (module does not exist).

- [ ] **Step 3: Write minimal implementation**

Create `lib/predictex/workers/knockout_teams.ex` (mirrors `Workers.KnockoutIds`):

```elixir
defmodule Predictex.Workers.KnockoutTeams do
  @moduledoc """
  Self-arming knockout team-name backfill (predictex-e5o). FIFA's `rounds.json` resolves a
  bracket slot (incl. third-placed: `3B/E/F/I/J` → `Bosnia & Herzegovina`) ahead of openfootball;
  this worker fills the placeholder side from FIFA so the native R32 card flips `:editable` sooner.

    * **Stop before fetch** — if no knockout fixture still holds a placeholder side, it no-ops
      without touching the network.
    * Otherwise it fetches `rounds.json` and runs `Fifa.KnockoutTeams.assign/1` (placeholders only;
      openfootball stays authoritative — the no-downgrade guard).

  The rounds source is injectable (`:ko_teams_rounds_fun`) for network-free tests. Transient —
  deletable from the cron once the bracket teams are fully resolved.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger
  import Ecto.Query

  alias Predictex.Fifa.{KnockoutTeams, Reference}
  alias Predictex.{Knockout, Repo}
  alias Predictex.Tournament.Fixture

  @impl Oban.Worker
  def perform(_job) do
    if ko_teams_pending?() do
      case rounds_fun().() do
        {:ok, rounds} ->
          summary = KnockoutTeams.assign(rounds)
          Logger.info("knockout team backfill: #{inspect(summary)} (#{coverage()})")
          :ok

        {:error, reason} ->
          Logger.error("knockout team backfill: rounds fetch failed: #{inspect(reason)}")
          {:error, reason}
      end
    else
      :ok
    end
  end

  defp ko_teams_pending? do
    from(f in Fixture, join: r in assoc(f, :round), where: r.stage == :knockout, select: {f.team1, f.team2})
    |> Repo.all()
    |> Enum.any?(fn {t1, t2} -> not (Knockout.resolved_team?(t1) and Knockout.resolved_team?(t2)) end)
  end

  defp coverage do
    rows =
      from(f in Fixture, join: r in assoc(f, :round), where: r.stage == :knockout, select: {f.team1, f.team2})
      |> Repo.all()

    resolved = Enum.count(rows, fn {t1, t2} -> Knockout.resolved_team?(t1) and Knockout.resolved_team?(t2) end)
    "KO teams resolved: #{resolved}/#{length(rows)}"
  end

  defp rounds_fun do
    Application.get_env(:predictex, :ko_teams_rounds_fun, &Reference.fetch_rounds/0)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/predictex/workers/knockout_teams_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Register the cron entry**

In `config/config.exs`, add the worker beneath `KnockoutIds` (line ~102) inside the `crontab:` list:

```elixir
       {"*/10 * * * *", Predictex.Workers.KnockoutIds},
       # Fills knockout team names from FIFA rounds.json ahead of openfootball (predictex-e5o);
       # stop-before-fetch no-ops once the bracket teams are fully resolved. Removable post-bracket.
       {"*/10 * * * *", Predictex.Workers.KnockoutTeams}
```

(Add the trailing comma after the `KnockoutIds` tuple that currently ends the list.)

- [ ] **Step 6: Run the gate**

Run: `mise exec -- mix precommit`
Expected: green (compile/format/credo/test).

- [ ] **Step 7: Commit**

```bash
git add lib/predictex/workers/knockout_teams.ex test/predictex/workers/knockout_teams_test.exs config/config.exs
git commit -m "feat(workers): self-arming KnockoutTeams cron worker + registration (predictex-e5o)"
```

---

### Task 4: End-to-end — a `:pending` R32 card flips `:editable` after FIFA resolution; docs

**Files:**
- Test: `test/predictex_web/live/my_predictions_live_test.exs` (one new `@tag :native_ko` test)
- Modify (docs): the `Predictex.Fifa.KnockoutTeams` moduledoc cross-link + `CONTEXT.md` term if present.

**Interfaces:**
- Consumes: `Workers.KnockoutTeams.perform/1` (or `KnockoutTeams.assign/1`), `Predictions.fixture_entry_state/2`, the `:native_ko` flag-enabled render from `80k`.

- [ ] **Step 1: Write the failing test**

In `test/predictex_web/live/my_predictions_live_test.exs`, add (the `@tag :native_ko` setup enables the flag + flushes the cache on exit — reuse it):

```elixir
  @tag :native_ko
  test "a :pending R32 card flips to :editable after FIFA resolves its placeholder side",
       %{conn: conn, round: round} do
    player = player_fixture(%{display_name: "FifaResolve"})
    past = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.truncate(:second)
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    # Group fixtures supply the canonical names; close ordinal-1 so it doesn't steal "active".
    _g = fixture!(round, %{team1: "USA", team2: "Bosnia & Herzegovina", kickoff_at: past, status: :completed, home_goals: 1, away_goals: 0})

    {:ok, ko} = Tournament.create_round(%{name: "Round of 32", stage: :knockout, ordinal: 4})
    ko_fx = fixture!(ko, %{team1: "USA", team2: "3B/E/F/I/J", kickoff_at: future})

    {:ok, lv, _html} = conn |> log_in_player(player) |> live(~p"/predictions")
    html = lv |> element("button", "Round of 32") |> render_click()
    refute html =~ ~s(name="picks[#{ko_fx.id}][home_goals]")
    assert html =~ "awaiting teams"

    # FIFA rounds.json resolves the slot; the worker fills the placeholder side.
    Application.put_env(:predictex, :ko_teams_rounds_fun, fn ->
      {:ok, [%{"stage" => "r32", "tournaments" => [%{"date" => DateTime.to_iso8601(future), "homeSquadName" => "USA", "awaySquadName" => "Bosnia and Herzegovina"}]}]}
    end)
    on_exit(fn -> Application.delete_env(:predictex, :ko_teams_rounds_fun) end)

    assert :ok = Predictex.Workers.KnockoutTeams.perform(%Oban.Job{args: %{}})
    # assign/1 broadcasts :fixtures_changed → the open dashboard re-pulls.
    html = render(lv)

    assert html =~ ~s(name="picks[#{ko_fx.id}][home_goals]")
    assert html =~ "Bosnia &amp; Herzegovina"
  end
```

> If the broadcast does not reach the LiveView in the test (no subscription in the test process), drive the re-pull the same way the other `:native_ko` tests do (e.g. `Tournament.broadcast_change()` is already called inside `assign/1`; if the LiveView needs an explicit nudge, send the `:fixtures_changed`/tick the test harness uses). Confirm by reading how the existing per-fixture-resolution test (predictex-80k) re-renders after `broadcast_change()`.

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex_web/live/my_predictions_live_test.exs --only native_ko`
Expected: FAIL before the worker exists/wires — but since Tasks 1-3 are done, it should fail only if the flip doesn't happen; if it passes immediately, confirm the `refute` (pre-fill) and `assert` (post-fill) both exercise the change (temporarily skip the worker call to see the `refute`-only state stay pending).

- [ ] **Step 3: Make it pass**

No new production code expected (Tasks 1-3 deliver the behavior). If the re-render needs wiring, adjust per the Step 1 note. Keep the change minimal.

- [ ] **Step 4: Docs**

Ensure the `Predictex.Fifa.KnockoutTeams` moduledoc cross-references the two-writer rule and `predictex-iy1` `FifaFallback` as the sibling no-downgrade precedent. If `CONTEXT.md` exists with a glossary, add a "FIFA bracket resolution" term mirroring the "FIFA result fallback" term.

- [ ] **Step 5: Run the full gate**

Run: `mise exec -- mix precommit`
Expected: green.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "test(fifa): :pending R32 card flips :editable after FIFA team resolution + docs (predictex-e5o)"
```

---

## Self-Review

**Spec coverage:**
- Source early resolution from FIFA `rounds.json` (decision 1) → Task 1 `plan/3` slot index + Task 3 worker fetch. ✓
- No-downgrade / no-overwrite guard (decision 2, the keystone) → "placeholders only" in `fill_for/4`; Task 2 no-downgrade test; structural (resolved sides never in output). ✓
- Trigger + guard are the same `Knockout.resolved_team?/1` (decision 3) → used in `canonical_index/1`, `plan/3`, worker `ko_teams_pending?/0`. ✓
- Reuse the existing cron/worker path, self-arming + stop-before-fetch (decision 4) → Task 3 worker mirrors `KnockoutIds`; separate worker (not piggybacked on `KnockoutIds`' id-based stop, which would halt before names resolve). ✓
- FIFA-filled name is provisional; openfootball reclaims (decision 5) → writes only team1/team2 via `update_fixture/2`; `source_num` identity preserved; documented. ✓
- Canonical (openfootball) naming via the alias table → `Crosswalk.norm/1` + `canonical_index/1` from existing fixture names (avoids flag-miss + openfootball churn). ✓
- End-to-end `:pending`→`:editable` flip → Task 4. ✓
- No migration / no new deps → confirmed. ✓

**Placeholder scan:** No "TBD/handle edge cases" — every step has concrete code. The two conditional notes (Task 1 Step 3 alias-omission to stay warning-clean; Task 4 Step 1 re-render wiring) each specify both branches and how to confirm, not a deferral.

**Type consistency:** `canonical_index/1 :: %{norm => canonical}` consumed by `plan/3` and `assign/1`. `plan/3 :: [%{fixture_id, optional team1/team2}]` consumed by `assign/1`'s reduce (`Map.pop(:fixture_id)` → attrs). `assign/1 :: %{resolved, sides, errors}` asserted in Task 2/3 tests. `Crosswalk.slot_key/1`, `norm/1` signatures match the reused-interfaces block. Consistent.

## Notes for the implementer

- The orientation rule has two cases: **anchored** (one side already resolved — the safe, high-value path: USA v `3B/E/F/I/J`) keys orientation off the resolved side; **both-placeholder** fills positionally (FIFA home→team1). Both go through the canonical lookup and the placeholder-only guard, so neither can overwrite a real name.
- Why a separate worker (not extend `KnockoutIds`): `KnockoutIds` stops fetching once every KO fixture has a `fifa_match_id`, but a slot can carry its `fifaId` before FIFA fills its third-placed *name* — so the id-stop would halt before names resolve. `KnockoutTeams` has its own placeholder-based stop condition.
- Do NOT write a raw FIFA name — always map through `canonical_index/1` so the stored name is openfootball-canonical (flags resolve via `Flags.flag/1`, and openfootball's later sync matches without churn). A FIFA name with no canonical match is skipped, not written.
- After this lands, no flag/rollout step — it only ever *fills* placeholders, so it's a no-op until FIFA resolves a slot; member visibility stays gated by `:native_ko_entry`.
