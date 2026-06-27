# e5o v2 — both-placeholder R32 resolution — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fill **both** sides of a both-placeholder R32 fixture that FIFA has resolved (e.g. `Winner I` v `3rd·C/D/F/G/H` → France v Sweden), by resolving the winner/runner-up placeholder against our own group standings as a *validating anchor* — no blind positional guess.

**Architecture:** A both-placeholder fixture is one winner/runner-up slot (`1X`/`2X`) paired with a third (`3…`) or another `1X`/`2X`. Resolve the `1X`/`2X` side against the pure `GroupTables` standings; if the projected team matches one FIFA name (after `Crosswalk.norm/1`), that single check both validates the slot match and fixes orientation. Fill both sides from FIFA's canonical names; skip if nothing projects, the projection matches neither FIFA name, or either FIFA name isn't canonical.

**Tech Stack:** Elixir 1.20 / OTP 28, Ecto/Postgres, Oban. No new deps. **No migration.**

## Global Constraints

- Run mix via mise: **`mise exec -- mix …`** (plain `mix` is the wrong version).
- The gate is **`mix precommit`** (compile --warnings-as-errors, deps.unlock --check-unused, format --check-formatted, credo --strict, test), run on every Elixir-staging commit via lefthook. Never `--no-verify`.
- TDD: failing test first, run-to-fail, implement, run-to-pass, commit.
- New ConnCase/DataCase tests creating multiple rounds insert them **ascending by `:ordinal`** (deadlock invariant).
- **No blind positional fill** — orientation always comes from a projection-validated anchor (the advisor rejected positional-trust in v1). Never write a team into a fixture from our standings alone; the standings only *validate + orient*; the names written are always FIFA's (authoritative).
- **All-or-nothing** for a both-placeholder fixture: fill both sides or neither (a half-fill leaves it `:pending`).
- Writes go through `Tournament.update_fixture/2` (only `team1`/`team2`); the `predictex-ahi` Ingest no-downgrade guard keeps the fill from being reverted by a later openfootball placeholder sync.
- All new code covered by tests; pristine output.

## Reused interfaces (already in the codebase — do not re-implement)

- `Predictex.GroupTables.build(fixtures) :: %{group => [%Predictex.GroupTables.Row{}]}` — ranked standings (rank 1 first); each `Row` has `:team` (binary) and `:provisional_tie?` (boolean). Self-filters to fixtures with a `:group`; KO fixtures (`group: nil`) are ignored.
- `Predictex.Knockout.resolved_team?(name) :: boolean`; module attrs `@winner_runner_up ~r/^[12][A-Z]$/`, `@third ~r{^3[A-Z](?:/[A-Z])+$}`, `@later_round ~r/^[WL]\d+$/`.
- `Predictex.Fifa.Crosswalk.norm(name) :: String.t()` — lowercase + whitespace + FIFA→openfootball alias; `norm(nil) == ""`.
- `Predictex.Fifa.KnockoutTeams` — `plan/3`, `assign/1`, `canonical_index/1`, and private `fill_for/4`, `anchored/6`, `canonical/2`, `maybe_put/3` (v1).

## File Structure

| File | Responsibility |
|------|----------------|
| `lib/predictex/knockout.ex` (modify) | NEW `parse_slot/1` — classify a placeholder (`{:winner,g}`/`{:runner_up,g}`/`{:third,[g]}`/`{:later,name}`/`{:resolved,name}`). The single placeholder-grammar classifier. |
| `lib/predictex/fifa/knockout_teams.ex` (modify) | `plan/4` (group_tables, defaulted); both-placeholder branch (`both_placeholder`/`orient_both`/`project_slot`/`team_at`); `assign/1` builds + passes group tables. |
| Test files | `test/predictex/knockout_test.exs`, `test/predictex/fifa/knockout_teams_test.exs`, `test/predictex/fifa/knockout_teams_assign_test.exs`, `test/predictex/results/ingest_test.exs` (ahi both-placeholder regression), `test/predictex_web/live/my_predictions_live_test.exs` (flip). |

---

### Task 1: `Predictex.Knockout.parse_slot/1`

**Files:**
- Modify: `lib/predictex/knockout.ex`
- Test: `test/predictex/knockout_test.exs`

**Interfaces:**
- Produces: `Knockout.parse_slot(name) :: {:winner, group} | {:runner_up, group} | {:third, [group]} | {:later, name} | {:resolved, name}` — `group` a single-letter binary, `[group]` a list of them. Total. Consistent with `resolved_team?/1` (a `{:resolved, _}` iff `resolved_team?` is true).

- [ ] **Step 1: Write the failing test**

Add to `test/predictex/knockout_test.exs` (a new `describe`, before the final `end`):

```elixir
  describe "parse_slot/1 (predictex-dum)" do
    test "classifies each placeholder form" do
      assert Knockout.parse_slot("1A") == {:winner, "A"}
      assert Knockout.parse_slot("2B") == {:runner_up, "B"}
      assert Knockout.parse_slot("3A/B/C/D/F") == {:third, ["A", "B", "C", "D", "F"]}
      assert Knockout.parse_slot("W89") == {:later, "W89"}
      assert Knockout.parse_slot("L101") == {:later, "L101"}
    end

    test "a real team name is {:resolved, name}" do
      assert Knockout.parse_slot("Brazil") == {:resolved, "Brazil"}
      assert Knockout.parse_slot("Côte d'Ivoire") == {:resolved, "Côte d'Ivoire"}
    end

    test "is total and agrees with resolved_team?/1" do
      for s <- ["1A", "2B", "3A/B/C/D/F", "W89", "Brazil", ""] do
        assert match?({:resolved, _}, Knockout.parse_slot(s)) == Knockout.resolved_team?(s)
      end

      assert Knockout.parse_slot(nil) == {:resolved, ""}
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex/knockout_test.exs`
Expected: FAIL — `Predictex.Knockout.parse_slot/1 is undefined`.

- [ ] **Step 3: Write minimal implementation**

In `lib/predictex/knockout.ex`, add after `slot_label/1` (reusing the existing module attrs, extracting via binary match — no new regexes):

```elixir
  @doc """
  Classify a fixture-slot string into its bracket-grammar token (predictex-dum). Single source of
  the placeholder classification, consistent with `resolved_team?/1` (`{:resolved, _}` iff resolved).

    * `"1A"` → `{:winner, "A"}`           — group winner slot
    * `"2B"` → `{:runner_up, "B"}`        — group runner-up slot
    * `"3A/B/C/D/F"` → `{:third, ["A","B","C","D","F"]}` — third-placed candidate set
    * `"W89"`/`"L101"` → `{:later, name}` — later-round winner/loser-of slot
    * a real team name → `{:resolved, name}`

  Total.
  """
  def parse_slot(name) when is_binary(name) do
    cond do
      Regex.match?(@winner_runner_up, name) ->
        <<pos::binary-1, group::binary>> = name
        if pos == "1", do: {:winner, group}, else: {:runner_up, group}

      Regex.match?(@third, name) ->
        {:third, name |> String.slice(1..-1//1) |> String.split("/")}

      Regex.match?(@later_round, name) ->
        {:later, name}

      true ->
        {:resolved, name}
    end
  end

  def parse_slot(_), do: {:resolved, ""}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/predictex/knockout_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/knockout.ex test/predictex/knockout_test.exs
git commit -m "feat(knockout): parse_slot/1 placeholder classifier (predictex-dum)"
```

---

### Task 2: `KnockoutTeams.plan/4` both-placeholder fill + `assign/1` group tables

**Files:**
- Modify: `lib/predictex/fifa/knockout_teams.ex`
- Test: `test/predictex/fifa/knockout_teams_test.exs` (pure plan cases), `test/predictex/fifa/knockout_teams_assign_test.exs` (assign integration)

**Interfaces:**
- Consumes: `Knockout.parse_slot/1` (Task 1), `GroupTables.build/1`, `Crosswalk.norm/1`.
- Produces: `plan(rounds, fixtures, canonical_index, group_tables \\ %{})` — a defaulted 4th arg; the both-placeholder branch fills both sides when a `1X`/`2X` side projects (via `group_tables`) to a real team matching one FIFA name. `assign/1` unchanged in signature; it now builds `group_tables` from group-stage fixtures and passes them.

- [ ] **Step 1: Write the failing pure tests**

The Task-1 file `test/predictex/fifa/knockout_teams_test.exs` already has a module-level `@canon` and a `rounds/3` helper (and `alias Predictex.Tournament.Fixture`).

**⚠️ MODULE-LEVEL, not inside `describe`:** a module attribute (`@tables`) and the `GroupTables` alias must live at the TOP of the test module (alongside the existing `@canon`/aliases), NOT inside the `describe` block — module attributes evaluate at compile time and an alias scoped inside `describe` won't be in scope, which fails to compile. Add these two lines near the top of the module:

```elixir
  alias Predictex.GroupTables

  # Group I result → France is rank 1 (winner of I), Spain rank 2.
  @tables GroupTables.build([
            %Fixture{team1: "France", team2: "Spain", group: "I", status: :completed, home_goals: 1, away_goals: 0}
          ])
```

Then add the `describe` block (it references the module-level `@tables`):

```elixir
  describe "plan/4 — both-placeholder (projection-validated orientation, predictex-dum)" do
    test "fills BOTH sides when the winner slot projects to a team matching a FIFA name" do
      ko = ~U[2026-07-02 01:00:00Z]
      # Our fixture: team1 = winner of I (placeholder), team2 = a third (placeholder).
      f = %Fixture{id: 20, team1: "1I", team2: "3C/D/F/G/H", kickoff_at: ko}
      r = rounds("2026-07-02T01:00:00+00:00", "France", "Sweden")
      canon = KnockoutTeams.canonical_index(["France", "Sweden", "Spain"])

      assert [%{fixture_id: 20, team1: "France", team2: "Sweden"}] =
               KnockoutTeams.plan(r, [f], canon, @tables)
    end

    test "re-orients when FIFA lists the pair swapped (team1 still gets the winner)" do
      ko = ~U[2026-07-02 01:00:00Z]
      f = %Fixture{id: 21, team1: "1I", team2: "3C/D/F/G/H", kickoff_at: ko}
      # FIFA lists Sweden home, France away — our team1 (1I→France) must still become France.
      r = rounds("2026-07-02T01:00:00+00:00", "Sweden", "France")
      canon = KnockoutTeams.canonical_index(["France", "Sweden"])

      assert [%{fixture_id: 21, team1: "France", team2: "Sweden"}] =
               KnockoutTeams.plan(r, [f], canon, @tables)
    end

    test "skips when no side projects (group not decided → empty tables)" do
      ko = ~U[2026-07-02 01:00:00Z]
      f = %Fixture{id: 22, team1: "1Z", team2: "3C/D/F/G/H", kickoff_at: ko}
      r = rounds("2026-07-02T01:00:00+00:00", "France", "Sweden")
      canon = KnockoutTeams.canonical_index(["France", "Sweden"])

      assert KnockoutTeams.plan(r, [f], canon, @tables) == []
    end

    test "skips when the projected anchor matches neither FIFA name (spurious slot / disagreement)" do
      ko = ~U[2026-07-02 01:00:00Z]
      f = %Fixture{id: 23, team1: "1I", team2: "3C/D/F/G/H", kickoff_at: ko}
      # 1I projects to France, but FIFA's entry is a different pair → skip.
      r = rounds("2026-07-02T01:00:00+00:00", "Brazil", "Japan")
      canon = KnockoutTeams.canonical_index(["France", "Brazil", "Japan"])

      assert KnockoutTeams.plan(r, [f], canon, @tables) == []
    end

    test "all-or-nothing: skips when one FIFA name is not a known canonical team" do
      ko = ~U[2026-07-02 01:00:00Z]
      f = %Fixture{id: 24, team1: "1I", team2: "3C/D/F/G/H", kickoff_at: ko}
      r = rounds("2026-07-02T01:00:00+00:00", "France", "Atlantis")
      canon = KnockoutTeams.canonical_index(["France"])

      assert KnockoutTeams.plan(r, [f], canon, @tables) == []
    end

    test "does not anchor on a provisional-tie position" do
      # Group J: two teams level on points/GD/GF → rank-1 row is provisional_tie? → no anchor.
      tied =
        GroupTables.build([
          %Fixture{
            team1: "Argentina",
            team2: "Mexico",
            group: "J",
            status: :completed,
            home_goals: 1,
            away_goals: 1
          }
        ])

      ko = ~U[2026-07-02 01:00:00Z]
      f = %Fixture{id: 25, team1: "1J", team2: "3C/D/F/G/H", kickoff_at: ko}
      r = rounds("2026-07-02T01:00:00+00:00", "Argentina", "Sweden")
      canon = KnockoutTeams.canonical_index(["Argentina", "Sweden"])

      assert KnockoutTeams.plan(r, [f], canon, tied) == []
    end
  end
```

Also add to `test/predictex/fifa/knockout_teams_assign_test.exs` an integration test (DB) where `assign/1` fills a both-placeholder fixture end-to-end:

```elixir
  test "assign/1 fills a both-placeholder fixture via the group-standings anchor" do
    # Group I result seeds the canonical index AND the standings (France = winner of I).
    {:ok, grp} = Tournament.create_round(%{name: "Group I", stage: :group, ordinal: 1})

    {:ok, _} =
      Tournament.create_fixture(%{
        external_ref: "2026-06-20 France v Spain",
        team1: "France",
        team2: "Spain",
        group: "I",
        status: :completed,
        home_goals: 2,
        away_goals: 0,
        kickoff_at: ~U[2026-06-20 19:00:00Z],
        round_id: grp.id
      })

    # Seed Sweden as a canonical name too (a completed group fixture in another group).
    {:ok, _} =
      Tournament.create_fixture(%{
        external_ref: "2026-06-20 Sweden v Qatar",
        team1: "Sweden",
        team2: "Qatar",
        group: "C",
        status: :completed,
        home_goals: 1,
        away_goals: 0,
        kickoff_at: ~U[2026-06-20 16:00:00Z],
        round_id: grp.id
      })

    {:ok, ko} = Tournament.create_round(%{name: "Round of 32", stage: :knockout, ordinal: 4})
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    {:ok, fx} = Tournament.create_fixture(%{external_ref: "ko-bothph", team1: "1I", team2: "3C/D/F/G/H", kickoff_at: future, round_id: ko.id})
    iso = DateTime.to_iso8601(future)

    rounds = [%{"stage" => "r32", "tournaments" => [%{"date" => iso, "homeSquadName" => "France", "awaySquadName" => "Sweden"}]}]

    assert %{resolved: 1} = KnockoutTeams.assign(rounds)
    reloaded = Tournament.get_fixture!(fx.id)
    assert reloaded.team1 == "France" and reloaded.team2 == "Sweden"
  end
```

> Confirm the real fixture constructor (`Tournament.create_fixture/1` flat-attrs vs a `fixture!/2` helper) and the fixture getter (`Tournament.get_fixture!/1` may be named differently) by reading `lib/predictex/tournament.ex` and the existing assign-test helpers; mirror them. The assertion semantics (both sides become France/Sweden) are what matter.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mise exec -- mix test test/predictex/fifa/knockout_teams_test.exs test/predictex/fifa/knockout_teams_assign_test.exs`
Expected: FAIL — `plan/4` undefined / both-placeholder returns `[]` (v1 skips it).

- [ ] **Step 3: Implement `plan/4` + the both-placeholder branch**

In `lib/predictex/fifa/knockout_teams.ex`: add `alias Predictex.GroupTables` to the alias line (`alias Predictex.{GroupTables, Knockout, Repo, Tournament}`). Change `plan/3` to `plan/4` with a defaulted arg and thread `group_tables` into `fill_for`:

```elixir
  def plan(rounds, fixtures, canonical_index, group_tables \\ %{}) do
    slot_idx =
      for r <- rounds, r["stage"] in @ko_stages, t <- r["tournaments"] || [], into: %{} do
        {Crosswalk.slot_key(t["date"]), {t["homeSquadName"], t["awaySquadName"]}}
      end

    for f <- fixtures,
        not (Knockout.resolved_team?(f.team1) and Knockout.resolved_team?(f.team2)),
        {home, away} = Map.get(slot_idx, Crosswalk.slot_key(f.kickoff_at), {nil, nil}),
        fill = fill_for(f, home, away, canonical_index, group_tables),
        map_size(fill) > 0 do
      Map.put(fill, :fixture_id, f.id)
    end
  end
```

Replace `fill_for/4` with `fill_for/5` (the new `group_tables` arg) and the both-placeholder branch:

```elixir
  defp fill_for(f, home, away, idx, group_tables) do
    t1_ph = not Knockout.resolved_team?(f.team1)
    t2_ph = not Knockout.resolved_team?(f.team2)
    c_home = canonical(idx, home)
    c_away = canonical(idx, away)

    cond do
      t1_ph and t2_ph -> both_placeholder(f, home, away, c_home, c_away, group_tables)
      t1_ph -> anchored(f.team2, :team1, home, away, c_home, c_away)
      t2_ph -> anchored(f.team1, :team2, home, away, c_home, c_away)
      true -> %{}
    end
  end

  # Both sides are bracket placeholders. Resolve a winner/runner-up side against our group
  # standings as a validating anchor (predictex-dum): if the projected team matches one FIFA name,
  # that fixes orientation. Fill BOTH sides from the canonical FIFA names, or nothing.
  defp both_placeholder(f, fifa_home, fifa_away, c_home, c_away, tables) do
    {for_t1, for_t2} = orient_both(f.team1, f.team2, fifa_home, fifa_away, c_home, c_away, tables)

    if is_nil(for_t1) or is_nil(for_t2) do
      %{}
    else
      %{team1: for_t1, team2: for_t2}
    end
  end

  # Returns {canonical_for_team1, canonical_for_team2}; {nil, nil} when neither side's projection
  # matches a FIFA name (no validated orientation → skip).
  defp orient_both(slot1, slot2, fifa_home, fifa_away, c_home, c_away, tables) do
    cond do
      anchor_matches?(slot1, fifa_home, tables) -> {c_home, c_away}
      anchor_matches?(slot1, fifa_away, tables) -> {c_away, c_home}
      anchor_matches?(slot2, fifa_home, tables) -> {c_away, c_home}
      anchor_matches?(slot2, fifa_away, tables) -> {c_home, c_away}
      true -> {nil, nil}
    end
  end

  defp anchor_matches?(slot, fifa_name, tables) do
    case project_slot(slot, tables) do
      nil -> false
      team -> Crosswalk.norm(team) == Crosswalk.norm(fifa_name)
    end
  end

  # A 1X/2X slot → the real team at that group position in our standings, or nil if the group
  # isn't represented, the position is empty, or the row is a provisional tie (don't anchor on a
  # coin-flip leader). Third/later/resolved slots are not group-position anchors.
  defp project_slot(slot, tables) do
    case Knockout.parse_slot(slot) do
      {:winner, group} -> team_at(tables, group, 1)
      {:runner_up, group} -> team_at(tables, group, 2)
      _ -> nil
    end
  end

  defp team_at(tables, group, rank) do
    case tables |> Map.get(group, []) |> Enum.at(rank - 1) do
      %{team: team, provisional_tie?: false} -> team
      _ -> nil
    end
  end
```

(Keep `anchored/6`, `canonical/2`, `maybe_put/3` unchanged.)

Then update `assign/1` to build and pass the group tables:

```elixir
  def assign(rounds) do
    fixtures = Repo.all(Fixture)
    by_id = Map.new(fixtures, &{&1.id, &1})
    idx = canonical_index(Enum.flat_map(fixtures, &[&1.team1, &1.team2]))
    group_tables = GroupTables.build(fixtures)

    summary =
      rounds
      |> plan(fixtures, idx, group_tables)
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

Note: `GroupTables.build/1` self-filters to fixtures with a `:group`, so passing all fixtures is fine (KO fixtures have `group: nil` and are ignored). The existing v1 `plan/3` callers still compile via the defaulted 4th arg (empty tables → both-placeholder can't project → skips, exactly v1's behaviour).

- [ ] **Step 4: Run tests to verify they pass**

Run: `mise exec -- mix test test/predictex/fifa/knockout_teams_test.exs test/predictex/fifa/knockout_teams_assign_test.exs`
Expected: PASS — both-placeholder cases fill/skip correctly; the v1 pure tests (anchored, junk-name, both-placeholder-no-anchor) still pass under the defaulted arg.

- [ ] **Step 5: Run the full gate**

Run: `mise exec -- mix precommit`
Expected: green.

- [ ] **Step 6: Commit**

```bash
git add lib/predictex/fifa/knockout_teams.ex test/predictex/fifa/knockout_teams_test.exs test/predictex/fifa/knockout_teams_assign_test.exs
git commit -m "feat(fifa): both-placeholder R32 fill via group-standings anchor (predictex-dum)"
```

---

### Task 3: End-to-end — `:pending`→`:editable` flip + ahi regression + docs

**Files:**
- Test: `test/predictex/results/ingest_test.exs` (ahi both-placeholder regression), `test/predictex_web/live/my_predictions_live_test.exs` (flip)
- Modify (docs): `lib/predictex/fifa/knockout_teams.ex` moduledoc.

**Interfaces:**
- Consumes: `KnockoutTeams.assign/1`, `Predictions.fixture_entry_state/2`, the `:native_ko` flag render.

- [ ] **Step 1: ahi regression — a both-placeholder fill survives an openfootball placeholder re-sync**

In `test/predictex/results/ingest_test.exs`, inside the `describe "no-downgrade guard"` block, add a both-placeholder variant of the existing e5o regression. It seeds a group result (so the standings anchor `1I`→France), runs `assign`, then re-syncs the openfootball placeholders and asserts BOTH filled names survive:

```elixir
    test "an e5o both-placeholder fill survives a later openfootball placeholder sync (predictex-dum)" do
      {:ok, grp} = Tournament.create_round(%{name: "Group I", stage: :group, ordinal: 1})

      for {a, b, g} <- [{"France", "Spain", "I"}, {"Sweden", "Qatar", "C"}] do
        {:ok, _} =
          Tournament.create_fixture(%{
            external_ref: "g-#{a}",
            team1: a,
            team2: b,
            group: g,
            status: :completed,
            home_goals: 2,
            away_goals: 0,
            kickoff_at: ~U[2026-06-20 19:00:00Z],
            round_id: grp.id
          })
      end

      # openfootball seeds the R32 fixture both-placeholder (num 73 via ko_doc; kickoff 19:00 UTC).
      ko_doc("1I", "3C/D/F/G/H") |> Ingest.plan() |> Ingest.commit()

      rounds = [
        %{
          "stage" => "r32",
          "tournaments" => [
            %{"date" => "2026-06-28T19:00:00+00:00", "homeSquadName" => "France", "awaySquadName" => "Sweden"}
          ]
        }
      ]

      assert %{resolved: 1} = KnockoutTeams.assign(rounds)
      filled = Tournament.get_fixture_by_source_num(73)
      assert {filled.team1, filled.team2} == {"France", "Sweden"}

      # Next ResultSync STILL carries both placeholders — must NOT revert either filled name.
      ko_doc("1I", "3C/D/F/G/H") |> Ingest.plan() |> Ingest.commit()
      kept = Tournament.get_fixture_by_source_num(73)
      assert {kept.team1, kept.team2} == {"France", "Sweden"}
    end
```

Run: `mise exec -- mix test test/predictex/results/ingest_test.exs`
Expected: PASS (the `ahi` guard already preserves resolved team names; this proves it for a both-placeholder fill too).

- [ ] **Step 2: LiveView flip — a both-placeholder R32 card becomes `:editable`**

In `test/predictex_web/live/my_predictions_live_test.exs`, add (mirror the existing `@tag :native_ko` per-fixture-resolution / e5o flip test, but the fixture starts both-placeholder and the worker fills both sides):

```elixir
  @tag :native_ko
  test "a both-placeholder R32 card flips :editable after FIFA + standings resolve both sides",
       %{conn: conn, round: round} do
    player = player_fixture(%{display_name: "BothPh"})
    past = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.truncate(:second)
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    # Group I result: France wins I (the standings anchor) + seeds canonical names.
    _g1 = fixture!(round, %{team1: "France", team2: "Spain", group: "I", kickoff_at: past, status: :completed, home_goals: 2, away_goals: 0})
    _g2 = fixture!(round, %{team1: "Sweden", team2: "Qatar", group: "C", kickoff_at: past, status: :completed, home_goals: 1, away_goals: 0})

    {:ok, ko} = Tournament.create_round(%{name: "Round of 32", stage: :knockout, ordinal: 4})
    ko_fx = fixture!(ko, %{team1: "1I", team2: "3C/D/F/G/H", kickoff_at: future})

    {:ok, lv, _html} = conn |> log_in_player(player) |> live(~p"/predictions")
    html = lv |> element("button", "Round of 32") |> render_click()
    refute html =~ ~s(name="picks[#{ko_fx.id}][home_goals]")
    assert html =~ "awaiting teams"

    Application.put_env(:predictex, :ko_teams_rounds_fun, fn ->
      {:ok, [%{"stage" => "r32", "tournaments" => [%{"date" => DateTime.to_iso8601(future), "homeSquadName" => "France", "awaySquadName" => "Sweden"}]}]}
    end)
    on_exit(fn -> Application.delete_env(:predictex, :ko_teams_rounds_fun) end)

    assert :ok = Predictex.Workers.KnockoutTeams.perform(%Oban.Job{args: %{}})
    html = render(lv)

    assert html =~ ~s(name="picks[#{ko_fx.id}][home_goals]")
    assert html =~ "France"
    assert html =~ "Sweden"
  end
```

> This test sets the global `:ko_teams_rounds_fun` env key. The worker test (`knockout_teams_test.exs`) is already `async: false` for this reason; `my_predictions_live_test.exs` is the only other setter. If the gate shows a flaky interaction, the fix is the same one-liner as `predictex-ahi`'s final review (the controller will handle it) — do NOT add a `config/test.exs` override.

Run: `mise exec -- mix test test/predictex_web/live/my_predictions_live_test.exs --only native_ko`
Expected: PASS.

- [ ] **Step 3: Docs**

Update the `Predictex.Fifa.KnockoutTeams` moduledoc to note that both-placeholder fixtures are now resolved via the group-standings anchor (predictex-dum), not just the anchored-on-a-resolved-side v1 path.

- [ ] **Step 4: Run the full gate**

Run: `mise exec -- mix precommit`
Expected: green.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "test(fifa): both-placeholder flip + ahi regression + docs (predictex-dum)"
```

---

## Self-Review

**Spec coverage:**
- Projection-validated anchor (resolve `1X`/`2X` vs `GroupTables`, match a FIFA name → orient) → Task 2 (`orient_both`/`project_slot`). ✓
- Fill both sides, all-or-nothing → Task 2 (`both_placeholder` nil-guard). ✓
- Skip when nothing projects / matches neither / non-canonical → Task 2 tests. ✓
- Don't anchor on a provisional tie → `team_at` `provisional_tie?: false` guard + Task 2 test. ✓
- Uniform scope (winner-v-third AND winner-v-runner-up) → `orient_both` tries both sides; either projecting `1X`/`2X` anchors. ✓
- Depend on pure `GroupTables` + `Knockout.parse_slot`, NOT `Bracket` read-model → Task 1 + Task 2 (no `Bracket` alias). ✓
- ahi guard keeps the fill stuck → Task 3 Step 1 regression. ✓
- `:pending`→`:editable` flip → Task 3 Step 2. ✓
- No blind positional, no projection-only write → orientation always via a matched anchor; written names are FIFA's. ✓
- No migration / no new deps → confirmed. ✓

**Placeholder scan:** No "TBD/handle edge cases" — every step has concrete code. The two confirm-the-real-constructor notes (Task 2 Step 1, Task 3) specify how to confirm + that assertion semantics govern, not a deferral.

**Type consistency:** `parse_slot/1 :: {:winner,g}|{:runner_up,g}|{:third,[g]}|{:later,name}|{:resolved,name}` consumed by `project_slot/2` (Task 2). `plan/4` defaulted arg keeps v1 `plan/3` callers valid. `orient_both` returns `{c_team1, c_team2}` consumed by `both_placeholder`'s nil-guard → `%{team1:, team2:}`, the same shape `assign/1`'s reduce pops `:fixture_id` from. `team_at` reads `%{team:, provisional_tie?:}` (the `GroupTables.Row` fields). Consistent.

## Notes for the implementer

- Orientation is per-side: `orient_both` tries team1 as the anchor first, then team2 — whichever is a `1X`/`2X` slot that projects to a FIFA-matching team. The returned tuple is always `{for_team1, for_team2}` in fixture order, regardless of which side anchored.
- The winner-side fill is FIFA-sourced and projection-validated (we confirmed the projected team ≡ that FIFA name); we never write a team from standings alone.
- `GroupTables.build/1` is pure and already filters to `:group` fixtures — do not pre-filter; pass all fixtures.
- The `provisional_tie?: false` guard in `team_at` is *tie*-detection, NOT *group-decided* detection: it rejects a tied leader but will anchor on a clear leader of a group that isn't yet mathematically locked. That's accepted — if FIFA is ever ahead of our standings' lock, a wrong fill self-heals via openfootball's real→real authority (the `ahi` guard only blocks real→placeholder). Do not over-read the flag as "group complete"; a stricter "all teams played equal games" check is possible future hardening, out of scope here.
- After this lands, no flag/rollout change — it only fills placeholder fixtures FIFA has resolved AND our standings corroborate; member visibility stays gated by `:native_ko_entry`.
