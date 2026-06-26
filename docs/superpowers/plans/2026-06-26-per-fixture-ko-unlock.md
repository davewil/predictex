# Per-fixture native R32 unlock — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let members predict each Round-of-32 match the moment its two teams resolve (FIFA-style), instead of the whole round opening at once when the group stage ends.

**Architecture:** A new pure `Predictex.Knockout.resolved_team?/1` (placeholder ⇆ real-name) becomes the single source of "is this slot a resolved team", consumed by both `Bracket` (refactored) and a new pure `Predictions.fixture_entry_state/2` (`:pending | :locked | :editable`). The write path gains a resolution partition and a commit-at-kickoff booster guard; the LiveView renders per-fixture and loosens its gate from `round_open?` to flag+knockout.

**Tech Stack:** Elixir 1.20 / OTP 28, Phoenix 1.8 LiveView, Ecto/Postgres, FunWithFlags. No new deps. **No migration.**

## Global Constraints

- Run mix via mise: **`mise exec -- mix …`** (plain `mix` is the wrong version).
- The gate is **`mix precommit`** (compile --warnings-as-errors, deps.unlock --check-unused, format --check-formatted, credo --strict, test), run on every Elixir-staging commit via lefthook. Never `--no-verify`.
- TDD: failing test first, run-to-fail, implement, run-to-pass, commit.
- New ConnCase/DataCase tests creating multiple rounds insert them **ascending by `:ordinal`** (deadlock invariant).
- Flag-test isolation: enable the flag in `setup`, `FunWithFlags.Store.Cache.flush/0` in `on_exit` — NEVER a `config/test.exs` `:cache` override (compile-env gotcha: passes locally, fails CI).
- A placeholder team string is one of: `^[12][A-Z]$` (group winner/runner-up), `^3[A-Z](/[A-Z])+$` (third-placed candidate set), `^[WL]\d+$` (later-round). Anything else is a resolved real team name. These are the **same** patterns `Bracket` already encodes — Task 1 makes them one definition.
- All new code covered by tests.

## File Structure

| File | Responsibility |
|------|----------------|
| `lib/predictex/knockout.ex` | NEW pure: `resolved_team?/1` (owns the placeholder regexes). |
| `lib/predictex/bracket.ex` (modify) | `resolve_slot/2` defers the "is it resolved" decision to `Knockout.resolved_team?/1`. |
| `lib/predictex/predictions.ex` (modify) | `fixture_entry_state/2`; `save_round_predictions/5` resolution partition + booster guard. |
| `lib/predictex_web/live/my_predictions_live.ex` (modify) | `native_ko_round?/2` gate, `@fixture_states`, per-fixture render, `:booster_locked` flash. |
| `lib/mix/tasks/predictex.preview_knockout.ex` (modify) | Resolve a few R32 fixtures' teams (was: settle predecessor). |
| `lib/predictex/tournament.ex` (modify, Task 5) | Remove `round_open?/1` if it ends up uncalled. |
| `docs/rules.md` (modify, Task 5) | §4 availability rule → per-fixture. |
| Test files | `test/predictex/knockout_test.exs` (new), and edits to `bracket_test.exs`, `predictions_test.exs`, `my_predictions_live_test.exs`, `predictex.preview_knockout_test.exs`, `tournament_test.exs`. |

---

### Task 1: `Predictex.Knockout.resolved_team?/1` + refactor `Bracket` onto it

**Files:**
- Create: `lib/predictex/knockout.ex`, `test/predictex/knockout_test.exs`
- Modify: `lib/predictex/bracket.ex`
- Test: `test/predictex/bracket_test.exs` (existing cases must still pass — regression)

**Interfaces:**
- Produces: `Knockout.resolved_team?(name) :: boolean` — `true` iff `name` is a binary that is NOT a placeholder; `false` for a placeholder or a non-binary.

- [ ] **Step 1: Write the failing test**

Create `test/predictex/knockout_test.exs`:

```elixir
defmodule Predictex.KnockoutTest do
  use ExUnit.Case, async: true

  alias Predictex.Knockout

  test "resolved_team?/1 is false for every placeholder form" do
    refute Knockout.resolved_team?("1C")
    refute Knockout.resolved_team?("2F")
    refute Knockout.resolved_team?("3A/B/C/D/F")
    refute Knockout.resolved_team?("W89")
    refute Knockout.resolved_team?("L101")
  end

  test "resolved_team?/1 is true for real team names" do
    assert Knockout.resolved_team?("Croatia")
    assert Knockout.resolved_team?("South Africa")
    assert Knockout.resolved_team?("Côte d'Ivoire")
  end

  test "resolved_team?/1 is total — non-binaries and empties never raise" do
    refute Knockout.resolved_team?(nil)
    # empty string is not a placeholder pattern, so it counts as (degenerate) resolved
    assert Knockout.resolved_team?("")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex/knockout_test.exs`
Expected: FAIL — `Predictex.Knockout.resolved_team?/1 is undefined`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/predictex/knockout.ex`:

```elixir
defmodule Predictex.Knockout do
  @moduledoc """
  Pure knockout-stage predicates shared across the projected bracket (`predictex-7qu`) and the
  per-fixture native entry gate (`predictex-80k`).

  `resolved_team?/1` is the single definition of "is this fixture slot a resolved real team or
  still a bracket placeholder". The placeholder grammar (group winner/runner-up `1C`/`2F`,
  third-placed candidate set `3A/B/C/D/F`, later-round `W89`/`L101`) is owned here so the bracket
  read-model and the prediction write path can never disagree about what counts as resolved.
  """

  @winner_runner_up ~r/^[12][A-Z]$/
  @third ~r{^3[A-Z](?:/[A-Z])+$}
  @later_round ~r/^[WL]\d+$/

  @doc "True iff `name` is a real team name (not a bracket placeholder). Total."
  def resolved_team?(name) when is_binary(name) do
    not (Regex.match?(@winner_runner_up, name) or Regex.match?(@third, name) or
           Regex.match?(@later_round, name))
  end

  def resolved_team?(_), do: false
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/predictex/knockout_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Refactor `Bracket.resolve_slot/2` to defer to `Knockout`**

In `lib/predictex/bracket.ex`: add `alias Predictex.Knockout` near the existing aliases, and make the resolved-team decision the FIRST branch of the `cond` in `resolve_slot/2`, so `Knockout` owns classification. Change the `cond` to:

```elixir
  def resolve_slot(placeholder, group_tables) when is_binary(placeholder) do
    cond do
      Knockout.resolved_team?(placeholder) ->
        {:resolved, placeholder}

      caps = Regex.run(@winner_runner_up, placeholder) ->
        [_, pos, group] = caps
        resolve_position(group_tables, group, String.to_integer(pos))

      Regex.match?(@third, placeholder) ->
        groups = placeholder |> String.slice(1..-1//1) |> String.split("/")
        {:candidate_set, groups}

      true ->
        {:tbd, placeholder}
    end
  end
```

Note: the `@later_round` branch that returned `{:tbd, placeholder}` is now subsumed by the final `true -> {:tbd, placeholder}` (a `W89`/`L101` is not `resolved_team?`, not winner/runner-up, not a third-set, so it falls through to `true`). Keep `@winner_runner_up` and `@third` module attributes in `bracket.ex` (still used for capture/parse); the `@later_round` attribute and the `@third`-via-`trim`/`slice` parsing are unchanged from current code. Delete the now-unused `@later_round` attribute in `bracket.ex` if the compile warns it is unused.

- [ ] **Step 6: Run the Bracket regression tests**

Run: `mise exec -- mix test test/predictex/bracket_test.exs test/predictex/bracket_view_test.exs`
Expected: PASS — all existing `resolve_slot/2`/`build/2`/`view/0` cases unchanged (`"1C"`→`{:exact,…}`, `"3A/B/C/D/F"`→`{:candidate_set,…}`, `"Germany"`→`{:resolved,…}`, `"W74"`→`{:tbd,"W74"}`, `""`→`{:resolved,""}`).

- [ ] **Step 7: Commit**

```bash
git add lib/predictex/knockout.ex test/predictex/knockout_test.exs lib/predictex/bracket.ex
git commit -m "feat(knockout): Knockout.resolved_team?/1 single source; Bracket defers to it (predictex-80k)"
```

---

### Task 2: `Predictions.fixture_entry_state/2`

**Files:**
- Modify: `lib/predictex/predictions.ex`
- Test: `test/predictex/predictions_test.exs`

**Interfaces:**
- Consumes: `Knockout.resolved_team?/1`, the existing `Predictions.locked?/2`.
- Produces: `Predictions.fixture_entry_state(fixture, now) :: :pending | :locked | :editable`.

- [ ] **Step 1: Write the failing test**

Add to `test/predictex/predictions_test.exs` (new `describe` at the end of the module, before the final `end`):

```elixir
  describe "fixture_entry_state/2 (per-fixture KO entry gate)" do
    alias Predictex.Tournament.Fixture

    @now ~U[2026-06-28 12:00:00Z]

    test ":pending when either team is still a bracket placeholder" do
      future = DateTime.add(@now, 3600, :second)
      assert Predictions.fixture_entry_state(%Fixture{team1: "Germany", team2: "3A/B/C/D/F", kickoff_at: future}, @now) == :pending
      assert Predictions.fixture_entry_state(%Fixture{team1: "1C", team2: "Belgium", kickoff_at: future}, @now) == :pending
    end

    test ":editable when both teams resolved and kickoff is in the future" do
      future = DateTime.add(@now, 3600, :second)
      assert Predictions.fixture_entry_state(%Fixture{team1: "Brazil", team2: "Japan", kickoff_at: future}, @now) == :editable
    end

    test ":locked when both teams resolved and kickoff has passed" do
      past = DateTime.add(@now, -3600, :second)
      assert Predictions.fixture_entry_state(%Fixture{team1: "Brazil", team2: "Japan", kickoff_at: past}, @now) == :locked
    end

    test ":pending takes precedence over a passed kickoff" do
      past = DateTime.add(@now, -3600, :second)
      assert Predictions.fixture_entry_state(%Fixture{team1: "1A", team2: "2B", kickoff_at: past}, @now) == :pending
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex/predictions_test.exs`
Expected: FAIL — `Predictions.fixture_entry_state/2 is undefined`.

- [ ] **Step 3: Write minimal implementation**

In `lib/predictex/predictions.ex`, add `alias Predictex.Knockout` near the top (alongside the existing aliases), and add this function next to `locked?/2`:

```elixir
  @doc """
  Per-fixture native KO entry state at `now` (predictex-80k):

    * `:pending`  — a slot is still a bracket placeholder; can't predict an unknown team
    * `:locked`   — both teams resolved, kickoff has passed (read-only)
    * `:editable` — both teams resolved, kickoff in the future

  `:pending` is checked first so an unresolved fixture is never editable even if its scheduled
  kickoff has somehow passed. Reuses `locked?/2` so the lockout rule has one definition.
  """
  def fixture_entry_state(%Fixture{team1: t1, team2: t2} = fixture, now) do
    cond do
      not (Knockout.resolved_team?(t1) and Knockout.resolved_team?(t2)) -> :pending
      locked?(fixture, now) -> :locked
      true -> :editable
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/predictex/predictions_test.exs`
Expected: PASS (4 new tests; the rest of the file unchanged).

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/predictions.ex test/predictex/predictions_test.exs
git commit -m "feat(predictions): fixture_entry_state/2 per-fixture KO gate (predictex-80k)"
```

---

### Task 3: Write path — resolution partition + commit-at-kickoff booster guard

**Files:**
- Modify: `lib/predictex/predictions.ex` (`save_round_predictions/5`)
- Modify: `lib/predictex_web/live/my_predictions_live.ex` (`do_save_round` flash for `:booster_locked`)
- Test: `test/predictex/predictions_test.exs`

**Interfaces:**
- Consumes: `Knockout.resolved_team?/1`, existing `locked?/2`.
- Produces: `save_round_predictions/5` returns `{:error, :booster_locked}` when a locked fixture in the round already holds the booster and the submit sets a booster on a different fixture; its `{:ok, results}` map gains `:pending` for unresolved-fixture rows (never written).

- [ ] **Step 1: Write the failing tests**

Add to the `describe "save_round_predictions/4 (member, lockout-aware)"` block in `test/predictex/predictions_test.exs` (its `setup` already provides `open` (future kickoff) and `locked` (past kickoff) fixtures with real team names "A"/"B"). Add a helper fixture with a placeholder team and the two tests:

```elixir
    test "a row for an unresolved (placeholder-team) fixture is rejected as :pending and never written", %{round: round, player: player} do
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
      pending = fixture!(round, %{team1: "1A", team2: "2B", kickoff_at: future})
      rows = [%{fixture_id: pending.id, home_goals: 2, away_goals: 1, booster: false}]

      assert {:ok, results} = Predictions.save_round_predictions(player.id, round.id, rows, true)
      assert results[pending.id] == :pending
      assert Predictions.get_player_fixture_prediction(player.id, pending.id) == nil
    end

    test "rejects :booster_locked when a kicked-off fixture already holds the booster", %{round: round, player: player, open: open, locked: locked} do
      # Commit the booster to the locked (kicked-off) fixture, as a prior save would have.
      {:ok, _} = Predictions.admin_upsert_prediction(%{player_id: player.id, fixture_id: locked.id, home_goals: 1, away_goals: 0, booster: true})

      # Now try to boost the still-open fixture.
      rows = [%{fixture_id: open.id, home_goals: 2, away_goals: 1, booster: true}]
      assert {:error, :booster_locked} = Predictions.save_round_predictions(player.id, round.id, rows, true)

      # The committed booster on the locked fixture survives; nothing was written to `open`.
      assert Predictions.get_player_fixture_prediction(player.id, locked.id).booster == true
      assert Predictions.get_player_fixture_prediction(player.id, open.id) == nil
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mise exec -- mix test test/predictex/predictions_test.exs`
Expected: FAIL — `:pending` not in results (the placeholder row currently `:upserted`); `:booster_locked` not returned (currently a constraint rollback → `{:error, ...}` with a different shape, or an `:upserted`).

- [ ] **Step 3: Implement the booster guard + resolution partition**

In `lib/predictex/predictions.ex`, rewrite the `save_round_predictions(player_id, round_id, rows, true, now)` clause body. Add the booster guard before the existing work, and split the `open` rows by resolution:

```elixir
  def save_round_predictions(player_id, round_id, rows, true, now)
      when is_list(rows) do
    fixtures = Map.new(Repo.all(from f in Fixture, where: f.round_id == ^round_id), &{&1.id, &1})

    # Commit-at-kickoff booster guard (predictex-80k): if a kicked-off fixture in this round
    # already holds the booster and the submit sets a booster on a different fixture, reject
    # cleanly instead of hitting the one-booster-per-round unique index. The member keeps the
    # committed booster and gets a clear message.
    if booster_locked_conflict?(player_id, round_id, fixtures, rows, now) do
      {:error, :booster_locked}
    else
      do_save_round_predictions(player_id, round_id, rows, fixtures, now)
    end
  end

  defp do_save_round_predictions(player_id, round_id, rows, fixtures, now) do
    {known, unknown} = Enum.split_with(rows, &Map.has_key?(fixtures, &1.fixture_id))
    {locked, open} = Enum.split_with(known, &locked?(Map.fetch!(fixtures, &1.fixture_id), now))

    # Among unlocked rows, reject those whose fixture is still a bracket placeholder (:pending):
    # the UI never offers them; a crafted payload is dropped here (defense in depth).
    {pending, editable} =
      Enum.split_with(open, fn row ->
        fx = Map.fetch!(fixtures, row.fixture_id)
        not (Knockout.resolved_team?(fx.team1) and Knockout.resolved_team?(fx.team2))
      end)

    Repo.transaction(fn ->
      open_ids = Enum.map(editable, & &1.fixture_id)

      from(p in Prediction,
        where: p.player_id == ^player_id and p.round_id == ^round_id and p.fixture_id in ^open_ids
      )
      |> Repo.update_all(set: [booster: false])

      saved =
        Enum.reduce(editable, %{}, fn row, acc ->
          Map.put(acc, row.fixture_id, save_round_row(player_id, round_id, row))
        end)

      results = Enum.reduce(locked, saved, fn row, acc -> Map.put(acc, row.fixture_id, :locked) end)
      results = Enum.reduce(pending, results, fn row, acc -> Map.put(acc, row.fixture_id, :pending) end)
      results = Enum.reduce(unknown, results, fn row, acc -> Map.put(acc, row.fixture_id, :unknown) end)

      if Enum.any?(results, fn {_id, r} -> r == {:error, :booster_on_blank} end) do
        Repo.rollback({:booster_on_blank, results})
      else
        results
      end
    end)
    |> broadcast_on_success()
  end

  # A different fixture already holds the booster AND it has kicked off → the booster is
  # committed to it for the round; a new booster elsewhere is rejected.
  defp booster_locked_conflict?(player_id, round_id, fixtures, rows, now) do
    incoming = Enum.find(rows, & &1.booster)

    committed_id =
      Repo.one(
        from p in Prediction,
          where: p.player_id == ^player_id and p.round_id == ^round_id and p.booster == true,
          select: p.fixture_id
      )

    not is_nil(incoming) and not is_nil(committed_id) and incoming.fixture_id != committed_id and
      locked?(Map.get(fixtures, committed_id), now)
  end
```

Note: `locked?/2` already guards `nil` (`locked?(nil, _) -> false`), so a committed booster on a fixture outside this round map yields `false` (no false conflict). Keep the original single-clause body's logic intact otherwise — the only behavioural change is the new `:pending` split and the early `:booster_locked` return.

- [ ] **Step 4: Add the `:booster_locked` flash in the LiveView**

In `lib/predictex_web/live/my_predictions_live.ex`, in `do_save_round`, replace the catch-all error arm so `:booster_locked` gets a specific message. Change:

```elixir
          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not save predictions.")}
```

to:

```elixir
          {:error, :booster_locked} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Your booster is locked to a match that's already kicked off — it can't be moved this round."
             )}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not save predictions.")}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mise exec -- mix test test/predictex/predictions_test.exs`
Expected: PASS — `:pending` row rejected+unwritten; `:booster_locked` returned, committed booster preserved, `open` unwritten; all pre-existing `save_round_predictions` cases (saves, `:locked`, `:unknown`, booster-on-blank, broadcast) still green.

- [ ] **Step 6: Commit**

```bash
git add lib/predictex/predictions.ex lib/predictex_web/live/my_predictions_live.ex test/predictex/predictions_test.exs
git commit -m "feat(predictions): :pending resolution partition + commit-at-kickoff booster guard (predictex-80k)"
```

---

### Task 4: Per-fixture render + loosened gate (+ replace the cutover test)

**Files:**
- Modify: `lib/predictex_web/live/my_predictions_live.ex`
- Test: `test/predictex_web/live/my_predictions_live_test.exs`

**Interfaces:**
- Consumes: `Predictions.fixture_entry_state/2`, `native_ko_enabled?/1` (existing).
- Produces: the R32 tab renders editable/locked/pending per fixture; the `save_round` handler gate is `native_ko_round?/2` (flag + knockout, NO `round_open?`).

- [ ] **Step 1: Write the failing tests**

In `test/predictex_web/live/my_predictions_live_test.exs`: (a) **replace** the `@tag :native_ko` cutover test ("knockout round flips read-only → editable the moment its predecessor completes (28 Jun cutover)", ~line 442) with the per-fixture-resolution test below, and (b) add a mixed-state render test. Both are `@tag :native_ko` (flag enabled by the existing tag setup).

```elixir
  @tag :native_ko
  test "a knockout fixture flips read-only → editable the moment ITS teams resolve", %{conn: conn, round: round} do
    player = player_fixture(%{display_name: "PerFixture"})
    past = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.truncate(:second)
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    # Close ordinal 1 so it doesn't steal "active".
    _done1 = fixture!(round, %{team1: "France", team2: "Spain", kickoff_at: past, status: :completed, home_goals: 1, away_goals: 0})

    {:ok, ko_round} = Tournament.create_round(%{name: "Round of 32", stage: :knockout, ordinal: 4})
    # Starts with placeholder teams → :pending → read-only "awaiting teams".
    ko_fx = fixture!(ko_round, %{team1: "1A", team2: "2B", kickoff_at: future})

    {:ok, lv, _html} = conn |> log_in_player(player) |> live(~p"/predictions")
    html = lv |> element("button", "Round of 32") |> render_click()
    refute html =~ ~s(name="picks[#{ko_fx.id}][home_goals]")
    assert html =~ "awaiting teams"

    # FIFA/openfootball resolve the bracket: the fixture's own teams become real names.
    ko_fx |> Ecto.Changeset.change(%{team1: "Brazil", team2: "Japan"}) |> Predictex.Repo.update!()
    Tournament.broadcast_change()
    html = render(lv)

    # The same fixture now renders editable inputs — gated on ITS resolution, not the whole round.
    assert html =~ ~s(name="picks[#{ko_fx.id}][home_goals]")
    assert html =~ "Brazil"
  end

  @tag :native_ko
  test "the R32 tab is a per-fixture mix: editable, locked, pending", %{conn: conn, round: round} do
    player = player_fixture(%{display_name: "Mix"})
    past = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.truncate(:second)
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    _done1 = fixture!(round, %{team1: "France", team2: "Spain", kickoff_at: past, status: :completed, home_goals: 1, away_goals: 0})

    {:ok, ko} = Tournament.create_round(%{name: "Round of 32", stage: :knockout, ordinal: 4})
    editable = fixture!(ko, %{team1: "Brazil", team2: "Japan", kickoff_at: future})
    locked = fixture!(ko, %{team1: "Spain", team2: "Italy", kickoff_at: past})
    pending = fixture!(ko, %{team1: "Germany", team2: "3A/B/C/D/F", kickoff_at: future})

    {:ok, lv, _html} = conn |> log_in_player(player) |> live(~p"/predictions")
    html = lv |> element("button", "Round of 32") |> render_click()

    assert html =~ ~s(name="picks[#{editable.id}][home_goals]")          # editable: inputs
    refute html =~ ~s(name="picks[#{locked.id}][home_goals]")            # locked: no inputs
    refute html =~ ~s(name="picks[#{pending.id}][home_goals]")           # pending: no inputs
    assert html =~ "awaiting teams"                                      # pending card label
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mise exec -- mix test test/predictex_web/live/my_predictions_live_test.exs`
Expected: FAIL — under the current round-level gate the pending fixture's round isn't open (no completed predecessor), so the editable form doesn't render and the new assertions fail.

- [ ] **Step 3: Loosen the gate and add `@fixture_states`**

In `lib/predictex_web/live/my_predictions_live.ex`:

a) Replace the gate helpers (the `editable_round?/2` clauses, ~lines 467-470) with:

```elixir
  # A knockout round shows the native entry view when the flag is on for this player. Individual
  # fixtures are then gated per-fixture (Predictions.fixture_entry_state/2) — predictex-80k.
  defp native_ko_round?(%{round: %{stage: :knockout}}, player), do: native_ko_enabled?(player)
  defp native_ko_round?(_, _player), do: false
```

(`native_ko_enabled?/1` stays as-is.)

b) In `handle_event("save_round", …)` (~line 50) change the guard:

```elixir
    if native_ko_round?(active, socket.assigns.current_scope.player) do
```

c) In `render/1`'s assigns block (~line 128) replace the `:editable_round?` assign with `:native_ko_round?` plus a per-fixture state map computed only for the active round:

```elixir
      |> assign(:native_ko_round?, native_ko_round?(active, assigns.current_scope.player))
      |> assign(:fixture_states, fixture_states(active, assigns.now))
```

and add the helper near `native_ko_round?/2`:

```elixir
  defp fixture_states(%{fixtures: fixtures}, now),
    do: Map.new(fixtures, fn fx -> {fx.fixture.id, Predictions.fixture_entry_state(fx.fixture, now)} end)

  defp fixture_states(_active, _now), do: %{}
```

- [ ] **Step 4: Render per-fixture inside the form**

In `render/1`, change the form gate (`:if={@active && @editable_round?}`, ~line 217) to `:if={@active && @native_ko_round?}` and the read-only grid gate (`:if={@active && not @editable_round?}`, ~line 322) to `:if={@active && not @native_ko_round?}`.

Then, inside the form's fixture grid, wrap each fixture in a `display:contents` element and gate the three card variants on the fixture's state. Replace the existing `<div :for={fx <- @active.fixtures} data-fixture-card ...> …editable card… </div>` with:

```heex
          <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
            <div :for={fx <- @active.fixtures} class="contents">
              <div
                :if={@fixture_states[fx.fixture.id] == :editable}
                data-fixture-card
                class="rounded-box bg-base-100 border border-base-content/10 p-3 shadow"
              >
                <%!-- …the existing editable card markup, UNCHANGED (home/away goal inputs,
                     first-scorer toggles, ⚡ booster button)… --%>
              </div>

              <.fixture_card
                :if={@fixture_states[fx.fixture.id] == :locked}
                fx={fx}
                stage={@active.round.stage}
                fifa_url={@fifa_url}
                live_cta?={Predictions.cta_window?(fx.fixture, @now)}
                live_path={~p"/fixtures/#{fx.fixture.id}"}
                tz={@tz}
              />

              <div
                :if={@fixture_states[fx.fixture.id] == :pending}
                class="rounded-box bg-base-200 border border-base-content/10 p-3 text-sm"
              >
                <p class="font-semibold">
                  {Flags.flag(fx.fixture.team1)} {fx.fixture.team1}
                  <span class="opacity-60">v</span>
                  {Flags.flag(fx.fixture.team2)} {fx.fixture.team2}
                </p>
                <p class="opacity-70">⏳ awaiting teams</p>
              </div>
            </div>
          </div>
```

Keep the editable card's inner markup byte-for-byte as it is today (the `data-goal-input`, `data-scorer-*`, `data-booster-btn` attributes the `RoundEntry` hook depends on) — only its `:if` gate and the `contents` wrapper are new. The sr-only `booster_fixture_id` input and the `Save picks` submit button stay where they are inside the form.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mise exec -- mix test test/predictex_web/live/my_predictions_live_test.exs`
Expected: PASS — the per-fixture-resolution test and the mixed-state test pass; the other `@tag :native_ko` tests (member enters picks, booster-on-blank, flag-off read-only, locked group read-only) still pass.

- [ ] **Step 6: Run the full gate**

Run: `mise exec -- mix precommit`
Expected: green (compile/format/credo/test). `editable_round?` is gone with no remaining references.

- [ ] **Step 7: Commit**

```bash
git add lib/predictex_web/live/my_predictions_live.ex test/predictex_web/live/my_predictions_live_test.exs
git commit -m "feat(predictions): per-fixture R32 render + flag-gated round (predictex-80k)"
```

---

### Task 5: Cleanup — preview task, `round_open?/1`, rules.md

**Files:**
- Modify: `lib/mix/tasks/predictex.preview_knockout.ex`, `test/mix/tasks/predictex.preview_knockout_test.exs`
- Modify (conditional): `lib/predictex/tournament.ex`, `test/predictex/tournament_test.exs`, `docs/rules.md`

**Interfaces:**
- Produces: `Mix.Tasks.Predictex.PreviewKnockout` resolves real team names onto a couple of the first knockout round's fixtures (so they become `:editable` locally). `Tournament.round_open?/1` removed iff it has no remaining callers.

- [ ] **Step 1: Re-point the preview task at fixture resolution**

In `lib/predictex/tournament.ex` confirm `round_open?/1`'s callers first:

Run: `grep -rn "round_open?" lib/ test/`
Note every caller. After the gate change in Task 4, the only `lib/` reference should be the moduledoc; the preview task uses it indirectly via "settle predecessor". This step removes that indirect use.

Rewrite `open_first_knockout_round/0` (and the task's `run/0` message) in `lib/mix/tasks/predictex.preview_knockout.ex` to resolve teams instead of settling the predecessor:

```elixir
  @doc """
  Resolve real team names onto the first knockout round's first two unresolved fixtures, so the
  per-fixture native entry form shows EDITABLE cards locally (predictex-80k). Returns
  `{:ok, %{round: round, resolved_count: n}}`. Pure of IO / app.start so it is directly testable.
  """
  def open_first_knockout_round do
    ko =
      Repo.one(from r in Round, where: r.stage == :knockout, order_by: [asc: r.ordinal], limit: 1)

    if is_nil(ko),
      do: Mix.raise("No knockout round found — run `mix ecto.reset` to seed the full schedule")

    unresolved =
      from(f in Fixture, where: f.round_id == ^ko.id, order_by: [asc: f.source_num])
      |> Repo.all()
      |> Enum.reject(fn f -> Predictex.Knockout.resolved_team?(f.team1) and Predictex.Knockout.resolved_team?(f.team2) end)
      |> Enum.take(2)

    sample = [{"Brazil", "Japan"}, {"Croatia", "Belgium"}]

    Enum.zip(unresolved, sample)
    |> Enum.each(fn {f, {t1, t2}} ->
      {:ok, _} = Tournament.update_fixture(f, %{team1: t1, team2: t2})
    end)

    Tournament.broadcast_change()
    {:ok, %{round: ko, resolved_count: length(unresolved)}}
  end
```

Update `run/0`'s `{:ok, %{round: round, settled_count: n}}` destructure to `%{round: round, resolved_count: n}` and its `Mix.shell().info` copy to describe resolving fixture teams (editable cards appear for the resolved matches). Update the `@moduledoc` accordingly (it now resolves teams, not settles the predecessor).

- [ ] **Step 2: Update the preview task test**

In `test/mix/tasks/predictex.preview_knockout_test.exs`, replace assertions about the predecessor being settled / `round_open?` flipping with: after `open_first_knockout_round/0`, the first two unresolved R32 fixtures now have resolved team names (`Knockout.resolved_team?(f.team1) and resolved_team?(f.team2)`), and `resolved_count` matches. Keep the idempotence and "no knockout round" raise tests, adapted. (Read the existing test and adapt its setup; it seeds rounds — keep ascending-ordinal insertion.)

Run: `mise exec -- mix test test/mix/tasks/predictex.preview_knockout_test.exs`
Expected: PASS.

- [ ] **Step 3: Retire `round_open?/1` if uncalled**

Run again: `grep -rn "round_open?" lib/ test/`

- If the ONLY remaining references are `Tournament.round_open?/1`'s own definition + its direct test in `tournament_test.exs` + the moduledoc: **remove** the `round_open?/1` function (and the `round_complete?/1` private helper if it becomes unused — check it), delete its test(s) in `tournament_test.exs`, and remove the moduledoc line. Then update `docs/rules.md` §4 to state the per-fixture availability rule ("a knockout prediction opens when that fixture's two teams are known and kickoff is in the future"), replacing the old "round opens when its predecessor is fully completed" wording.
- If any genuine caller remains, KEEP `round_open?/1` and instead add a one-line moduledoc note that it is no longer the entry gate. Record which path you took in the commit message.

- [ ] **Step 4: Run the full gate**

Run: `mise exec -- mix precommit`
Expected: green; no dangling references to removed functions.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore(knockout): preview task resolves teams; retire round_open? + rules.md §4 (predictex-80k)"
```

---

## Self-Review

**Spec coverage:**
- Per-fixture gate (`:pending`/`:locked`/`:editable`) → Task 2 (`fixture_entry_state/2`) + Task 4 (render). ✓
- Shared `resolved_team?/1` in neutral `Knockout`, both `Bracket` and `Predictions` consume it → Task 1. ✓
- Write-path resolution partition (`:pending`) + commit-at-kickoff booster guard (`:booster_locked`) → Task 3. ✓
- Read-only + `/fixtures` CTA for `:locked` (reuse `fixture_card`); "awaiting teams" for `:pending` → Task 4. ✓
- Flag still gates everything (off → read-only grid) → Task 4 (`native_ko_round?` uses `native_ko_enabled?`). ✓
- Replace the 28-Jun cutover test → Task 4 Step 1. ✓
- Update `mix predictex.preview_knockout`; retire `round_open?/1`; rules.md §4 → Task 5. ✓
- No migration, no new deps → confirmed. ✓

**Placeholder scan:** No "TBD/TODO/handle edge cases" — the one conditional (Task 5 Step 3 keep-vs-remove `round_open?`) is a decision with both branches specified, not a placeholder. The Task 4 Step 4 `<%!-- …existing editable card markup… --%>` is an explicit instruction to preserve current bytes (the markup is in the file, not invented), with the surrounding gate/wrapper given in full.

**Type consistency:** `Knockout.resolved_team?/1 :: boolean` consumed by `Bracket.resolve_slot/2` (Task 1), `Predictions.fixture_entry_state/2` (Task 2), and `save_round_predictions/5`'s pending split (Task 3). `fixture_entry_state/2 :: :pending|:locked|:editable` consumed by `fixture_states/2` → `@fixture_states` map → render `:if`s (Task 4). `save_round_predictions/5` adds `{:error, :booster_locked}` matched in `do_save_round` (Task 3 Step 4) and result `:pending` (Task 3 tests). Consistent.

## Notes for the implementer

- The pure `Knockout`/`fixture_entry_state` take a `%Fixture{}` or any map with `team1`/`team2`/`kickoff_at`; the `Predictions` tests pass `%Fixture{}` structs directly (no DB), the LiveView passes the real dashboard fixtures.
- Do NOT change the editable card's inner markup or the `RoundEntry` hook — only its `:if` gate and the `contents` wrapper are new (Task 4). The booster's round-exclusivity in the hook still works because only `:editable` cards carry `data-booster-btn`; the commit-at-kickoff collision is caught server-side in Task 3.
- After this lands, the operational rollout is `FunWithFlags.enable(:native_ko_entry)` for all members (no code) — out of scope for the plan.
