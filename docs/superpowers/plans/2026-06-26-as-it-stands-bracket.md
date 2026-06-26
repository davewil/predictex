# "As it stands" projected R32 bracket — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A public `/bracket` page showing the projected Round of 32 "as it stands" — live group tables (A–L) plus the R32 matchups they imply — computed from actual results.

**Architecture:** Pure cores at the centre, effects at the edges (the repo's `Ranking`/`Standings` grain). `GroupTables` (pure) computes the 12 group tables; `Bracket.Thirds` (pure) ranks the best-8-of-12 thirds; `Bracket` (pure, total) resolves each R32 placeholder slot into a renderable value; a thin Gather edge loads the fixtures; `BracketLive` (public) renders and re-pulls on the existing `:fixtures_changed` PubSub.

**Tech Stack:** Elixir 1.20 / OTP 28, Phoenix 1.8 LiveView, Ecto/Postgres. No new deps. **No migration.**

## Global Constraints

- Run mix via mise: **`mise exec -- mix …`** (plain `mix` is the wrong version).
- The gate is **`mix precommit`** (compile --warnings-as-errors, deps.unlock --check-unused, format --check-formatted, credo --strict, test); it runs on every Elixir-staging commit via lefthook. Never `--no-verify`.
- New ConnCase live-test files run `async: true`; when a test creates multiple rounds, insert them **ascending by `:ordinal`** (DataCase deadlock invariant).
- All new code must be covered by tests (TDD below).
- Third-placed slots render as **candidate sets** (never a guessed team) — exact named thirds arrive later via the existing openfootball/`Workers.KnockoutIds` ingest (the `{:resolved, name}` branch). No 495-row FIFA table (see the spike).
- Bracket scope is **R32 only**. The R32 round is the **knockout round with the lowest `ordinal`**.
- The placeholder parser MUST be **total** — every input maps to a renderable value, never raises.

## File Structure

| File | Responsibility |
|------|----------------|
| `lib/predictex/group_tables.ex` | Pure: `Row` struct + `build/1` → ranked group tables `%{group => [Row]}`. |
| `lib/predictex/bracket/thirds.ex` | Pure: `ranked/1` → best-8-of-12 thirds ranking + cutoff tie flag. |
| `lib/predictex/bracket.ex` | Pure (total) `resolve_slot/2` + `build/2`; Gather edge `view/0`. |
| `lib/predictex/tournament.ex` (modify) | Add `group_stage_fixtures/0` + `r32_fixtures/0` queries. |
| `lib/predictex_web/live/bracket_live.ex` | Public `/bracket` LiveView; renders bracket + tables + thirds panel; live re-pull. |
| `lib/predictex_web/router.ex` (modify) | Add `live "/bracket", BracketLive, :index` to the `:public` session. |
| `lib/predictex_web/components/layouts/root.html.heex` (modify) | Add a "Bracket" nav link. |
| `test/predictex/group_tables_test.exs` | Unit tests for the group-table maths + ties. |
| `test/predictex/bracket/thirds_test.exs` | Unit tests for the thirds ranking + cutoff. |
| `test/predictex/bracket_test.exs` | Unit tests for `resolve_slot/2` totality + `build/2`. |
| `test/predictex_web/live/bracket_live_test.exs` | Public mount, render, live update. |

---

### Task 1: Gather queries on `Tournament`

**Files:**
- Modify: `lib/predictex/tournament.ex`
- Test: `test/predictex/tournament_test.exs` (create if absent)

**Interfaces:**
- Produces: `Tournament.group_stage_fixtures() :: [%Fixture{}]` (all fixtures whose round is `stage: :group`); `Tournament.r32_fixtures() :: [%Fixture{}]` (fixtures of the lowest-ordinal `:knockout` round, ordered by `source_num`; `[]` when no knockout round exists).

- [ ] **Step 1: Write the failing test**

Append to `test/predictex/tournament_test.exs` (create the file with this content if it does not exist):

```elixir
defmodule Predictex.TournamentTest do
  use Predictex.DataCase, async: true

  alias Predictex.Tournament

  defp fixture!(round, attrs) do
    base = %{
      external_ref: "ref-#{System.unique_integer([:positive])}",
      team1: "A",
      team2: "B",
      status: :scheduled,
      round_id: round.id
    }

    {:ok, f} = Tournament.create_fixture(Map.merge(base, attrs))
    f
  end

  describe "group_stage_fixtures/0 and r32_fixtures/0" do
    test "partitions group-stage from the first knockout round" do
      # Insert rounds ascending by ordinal (DataCase deadlock invariant).
      {:ok, g1} = Tournament.create_round(%{name: "Matchday 1", stage: :group, ordinal: 1})
      {:ok, r32} = Tournament.create_round(%{name: "Round of 32", stage: :knockout, ordinal: 4})
      {:ok, r16} = Tournament.create_round(%{name: "Round of 16", stage: :knockout, ordinal: 5})

      gf = fixture!(g1, %{group: "A"})
      k_b = fixture!(r32, %{team1: "1A", team2: "2B", source_num: 74})
      k_a = fixture!(r32, %{team1: "1C", team2: "2D", source_num: 73})
      _r16f = fixture!(r16, %{team1: "W73", team2: "W74", source_num: 89})

      assert Enum.map(Tournament.group_stage_fixtures(), & &1.id) == [gf.id]
      # R32 = lowest-ordinal knockout round, ordered by source_num.
      assert Enum.map(Tournament.r32_fixtures(), & &1.id) == [k_a.id, k_b.id]
    end

    test "r32_fixtures is empty when there is no knockout round" do
      {:ok, g1} = Tournament.create_round(%{name: "Matchday 1", stage: :group, ordinal: 1})
      _gf = fixture!(g1, %{group: "A"})
      assert Tournament.r32_fixtures() == []
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex/tournament_test.exs`
Expected: FAIL — `function Predictex.Tournament.group_stage_fixtures/0 is undefined`.

- [ ] **Step 3: Write minimal implementation**

In `lib/predictex/tournament.ex`, add these two functions (next to the other fixture queries, after `get_fixture_by_source_num/1`). The module already aliases `Round`, `Fixture` and imports `Ecto.Query`.

```elixir
@doc "All group-stage fixtures (round `stage: :group`)."
def group_stage_fixtures do
  Repo.all(
    from f in Fixture,
      join: r in Round,
      on: f.round_id == r.id,
      where: r.stage == :group
  )
end

@doc """
Fixtures of the Round of 32 — the lowest-`ordinal` `:knockout` round — ordered by
`source_num`. Returns `[]` when no knockout round exists yet.
"""
def r32_fixtures do
  r32_id =
    Repo.one(
      from r in Round,
        where: r.stage == :knockout,
        order_by: [asc: r.ordinal],
        limit: 1,
        select: r.id
    )

  case r32_id do
    nil -> []
    id -> Repo.all(from f in Fixture, where: f.round_id == ^id, order_by: [asc: f.source_num])
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/predictex/tournament_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/tournament.ex test/predictex/tournament_test.exs
git commit -m "feat(tournament): group_stage_fixtures/0 + r32_fixtures/0 gather queries (predictex-7qu)"
```

---

### Task 2: `Predictex.GroupTables` — pure group-table computation

**Files:**
- Create: `lib/predictex/group_tables.ex`
- Test: `test/predictex/group_tables_test.exs`

**Interfaces:**
- Consumes: fixture-like values with `.group`, `.team1`, `.team2`, `.home_goals`, `.away_goals`, `.status` (a `%Fixture{}` or a plain map with those keys).
- Produces: `GroupTables.build(fixtures) :: %{group_letter => [GroupTables.Row.t()]}`, each list sorted best-first. `GroupTables.Row` struct: `team, group, played, won, drawn, lost, gf, ga, gd, points, rank, provisional_tie?`.

- [ ] **Step 1: Write the failing test**

Create `test/predictex/group_tables_test.exs`:

```elixir
defmodule Predictex.GroupTablesTest do
  use ExUnit.Case, async: true

  alias Predictex.GroupTables
  alias Predictex.GroupTables.Row

  defp fx(group, t1, t2, hg, ag, status \\ :completed) do
    %{group: group, team1: t1, team2: t2, home_goals: hg, away_goals: ag, status: status}
  end

  test "ranks a group by points, then goal difference, then goals for" do
    # Group A: Mexico beats Poland 2-0; Argentina beats Poland 1-0; Mexico draws Argentina 1-1.
    fixtures = [
      fx("A", "Mexico", "Poland", 2, 0),
      fx("A", "Argentina", "Poland", 1, 0),
      fx("A", "Mexico", "Argentina", 1, 1)
    ]

    [a, b, c] = GroupTables.build(fixtures)["A"]

    # Mexico: 4 pts, GD +2. Argentina: 4 pts, GD +1. Poland: 0 pts, GD -3.
    assert {a.team, a.rank, a.points, a.gd} == {"Mexico", 1, 4, 2}
    assert {b.team, b.rank, b.points, b.gd} == {"Argentina", 2, 4, 1}
    assert {c.team, c.rank, c.points, c.gd} == {"Poland", 3, 0, -3}
    assert %Row{} = a
  end

  test "counts wins, draws, losses, goals for/against and played" do
    fixtures = [fx("B", "Spain", "Japan", 3, 1), fx("B", "Spain", "Brazil", 0, 0)]
    spain = GroupTables.build(fixtures)["B"] |> Enum.find(&(&1.team == "Spain"))

    assert {spain.played, spain.won, spain.drawn, spain.lost} == {2, 1, 1, 0}
    assert {spain.gf, spain.ga, spain.points} == {3, 1, 4}
  end

  test "ignores fixtures that are not completed or have no score" do
    fixtures = [
      fx("C", "Italy", "Wales", 2, 0),
      fx("C", "Italy", "Ghana", nil, nil, :scheduled),
      fx("C", "Wales", "Ghana", 0, 0, :live)
    ]

    italy = GroupTables.build(fixtures)["C"] |> Enum.find(&(&1.team == "Italy"))
    assert italy.played == 1
    # Ghana appears (it's in the group) but has played nothing.
    ghana = GroupTables.build(fixtures)["C"] |> Enum.find(&(&1.team == "Ghana"))
    assert ghana.played == 0
  end

  test "marks adjacent teams level on points+GD+GF as a provisional tie" do
    # Two teams dead level: each beat the same patsy 1-0, drew each other 0-0.
    fixtures = [
      fx("D", "Kenya", "Chad", 1, 0),
      fx("D", "Mali", "Chad", 1, 0),
      fx("D", "Kenya", "Mali", 0, 0)
    ]

    rows = GroupTables.build(fixtures)["D"]
    [r1, r2 | _] = rows
    assert r1.provisional_tie?
    assert r2.provisional_tie?
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex/group_tables_test.exs`
Expected: FAIL — `Predictex.GroupTables.build/1 is undefined`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/predictex/group_tables.ex`:

```elixir
defmodule Predictex.GroupTables do
  @moduledoc """
  Pure (DB-free) computation of the football group tables "as it stands" from actual
  results — the foundation of the projected R32 bracket (`predictex-7qu`).

  Only `:completed` fixtures with integer scores contribute to the table (a live or
  scheduled fixture is not yet a result). Own goals are already reflected in the score, so
  no special handling is needed. Tiebreakers are pragmatic — points → goal difference →
  goals for → team name (stable) — with `provisional_tie?` flagging any row level with a
  neighbour on points+GD+GF.
  """

  alias Predictex.GroupTables.Row

  defmodule Row do
    @moduledoc "One team's standing within its group."
    @enforce_keys [:team, :group]
    defstruct team: nil,
              group: nil,
              played: 0,
              won: 0,
              drawn: 0,
              lost: 0,
              gf: 0,
              ga: 0,
              gd: 0,
              points: 0,
              rank: nil,
              provisional_tie?: false

    @type t :: %__MODULE__{}
  end

  @doc "Build `%{group_letter => [Row.t()]}` from a list of group-stage fixtures."
  def build(fixtures) do
    fixtures
    |> Enum.filter(& &1.group)
    |> Enum.group_by(& &1.group)
    |> Map.new(fn {group, fxs} -> {group, rank_group(group, fxs)} end)
  end

  defp rank_group(group, fxs) do
    fxs
    |> init_rows(group)
    |> tally(fxs)
    |> Map.values()
    |> Enum.sort_by(fn r -> {-r.points, -r.gd, -r.gf, r.team} end)
    |> assign_ranks()
  end

  defp init_rows(fxs, group) do
    fxs
    |> Enum.flat_map(&[&1.team1, &1.team2])
    |> Enum.uniq()
    |> Map.new(fn team -> {team, %Row{team: team, group: group}} end)
  end

  defp tally(rows, fxs), do: Enum.reduce(fxs, rows, &apply_fixture/2)

  defp apply_fixture(%{status: :completed, team1: h, team2: a, home_goals: hg, away_goals: ag}, rows)
       when is_integer(hg) and is_integer(ag) do
    rows |> update_row(h, hg, ag) |> update_row(a, ag, hg)
  end

  defp apply_fixture(_fixture, rows), do: rows

  defp update_row(rows, team, gf, ga) do
    Map.update!(rows, team, fn r ->
      {w, d, l, pts} =
        cond do
          gf > ga -> {1, 0, 0, 3}
          gf == ga -> {0, 1, 0, 1}
          true -> {0, 0, 1, 0}
        end

      %Row{
        r
        | played: r.played + 1,
          won: r.won + w,
          drawn: r.drawn + d,
          lost: r.lost + l,
          gf: r.gf + gf,
          ga: r.ga + ga,
          gd: r.gd + (gf - ga),
          points: r.points + pts
      }
    end)
  end

  defp assign_ranks(sorted) do
    keys = Enum.map(sorted, &tie_key/1)
    n = length(sorted)

    sorted
    |> Enum.with_index()
    |> Enum.map(fn {r, i} ->
      tied? =
        (i > 0 and Enum.at(keys, i - 1) == Enum.at(keys, i)) or
          (i < n - 1 and Enum.at(keys, i + 1) == Enum.at(keys, i))

      %Row{r | rank: i + 1, provisional_tie?: tied?}
    end)
  end

  defp tie_key(r), do: {r.points, r.gd, r.gf}
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/predictex/group_tables_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/group_tables.ex test/predictex/group_tables_test.exs
git commit -m "feat(group-tables): pure as-it-stands group standings (predictex-7qu)"
```

---

### Task 3: `Predictex.Bracket.Thirds` — best-8-of-12 ranking

**Files:**
- Create: `lib/predictex/bracket/thirds.ex`
- Test: `test/predictex/bracket/thirds_test.exs`

**Interfaces:**
- Consumes: `%{group_letter => [GroupTables.Row.t()]}` (output of `GroupTables.build/1`).
- Produces: `Thirds.ranked(group_tables) :: %{entries: [entry], cutoff_provisional?: boolean}` where `entry :: %{position: pos_integer, qualifying?: boolean, row: GroupTables.Row.t()}`. `qualifying?` is `position <= 8`. `cutoff_provisional?` is true when positions 8 and 9 are level on points+GD+GF.

- [ ] **Step 1: Write the failing test**

Create `test/predictex/bracket/thirds_test.exs`:

```elixir
defmodule Predictex.Bracket.ThirdsTest do
  use ExUnit.Case, async: true

  alias Predictex.Bracket.Thirds
  alias Predictex.GroupTables.Row

  # Build a group_tables map where each group's 3rd-placed team has the given points/gd.
  defp tables_with_thirds(specs) do
    Map.new(specs, fn {group, pts, gd} ->
      third = %Row{team: "3rd-#{group}", group: group, rank: 3, points: pts, gd: gd, gf: gd}
      # rows 1 and 2 just need to exist so Enum.at(rows, 2) is the third.
      top = [%Row{team: "1-#{group}", group: group, rank: 1}, %Row{team: "2-#{group}", group: group, rank: 2}]
      {group, top ++ [third]}
    end)
  end

  test "ranks thirds across groups and marks the top 8 as qualifying" do
    # 12 groups A..L with descending points so the order is deterministic.
    specs = for {g, i} <- Enum.with_index(~w(A B C D E F G H I J K L)), do: {g, 30 - i, 0}
    %{entries: entries} = Thirds.ranked(tables_with_thirds(specs))

    assert length(entries) == 12
    assert Enum.at(entries, 0).position == 1
    assert Enum.at(entries, 0).qualifying?
    assert Enum.at(entries, 7).qualifying?
    refute Enum.at(entries, 8).qualifying?
  end

  test "flags a provisional cutoff tie when 8th and 9th are level" do
    # Groups A..G strong; H and I dead level on the 8/9 boundary; J,K,L weakest.
    specs =
      [{"A", 9, 5}, {"B", 9, 4}, {"C", 9, 3}, {"D", 9, 2}, {"E", 9, 1}, {"F", 8, 2}, {"G", 8, 1}] ++
        [{"H", 6, 0}, {"I", 6, 0}, {"J", 3, 0}, {"K", 2, 0}, {"L", 1, 0}]

    assert %{cutoff_provisional?: true} = Thirds.ranked(tables_with_thirds(specs))
  end

  test "no cutoff tie when 8th and 9th differ" do
    specs = for {g, i} <- Enum.with_index(~w(A B C D E F G H I J K L)), do: {g, 30 - i, 0}
    assert %{cutoff_provisional?: false} = Thirds.ranked(tables_with_thirds(specs))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex/bracket/thirds_test.exs`
Expected: FAIL — `Predictex.Bracket.Thirds.ranked/1 is undefined`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/predictex/bracket/thirds.ex`:

```elixir
defmodule Predictex.Bracket.Thirds do
  @moduledoc """
  Pure best-8-of-12 third-placed ranking for the projected R32 (`predictex-7qu`).

  In the 2026 format the eight best third-placed teams (of twelve groups) reach the Round
  of 32. This ranks each group's 3rd-placed row across all groups (points → GD → GF → team
  name) and marks the top eight as qualifying. It does NOT assign thirds to specific R32
  slots — that needs FIFA's 495-row table (see the spike); the page shows this ranked panel
  beside the bracket instead, and exact slot teams arrive via the openfootball ingest.
  """

  @qualify_count 8

  @doc "Rank the 3rd-placed teams across groups; mark the top 8 qualifying."
  def ranked(group_tables) do
    entries =
      group_tables
      |> Enum.map(fn {_group, rows} -> Enum.at(rows, 2) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(fn r -> {-r.points, -r.gd, -r.gf, r.team} end)
      |> Enum.with_index(1)
      |> Enum.map(fn {row, pos} -> %{position: pos, qualifying?: pos <= @qualify_count, row: row} end)

    %{entries: entries, cutoff_provisional?: cutoff_tie?(entries)}
  end

  defp cutoff_tie?(entries) do
    case {Enum.at(entries, @qualify_count - 1), Enum.at(entries, @qualify_count)} do
      {%{row: a}, %{row: b}} -> {a.points, a.gd, a.gf} == {b.points, b.gd, b.gf}
      _ -> false
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/predictex/bracket/thirds_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/bracket/thirds.ex test/predictex/bracket/thirds_test.exs
git commit -m "feat(bracket): pure best-8-of-12 thirds ranking (predictex-7qu)"
```

---

### Task 4: `Predictex.Bracket.resolve_slot/2` — total placeholder parser

**Files:**
- Create: `lib/predictex/bracket.ex` (parser only this task; `build/2` + `view/0` in Task 5)
- Test: `test/predictex/bracket_test.exs`

**Interfaces:**
- Consumes: a placeholder string + `%{group_letter => [Row.t()]}`.
- Produces: `Bracket.resolve_slot(placeholder, group_tables) :: slot` where
  `slot :: {:exact, team} | {:candidate_set, [group_letter]} | {:resolved, team} | {:tbd, label}`.
  Total — every input maps cleanly, never raises.

- [ ] **Step 1: Write the failing test**

Create `test/predictex/bracket_test.exs`:

```elixir
defmodule Predictex.BracketTest do
  use ExUnit.Case, async: true

  alias Predictex.Bracket
  alias Predictex.GroupTables.Row

  defp tables do
    %{
      "C" => [
        %Row{team: "Croatia", group: "C", rank: 1},
        %Row{team: "Belgium", group: "C", rank: 2},
        %Row{team: "Morocco", group: "C", rank: 3}
      ]
    }
  end

  test "resolves a group-winner placeholder to the rank-1 team" do
    assert Bracket.resolve_slot("1C", tables()) == {:exact, "Croatia"}
  end

  test "resolves a runner-up placeholder to the rank-2 team" do
    assert Bracket.resolve_slot("2C", tables()) == {:exact, "Belgium"}
  end

  test "returns a candidate set for a third-placed placeholder" do
    assert Bracket.resolve_slot("3A/B/C/D/F", tables()) == {:candidate_set, ~w(A B C D F)}
  end

  test "passes an already-resolved real team name through as :resolved" do
    assert Bracket.resolve_slot("Germany", tables()) == {:resolved, "Germany"}
  end

  test "labels a winner/runner-up slot whose group has no ranked team yet as :tbd" do
    assert Bracket.resolve_slot("1Z", tables()) == {:tbd, "Winner Z"}
    assert Bracket.resolve_slot("2Z", tables()) == {:tbd, "Runners-up Z"}
  end

  test "is total — a later-round W/L marker and garbage never raise" do
    assert Bracket.resolve_slot("W74", tables()) == {:tbd, "W74"}
    assert match?({:resolved, _}, Bracket.resolve_slot("", tables()))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex/bracket_test.exs`
Expected: FAIL — `Predictex.Bracket.resolve_slot/2 is undefined`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/predictex/bracket.ex`:

```elixir
defmodule Predictex.Bracket do
  @moduledoc """
  Pure projection of the Round of 32 "as it stands" (`predictex-7qu`).

  `resolve_slot/2` is a TOTAL anti-corruption parser: every R32 placeholder the data carries
  (`"1C"` winner / `"2F"` runner-up / `"3A/B/C/D/F"` third-placed candidate set / an
  already-resolved real team name / anything unexpected) maps to a renderable value and never
  raises. Third-placed slots stay candidate sets — exact thirds arrive upstream via the
  openfootball/`Workers.KnockoutIds` ingest as `{:resolved, name}` (see the spike).
  """

  alias Predictex.Bracket.Thirds
  alias Predictex.{GroupTables, Tournament}

  @winner_runner_up ~r/^([12])([A-L])$/
  @third ~r{^3([A-L])(?:/([A-L]))+$}
  @later_round ~r/^[WL]\d+$/

  @doc "Resolve one R32 slot placeholder into a renderable value. Total."
  def resolve_slot(placeholder, group_tables) when is_binary(placeholder) do
    cond do
      caps = Regex.run(@winner_runner_up, placeholder) ->
        [_, pos, group] = caps
        resolve_position(group_tables, group, String.to_integer(pos))

      Regex.match?(@third, placeholder) ->
        groups = placeholder |> String.trim_leading("3") |> String.split("/")
        {:candidate_set, groups}

      Regex.match?(@later_round, placeholder) ->
        {:tbd, placeholder}

      true ->
        {:resolved, placeholder}
    end
  end

  defp resolve_position(group_tables, group, position) do
    case group_tables |> Map.get(group, []) |> Enum.at(position - 1) do
      %{team: team} -> {:exact, team}
      nil -> {:tbd, position_label(position, group)}
    end
  end

  defp position_label(1, group), do: "Winner #{group}"
  defp position_label(2, group), do: "Runners-up #{group}"
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/predictex/bracket_test.exs`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/bracket.ex test/predictex/bracket_test.exs
git commit -m "feat(bracket): total R32 slot placeholder parser (predictex-7qu)"
```

---

### Task 5: `Bracket.build/2` + `Bracket.view/0` Gather edge

**Files:**
- Modify: `lib/predictex/bracket.ex`
- Test: `test/predictex/bracket_test.exs` (add a `build/2` describe) and a DB test for `view/0`

**Interfaces:**
- Consumes: `Tournament.group_stage_fixtures/0`, `Tournament.r32_fixtures/0`, `GroupTables.build/1`, `Thirds.ranked/1`, `resolve_slot/2`.
- Produces: `Bracket.build(group_fixtures, r32_fixtures) :: %{matches: [match], group_tables: tables, thirds: thirds}` where `match :: %{source_num, kickoff_at, home: slot, away: slot}`. `Bracket.view() :: same` — the DB Gather edge.

- [ ] **Step 1: Write the failing test**

Add to `test/predictex/bracket_test.exs` (new describe at the end of the module, before the final `end`):

```elixir
  describe "build/2" do
    test "assembles R32 matches, group tables and the thirds panel" do
      group_fixtures = [
        %{group: "C", team1: "Croatia", team2: "Belgium", home_goals: 2, away_goals: 0, status: :completed},
        %{group: "F", team1: "Brazil", team2: "Serbia", home_goals: 1, away_goals: 0, status: :completed}
      ]

      r32_fixtures = [
        %{source_num: 76, kickoff_at: nil, team1: "1C", team2: "3A/B/C/D/F"},
        %{source_num: 77, kickoff_at: nil, team1: "Germany", team2: "2F"}
      ]

      %{matches: matches, group_tables: tables, thirds: thirds} =
        Predictex.Bracket.build(group_fixtures, r32_fixtures)

      assert [m76, m77] = matches
      assert m76.home == {:exact, "Croatia"}
      assert m76.away == {:candidate_set, ~w(A B C D F)}
      assert m77.home == {:resolved, "Germany"}
      assert m77.away == {:exact, "Serbia"}
      assert Map.has_key?(tables, "C")
      assert %{entries: _, cutoff_provisional?: _} = thirds
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex/bracket_test.exs`
Expected: FAIL — `Predictex.Bracket.build/2 is undefined`.

- [ ] **Step 3: Write minimal implementation**

Add to `lib/predictex/bracket.ex` (after `resolve_slot/2`, before the private helpers):

```elixir
  @doc "Pure projection: build the bracket view model from group + R32 fixtures."
  def build(group_fixtures, r32_fixtures) do
    tables = GroupTables.build(group_fixtures)

    matches =
      Enum.map(r32_fixtures, fn fx ->
        %{
          source_num: fx.source_num,
          kickoff_at: fx.kickoff_at,
          home: resolve_slot(fx.team1, tables),
          away: resolve_slot(fx.team2, tables)
        }
      end)

    %{matches: matches, group_tables: tables, thirds: Thirds.ranked(tables)}
  end

  @doc "Gather edge: load the fixtures and build the projection."
  def view do
    build(Tournament.group_stage_fixtures(), Tournament.r32_fixtures())
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mise exec -- mix test test/predictex/bracket_test.exs`
Expected: PASS.

- [ ] **Step 5: Write the failing DB test for `view/0`**

Create `test/predictex/bracket_view_test.exs`:

```elixir
defmodule Predictex.BracketViewTest do
  use Predictex.DataCase, async: true

  alias Predictex.{Bracket, Tournament}

  defp fixture!(round, attrs) do
    base = %{external_ref: "ref-#{System.unique_integer([:positive])}", status: :scheduled, round_id: round.id}
    {:ok, f} = Tournament.create_fixture(Map.merge(base, attrs))
    f
  end

  test "view/0 reads the live fixtures and projects the R32" do
    {:ok, g1} = Tournament.create_round(%{name: "Matchday 1", stage: :group, ordinal: 1})
    {:ok, r32} = Tournament.create_round(%{name: "Round of 32", stage: :knockout, ordinal: 4})

    fixture!(g1, %{group: "C", team1: "Croatia", team2: "Belgium", home_goals: 2, away_goals: 0, status: :completed})
    fixture!(r32, %{team1: "1C", team2: "2C", source_num: 73})

    %{matches: [match], group_tables: tables} = Bracket.view()

    assert match.home == {:exact, "Croatia"}
    assert match.away == {:exact, "Belgium"}
    assert Map.has_key?(tables, "C")
  end
end
```

- [ ] **Step 6: Run it (fails), implement is already done, run again (passes)**

Run: `mise exec -- mix test test/predictex/bracket_view_test.exs`
Expected: PASS (the implementation from Step 3 already provides `view/0`).

- [ ] **Step 7: Commit**

```bash
git add lib/predictex/bracket.ex test/predictex/bracket_test.exs test/predictex/bracket_view_test.exs
git commit -m "feat(bracket): build/2 projection + view/0 gather edge (predictex-7qu)"
```

---

### Task 6: `BracketLive` public page + route + nav + live update

**Files:**
- Create: `lib/predictex_web/live/bracket_live.ex`
- Modify: `lib/predictex_web/router.ex` (the `:public` live_session)
- Modify: `lib/predictex_web/components/layouts/root.html.heex` (nav link)
- Test: `test/predictex_web/live/bracket_live_test.exs`

**Interfaces:**
- Consumes: `Bracket.view/0`, `Tournament.subscribe_changes/0`, `PredictexWeb.Flags.flag/1`.
- Produces: the `/bracket` route.

- [ ] **Step 1: Write the failing test**

Create `test/predictex_web/live/bracket_live_test.exs`:

```elixir
defmodule PredictexWeb.BracketLiveTest do
  use PredictexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  alias Predictex.Tournament

  defp fixture!(round, attrs) do
    base = %{external_ref: "ref-#{System.unique_integer([:positive])}", status: :scheduled, round_id: round.id}
    {:ok, f} = Tournament.create_fixture(Map.merge(base, attrs))
    f
  end

  setup do
    # Rounds ascending by ordinal (DataCase deadlock invariant).
    {:ok, g1} = Tournament.create_round(%{name: "Matchday 1", stage: :group, ordinal: 1})
    {:ok, r32} = Tournament.create_round(%{name: "Round of 32", stage: :knockout, ordinal: 4})
    %{g1: g1, r32: r32}
  end

  test "is public — renders without logging in", %{conn: conn, g1: g1, r32: r32} do
    fixture!(g1, %{group: "C", team1: "Croatia", team2: "Belgium", home_goals: 2, away_goals: 0, status: :completed})
    fixture!(r32, %{team1: "1C", team2: "3A/B/C/D/F", source_num: 73})

    {:ok, _lv, html} = live(conn, ~p"/bracket")

    assert html =~ "As it stands"
    assert html =~ "Croatia"
    # Third-placed slot shows the candidate set, not a guessed team.
    assert html =~ "A/B/C/D/F"
    # Group table is present.
    assert html =~ "Belgium"
  end

  test "re-pulls on a fixtures_changed broadcast", %{conn: conn, g1: g1, r32: r32} do
    pred = fixture!(g1, %{group: "C", team1: "Croatia", team2: "Belgium", kickoff_at: nil, status: :scheduled})
    fixture!(r32, %{team1: "1C", team2: "2C", source_num: 73})

    {:ok, lv, _html} = live(conn, ~p"/bracket")

    # Settle the group fixture, then broadcast the same signal the settle path emits.
    pred
    |> Ecto.Changeset.change(%{status: :completed, home_goals: 3, away_goals: 0})
    |> Predictex.Repo.update!()

    Tournament.broadcast_change()

    html = render(lv)
    # Croatia is now the group winner → fills the 1C slot.
    assert html =~ "Croatia"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex_web/live/bracket_live_test.exs`
Expected: FAIL — no route `/bracket` (`** (ArgumentError) ... no route`).

- [ ] **Step 3: Add the route**

In `lib/predictex_web/router.ex`, inside the existing `:public` `live_session` (around lines 63–66), add the bracket route beside the leaderboard:

```elixir
    live_session :public,
      on_mount: [{PredictexWeb.PlayerAuth, :mount_current_scope}] do
      live "/", LeaderboardLive, :index
      live "/bracket", BracketLive, :index
    end
```

- [ ] **Step 4: Create the LiveView**

Create `lib/predictex_web/live/bracket_live.ex`:

```elixir
defmodule PredictexWeb.BracketLive do
  @moduledoc """
  Public "as it stands" projected Round of 32 (`predictex-7qu`): live group tables (A–L) and
  the R32 matchups they imply, computed from actual results. Winner/runner-up slots resolve
  to exact teams; third-placed slots show their candidate set + a ranked best-thirds panel,
  and become exact named teams automatically once the group stage ends (via the ingest).
  Re-pulls on the coarse `:fixtures_changed` PubSub signal.
  """
  use PredictexWeb, :live_view

  alias Predictex.{Bracket, Tournament}
  alias PredictexWeb.Flags

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Tournament.subscribe_changes()

    {:ok,
     socket
     |> assign(:page_title, "Bracket")
     |> assign_view()}
  end

  @impl true
  def handle_info(:fixtures_changed, socket), do: {:noreply, assign_view(socket)}

  defp assign_view(socket) do
    view = Bracket.view()

    socket
    |> assign(:matches, view.matches)
    |> assign(:group_tables, view.group_tables)
    |> assign(:thirds, view.thirds)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} max_width="max-w-6xl">
      <div class="space-y-6">
        <h1 class="text-2xl font-bold">As it stands · Round of 32</h1>

        <div :if={@matches == []} class="rounded-box bg-base-200 p-6 text-center">
          <p class="font-medium">No knockout bracket yet</p>
          <p class="text-sm opacity-70">The projected R32 appears once fixtures are seeded.</p>
        </div>

        <section :if={@matches != []} class="grid grid-cols-1 gap-2 sm:grid-cols-2">
          <div :for={m <- @matches} class="flex items-center justify-between rounded-box bg-base-200 p-3">
            <span class="font-medium">{slot_label(m.home)}</span>
            <span class="px-2 text-sm opacity-60">v</span>
            <span class="font-medium">{slot_label(m.away)}</span>
          </div>
        </section>

        <section :if={@thirds.entries != []} class="rounded-box border border-base-300 p-4">
          <h2 class="mb-2 font-semibold">Best thirds so far — top 8 of 12 qualify</h2>
          <ol class="space-y-1 text-sm">
            <li
              :for={e <- @thirds.entries}
              class={["flex justify-between", not e.qualifying? && "opacity-50"]}
            >
              <span>
                {e.position}. {Flags.flag(e.row.team)} {e.row.team}
                <span class="opacity-60">(Group {e.row.group})</span>
              </span>
              <span class="font-mono">
                {e.row.points} pts · {format_gd(e.row.gd)}{if e.position == 8 and @thirds.cutoff_provisional?,
                  do: " ⚠ level with 9th"}
              </span>
            </li>
          </ol>
        </section>

        <section :if={@group_tables != %{}} class="grid grid-cols-1 gap-4 md:grid-cols-2 lg:grid-cols-3">
          <div :for={{group, rows} <- Enum.sort_by(@group_tables, &elem(&1, 0))} class="rounded-box border border-base-300 p-3">
            <h3 class="mb-2 font-semibold">Group {group}</h3>
            <table class="w-full text-sm">
              <tbody>
                <tr :for={r <- rows} class={[r.rank <= 2 && "font-semibold"]}>
                  <td class="py-0.5">{Flags.flag(r.team)} {r.team}{if r.rank == 3, do: " ▲"}</td>
                  <td class="py-0.5 text-right font-mono opacity-70">{r.played}</td>
                  <td class="py-0.5 text-right font-mono">{format_gd(r.gd)}</td>
                  <td class="py-0.5 text-right font-mono font-semibold">{r.points}{if r.provisional_tie?, do: "*"}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp slot_label({:exact, team}), do: "#{Flags.flag(team)} #{team}"
  defp slot_label({:resolved, team}), do: "#{Flags.flag(team)} #{team}"
  defp slot_label({:candidate_set, groups}), do: "3rd · #{Enum.join(groups, "/")}"
  defp slot_label({:tbd, label}), do: label

  defp format_gd(gd) when gd > 0, do: "+#{gd}"
  defp format_gd(gd), do: "#{gd}"
end
```

- [ ] **Step 5: Add the nav link**

In `lib/predictex_web/components/layouts/root.html.heex`, after the Leaderboard link (line ~57), add:

```heex
        <.link href={~p"/bracket"} class="btn btn-ghost btn-sm">Bracket</.link>
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mise exec -- mix test test/predictex_web/live/bracket_live_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 7: Run the full gate**

Run: `mise exec -- mix precommit`
Expected: compile (no warnings), format, credo, and the full suite all green.

- [ ] **Step 8: Commit**

```bash
git add lib/predictex_web/live/bracket_live.ex lib/predictex_web/router.ex \
        lib/predictex_web/components/layouts/root.html.heex \
        test/predictex_web/live/bracket_live_test.exs
git commit -m "feat(bracket): public /bracket as-it-stands R32 page + nav + live update (predictex-7qu)"
```

---

## Self-Review

**Spec coverage:**
- Public `/bracket`, no auth → Task 6 (route in `:public` session, public mount test). ✓
- Group tables A–L, Pts/GD/GF tiebreakers, provisional-tie flag → Task 2. ✓
- Best-8-of-12 thirds + cutoff tie → Task 3. ✓
- Total placeholder parser; candidate-set thirds; `{:resolved, name}` 28-Jun path → Task 4. ✓
- R32-only, R32 = lowest-ordinal knockout round → Task 1 (`r32_fixtures/0`). ✓
- Live-update via `:fixtures_changed` → Task 6 (subscribe + handle_info + test). ✓
- No migration, no new deps → confirmed (Ecto queries only). ✓
- Flags for team names → Task 6 (`Flags.flag/1`). ✓

**Placeholder scan:** No "TBD/TODO/handle edge cases" — every step has complete code. ✓

**Type consistency:** `GroupTables.build/1` returns `%{group => [Row]}`, consumed by `Thirds.ranked/1` and `Bracket.resolve_slot/2`/`build/2`. `Thirds.ranked/1` returns `%{entries:, cutoff_provisional?:}`, consumed by the LiveView render. `resolve_slot/2` returns the four-variant `slot` tuple, matched by `slot_label/1`. `build/2` returns `%{matches:, group_tables:, thirds:}`, assigned in `assign_view/1`. Consistent across tasks. ✓

## Notes for the implementer

- The pure modules (`GroupTables`, `Bracket.Thirds`, `Bracket` parser/`build`) take **fixture-like maps or `%Fixture{}` structs interchangeably** (dot access on the same keys) — tests use plain maps; `view/0` passes real `%Fixture{}`. Keep it that way; do not couple the pure cores to Ecto.
- `provisional_tie?`'s `*` and the thirds `⚠` are deliberately understated; styling can be refined later (`predictex-aqf`-style polish), but the data is correct now.
- After this lands, exact named thirds appear automatically when the group stage ends and openfootball/`Workers.KnockoutIds` resolve the real R32 teams (the `{:resolved, name}` branch) — no further work for that.
