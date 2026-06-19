# p4o — Match Recap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a settled-match recap to `/fixtures/:id` — per-player points earned on the fixture, and a goal breakdown (scorer + penalty/own-goal/regular + side).

**Architecture:** Two pure goal decoders (openfootball, FIFA) emit one unified shape; openfootball goals are persisted on a new `fixtures.goals` embed; a `MatchRecap` read model computes per-pick points (pure recompute off `Scoring`) and selects FIFA-capture goals when they reconcile with the final score, else the persisted openfootball goals. `FixtureLive` renders the recap for group-stage settled fixtures only.

**Tech Stack:** Elixir 1.20.1 / OTP 28 (via mise), Phoenix LiveView 1.8, Ecto/Postgres, Oban.

## Global Constraints

- **Run mix via mise:** `mise exec -- mix …` (plain `mix` is the wrong version).
- **Gate before every commit:** `mise exec -- mix precommit` (compile --warnings-as-errors, deps.unlock --check-unused, format --check-formatted, credo --strict, test). Never `git commit --no-verify`.
- **Commit autonomously when green; do NOT push/tag** without an explicit instruction (CLAUDE.md → Conventions & Patterns → Commit / push / deploy boundary).
- **Scope: group-stage settled fixtures only** (`status == :completed and round.stage == :group`). Knockout/ET recap is deferred (spec → Deferred decisions).
- **Unified goal event shape (atom keys):** `%{side: :home | :away, type: :penalty | :own_goal | :regular, player: String.t() | nil, minute: String.t()}`, ordered by elapsed minute.
- **Two-writer rule:** openfootball owns `goals` (like the result columns); FIFA only drives `live_*`.

---

## File Structure

- `lib/predictex/results/openfootball.ex` — **modify**: add `goal_events/1`; add `:goals` to `parse_match/1` output.
- `lib/predictex/tournament/fixture.ex` — **modify**: add `embeds_many :goals` + `cast_embed`.
- `priv/repo/migrations/<ts>_add_goals_to_fixtures.exs` — **create**: `add :goals, {:array, :map}`.
- `lib/predictex/results/ingest.ex` — **modify**: add `:goals` to `@replace_on_conflict`; pass `goals` in the plan attrs.
- `lib/predictex/tournament.ex` — **modify**: `get_fixture!/2` with preloads.
- `lib/predictex/capture.ex` — **modify**: extract pure `goal_events/1`; reuse in `analyze/1`.
- `lib/predictex/match_recap.ex` — **create**: `points/2`, `goals/2`.
- `lib/predictex_web/live/fixture_live.ex` — **modify**: preload round; render recap (final score, points, breakdown).
- Tests: `test/predictex/results/openfootball_test.exs`, `test/predictex/capture_test.exs`, `test/predictex/match_recap_test.exs` (new), `test/predictex/results/ingest_test.exs`, `test/predictex_web/live/fixture_live_test.exs`.

---

# SLICE 1 — Points-per-player (pure, no migration; independently shippable)

## Task 1: `MatchRecap.points/2`

**Files:**
- Create: `lib/predictex/match_recap.ex`
- Test: `test/predictex/match_recap_test.exs`

**Interfaces:**
- Consumes: `Predictex.Scoring.score/3` → `%{fixture_total: integer, ...}`.
- Produces: `Predictex.MatchRecap.points(fixture, predictions) :: %{player_id => integer}` where `fixture.round` is preloaded (uses `fixture.round.stage`); each prediction has `:player_id`, `:home_goals`, `:away_goals`, `:booster` (+ knockout first-scorer fields).

- [ ] **Step 1: Write the failing test**

```elixir
# test/predictex/match_recap_test.exs
defmodule Predictex.MatchRecapTest do
  use ExUnit.Case, async: true
  alias Predictex.MatchRecap

  defp fixture(attrs \\ %{}) do
    Map.merge(
      %{home_goals: 2, away_goals: 1, status: :completed, round: %{stage: :group}},
      attrs
    )
  end

  describe "points/2" do
    test "maps each player_id to the points their pick earned (booster folded in)" do
      preds = [
        %{player_id: 1, home_goals: 2, away_goals: 1, booster: false},
        %{player_id: 2, home_goals: 2, away_goals: 1, booster: true},
        %{player_id: 3, home_goals: 0, away_goals: 0, booster: false}
      ]

      pts = MatchRecap.points(fixture(), preds)

      assert pts[2] == pts[1] * 2, "booster doubles the same exact-score pick"
      assert pts[1] > pts[3], "an exact pick scores more than a wrong one"
      assert Map.keys(pts) |> Enum.sort() == [1, 2, 3]
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex/match_recap_test.exs`
Expected: FAIL — `Predictex.MatchRecap.points/2 is undefined`.

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/predictex/match_recap.ex
defmodule Predictex.MatchRecap do
  @moduledoc """
  Read model for the settled-match recap on `/fixtures/:id` (predictex-p4o).

  Pure functions over an already-loaded fixture + its predictions (+ an optional
  FIFA detail body). `FixtureLive` does the DB reads at the edge and calls these.
  """
  alias Predictex.Scoring

  @doc """
  Points each prediction earned on this fixture: `%{player_id => fixture_total}`.

  `fixture.round` must be preloaded (the stage drives knockout-only scoring lines).
  Uses `Scoring.score/3`, whose `:fixture_total` already folds in the ⚡ booster. This
  is the per-fixture contribution only — it deliberately excludes the round bonus, so it
  will not sum to the leaderboard total.
  """
  @spec points(map(), [map()]) :: %{integer() => integer()}
  def points(fixture, predictions) do
    stage = fixture.round.stage

    Map.new(predictions, fn pred ->
      {pred.player_id, Scoring.score(pred, fixture, stage).fixture_total}
    end)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/predictex/match_recap_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/match_recap.ex test/predictex/match_recap_test.exs
git commit -m "feat(recap): MatchRecap.points/2 — per-pick fixture points (p4o)"
```

## Task 2: FixtureLive — final score + per-pick points (settled group fixtures)

**Files:**
- Modify: `lib/predictex/tournament.ex:60` (`get_fixture!`)
- Modify: `lib/predictex_web/live/fixture_live.ex`
- Test: `test/predictex_web/live/fixture_live_test.exs`

**Interfaces:**
- Consumes: `MatchRecap.points/2`; `Tournament.get_fixture!(id, preloads)`.
- Produces: assigns `:recap?` (boolean), `:points` (`%{player_id => integer}`); settled header shows the final score; "Everyone's picks" rows show `+N` points.

- [ ] **Step 1: Add a preload arg to `get_fixture!`**

In `lib/predictex/tournament.ex`, replace line 60:

```elixir
def get_fixture!(id, preloads \\ []), do: Repo.get!(Fixture, id) |> Repo.preload(preloads)
```

- [ ] **Step 2: Write the failing LiveView test**

```elixir
# test/predictex_web/live/fixture_live_test.exs — add inside the describe/module, following existing conventions
test "settled group fixture shows the final score and per-pick points", %{conn: conn} do
  {:ok, round} = Tournament.create_round(%{name: "Matchday 1", stage: :group, ordinal: 1})
  past = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.truncate(:second)

  {:ok, fx} =
    Tournament.create_fixture(%{
      external_ref: "recap-1", team1: "Egypt", team2: "Belgium",
      status: :completed, home_goals: 2, away_goals: 1, kickoff_at: past, round_id: round.id
    })

  viewer = player_fixture(%{display_name: "Zoe"})
  {:ok, _} = Predictions.create_prediction(%{player_id: viewer.id, fixture_id: fx.id, home_goals: 2, away_goals: 1})

  {:ok, _lv, html} = conn |> log_in_player(viewer) |> live(~p"/fixtures/#{fx.id}")

  assert html =~ "2–1"                       # final score in header (en-dash)
  assert html =~ "Zoe"
  assert html =~ "+"                          # a points annotation rendered
end
```

(Imports/aliases `Tournament`, `Predictions`, `player_fixture`, `log_in_player` already present in this file.)

- [ ] **Step 3: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex_web/live/fixture_live_test.exs`
Expected: FAIL — final score `2–1` not rendered for a non-live fixture.

- [ ] **Step 4: Preload round + compute recap assigns**

In `lib/predictex_web/live/fixture_live.ex`:

`mount/3` — preload round:
```elixir
fixture = Tournament.get_fixture!(id, :round)
```
`handle_info/2` — preload round on reload too:
```elixir
new = Tournament.get_fixture!(old.id, :round)
```

Add `alias Predictex.MatchRecap` to the alias line, and at the end of `load_all/2` add the recap assigns:

```elixir
defp load_all(socket, fixture) do
  now = DateTime.utc_now()
  locked? = Predictions.locked?(fixture, now)
  viewer_id = socket.assigns.current_scope.player.id
  h = fixture.live_home_goals || 0
  a = fixture.live_away_goals || 0
  recap? = fixture.status == :completed and fixture.round.stage == :group
  picks = if(locked?, do: Predictions.list_fixture_predictions(fixture.id), else: [])

  socket
  |> assign(:fixture, fixture)
  |> assign(:viewer_id, viewer_id)
  |> assign(:picks_visible?, locked?)
  |> assign(:picks, picks)
  |> assign(:recap?, recap?)
  |> assign(:points, if(recap?, do: MatchRecap.points(fixture, picks), else: %{}))
  |> assign(:scenarios, if(fixture.is_live, do: Buzz.scenarios_with_deltas(fixture.id, h, a), else: []))
  |> assign(:headlines, if(fixture.is_live, do: Buzz.headlines(fixture.id, h, a, viewer_id), else: []))
end
```

- [ ] **Step 5: Render the final score and points**

In the match-header block, the score `<span>` currently shows only when `@fixture.is_live`, and a `"v"` shows otherwise. Change so a settled recap shows the final score:

```heex
<span
  :if={@fixture.is_live or @recap?}
  class="font-score text-4xl font-extrabold tabular-nums sm:text-5xl"
>
  {@fixture.is_live && @fixture.live_home_goals || @fixture.home_goals}<span class="px-1 text-base-content/30">–</span>{@fixture.is_live && @fixture.live_away_goals || @fixture.away_goals}
</span>
<span :if={not @fixture.is_live and not @recap?} class="px-2 text-base-content/40">v</span>
```

In the "Everyone's picks" row, after the booster `<span>`, append the points when in recap:

```heex
<span
  :if={@recap?}
  class="rounded bg-success/15 px-1.5 py-0.5 text-[10px] font-bold text-success"
>
  +{Map.get(@points, p.player_id, 0)}
</span>
```

- [ ] **Step 6: Run the test + full gate**

Run: `mise exec -- mix test test/predictex_web/live/fixture_live_test.exs` → PASS
Run: `mise exec -- mix precommit` → all green.

- [ ] **Step 7: Commit**

```bash
git add lib/predictex/tournament.ex lib/predictex_web/live/fixture_live.ex test/predictex_web/live/fixture_live_test.exs
git commit -m "feat(recap): settled group fixtures show final score + per-pick points (p4o slice 1)"
```

> **SLICE 1 is now independently shippable** (no migration). Stop here for a review/deploy boundary if desired before starting slice 2.

---

# SLICE 2 — Goal breakdown

## Task 3: `Results.Openfootball.goal_events/1` + persist on parse

**Files:**
- Modify: `lib/predictex/results/openfootball.ex`
- Test: `test/predictex/results/openfootball_test.exs`

**Interfaces:**
- Produces: `Results.Openfootball.goal_events(match_map) :: [%{side, type, player, minute}]`; `parse_match/1` output gains `:goals` (same list).

- [ ] **Step 1: Write the failing test**

```elixir
# test/predictex/results/openfootball_test.exs — add a describe block
describe "goal_events/1" do
  test "decodes regular/penalty/own-goal with side, scorer, and stoppage minute" do
    m = %{
      "goals1" => [
        %{"name" => "Salah", "minute" => 16, "penalty" => true},
        %{"name" => "Aguerd", "minute" => "90+2", "owngoal" => true}
      ],
      "goals2" => [%{"name" => "Lukaku", "minute" => 73}]
    }

    assert [g1, g2, g3] = Predictex.Results.Openfootball.goal_events(m)
    assert g1 == %{side: :home, type: :penalty, player: "Salah", minute: "16"}
    assert g2 == %{side: :away, type: :regular, player: "Lukaku", minute: "73"}
    assert g3 == %{side: :home, type: :own_goal, player: "Aguerd", minute: "90+2"}
  end

  test "an empty match yields no goals" do
    assert Predictex.Results.Openfootball.goal_events(%{}) == []
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/predictex/results/openfootball_test.exs`
Expected: FAIL — `goal_events/1` undefined.

- [ ] **Step 3: Implement `goal_events/1` and wire into `parse_match/1`**

In `lib/predictex/results/openfootball.ex`, add `goals: goal_events(m)` to the `parse_match/1` output map, and add the public function + helpers (reuse the existing `split_minute/1`, `zero/1`, `order/2`):

```elixir
@doc """
All goals of a match as `[%{side, type, player, minute}]`, ordered by elapsed minute.
Side is the array the goal sits in (own goals included — the beneficiary side). Type is
`:penalty` / `:own_goal` / `:regular`. Minute is a display string ("16", "90+2").
"""
@spec goal_events(map()) :: [map()]
def goal_events(m) when is_map(m) do
  events =
    Enum.map(Map.get(m, "goals1", []) || [], &goal_event(&1, :home)) ++
      Enum.map(Map.get(m, "goals2", []) || [], &goal_event(&1, :away))

  events
  |> Enum.sort_by(& &1.__order)
  |> Enum.map(&Map.delete(&1, :__order))
end

def goal_events(_), do: []

defp goal_event(goal, side) when is_map(goal) do
  %{
    side: side,
    type: goal_type(goal),
    player: Map.get(goal, "name"),
    minute: minute_string(Map.get(goal, "minute"), Map.get(goal, "offset")),
    __order: order(Map.get(goal, "minute"), Map.get(goal, "offset"))
  }
end

defp goal_type(%{"owngoal" => true}), do: :own_goal
defp goal_type(%{"penalty" => true}), do: :penalty
defp goal_type(_), do: :regular

defp minute_string(minute, offset) do
  {base, off} = order(minute, offset)
  if off > 0, do: "#{base}+#{off}", else: "#{base}"
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mise exec -- mix test test/predictex/results/openfootball_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/results/openfootball.ex test/predictex/results/openfootball_test.exs
git commit -m "feat(recap): Openfootball.goal_events/1 + :goals on parse_match (p4o)"
```

## Task 4: Persist `goals` — embed + migration + ingest

**Files:**
- Modify: `lib/predictex/tournament/fixture.ex`
- Create: `priv/repo/migrations/<ts>_add_goals_to_fixtures.exs`
- Modify: `lib/predictex/results/ingest.ex`
- Test: `test/predictex/results/ingest_test.exs`

**Interfaces:**
- Produces: `fixtures.goals` — `embeds_many :goals` of `%Fixture.Goal{side, type, player, minute}`; refreshed on every ResultSync.

- [ ] **Step 1: Add the embed to the schema**

In `lib/predictex/tournament/fixture.ex`, inside `schema "fixtures" do … end`, after the `field`s and before `belongs_to`:

```elixir
embeds_many :goals, Goal, on_replace: :delete do
  field :side, Ecto.Enum, values: [:home, :away]
  field :type, Ecto.Enum, values: [:penalty, :own_goal, :regular]
  field :player, :string
  field :minute, :string
end
```

In `changeset/2`, after the `cast(attrs, @castable)` pipe, add:

```elixir
|> cast_embed(:goals, with: &goal_changeset/2)
```

And add the embed changeset helper (uses `import Ecto.Changeset`, already imported):

```elixir
defp goal_changeset(goal, attrs) do
  goal
  |> cast(attrs, [:side, :type, :player, :minute])
  |> validate_required([:side, :type])
end
```

- [ ] **Step 2: Create the migration**

Run: `mise exec -- mix ecto.gen.migration add_goals_to_fixtures`
Then set its body:

```elixir
defmodule Predictex.Repo.Migrations.AddGoalsToFixtures do
  use Ecto.Migration

  def change do
    alter table(:fixtures) do
      add :goals, {:array, :map}, default: []
    end
  end
end
```

Run: `mise exec -- mix ecto.migrate`
Expected: migration runs clean.

- [ ] **Step 3: Write the failing ingest test**

```elixir
# test/predictex/results/ingest_test.exs — add a test (follow existing setup for a decoded doc)
test "persists goal events and refreshes them on re-sync" do
  doc = %{
    "matches" => [
      %{
        "round" => "Matchday 1", "team1" => "Egypt", "team2" => "Belgium",
        "date" => "2026-06-20", "time" => "18:00",
        "score" => %{"ft" => [2, 1]},
        "goals1" => [%{"name" => "Salah", "minute" => 16, "penalty" => true}],
        "goals2" => [%{"name" => "Lukaku", "minute" => 73}]
      }
    ]
  }

  doc |> Ingest.plan() |> Ingest.commit()
  fx = Repo.get_by!(Fixture, external_ref: "2026-06-20 Egypt v Belgium") |> Repo.preload([])
  assert [%{side: :home, type: :penalty, player: "Salah"}, %{side: :away, type: :regular}] = fx.goals

  # re-sync with an extra goal → overwritten, not duplicated
  doc2 = put_in(doc, ["matches", Access.at(0), "goals2"], [
    %{"name" => "Lukaku", "minute" => 73},
    %{"name" => "Hazard", "minute" => 88}
  ])
  doc2 |> Ingest.plan() |> Ingest.commit()
  fx2 = Repo.get_by!(Fixture, external_ref: "2026-06-20 Egypt v Belgium")
  assert length(fx2.goals) == 3
end
```

(Adjust the `external_ref` to match `Openfootball.ref/3` — `"#{date} #{t1} v #{t2}"`.)

- [ ] **Step 4: Run to verify it fails**

Run: `mise exec -- mix test test/predictex/results/ingest_test.exs`
Expected: FAIL — `goals` not in the plan attrs / not replaced on conflict.

- [ ] **Step 5: Wire goals through the plan + replace-on-conflict**

In `lib/predictex/results/ingest.ex`:
- Add `:goals` to `@replace_on_conflict` (line 26 list).
- In the `plan_fixture` attrs map (around line 78-90), add `goals: fixture.goals` (the parsed match already carries `:goals` from Task 3).

- [ ] **Step 6: Run to verify it passes + gate**

Run: `mise exec -- mix test test/predictex/results/ingest_test.exs` → PASS
Run: `mise exec -- mix precommit` → green.

- [ ] **Step 7: Commit**

```bash
git add lib/predictex/tournament/fixture.ex priv/repo/migrations/*_add_goals_to_fixtures.exs lib/predictex/results/ingest.ex test/predictex/results/ingest_test.exs
git commit -m "feat(recap): persist openfootball goals on the fixture embed (p4o)"
```

## Task 5: `Predictex.Capture.goal_events/1`

**Files:**
- Modify: `lib/predictex/capture.ex`
- Test: `test/predictex/capture_test.exs`

**Interfaces:**
- Produces: `Capture.goal_events(body) :: [%{side, type, player, minute}]` (same unified shape as Task 3). `analyze/1`'s goal list reuses it.

- [ ] **Step 1: Write the failing test (inline FIFA detail body, shape per `fifa-v3-live-api-contract`)**

```elixir
# test/predictex/capture_test.exs
describe "goal_events/1" do
  test "decodes FIFA Goals to the unified shape (Type 1/2/3, side by array, scorer via Players)" do
    body = %{
      "HomeTeam" => %{
        "Players" => [%{"IdPlayer" => "p1", "PlayerName" => [%{"Description" => "Salah"}]}],
        "Goals" => [%{"IdPlayer" => "p1", "Minute" => "16'", "Type" => 1}]
      },
      "AwayTeam" => %{
        "Players" => [%{"IdPlayer" => "p2", "PlayerName" => [%{"Description" => "Lukaku"}]}],
        "Goals" => [%{"IdPlayer" => "p2", "Minute" => "73'", "Type" => 2}]
      }
    }

    assert [%{side: :home, type: :penalty, player: "Salah", minute: "16'"},
            %{side: :away, type: :regular, player: "Lukaku", minute: "73'"}] =
             Predictex.Capture.goal_events(body)
  end

  test "a body with no goals yields []" do
    assert Predictex.Capture.goal_events(%{}) == []
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/predictex/capture_test.exs`
Expected: FAIL — `goal_events/1` undefined.

- [ ] **Step 3: Add the public decoder; refactor `goals_from_last_detail/1` to reuse it**

In `lib/predictex/capture.ex`, add:

```elixir
@doc "Decode a FIFA `/detail` body into unified goal events `[%{side, type, player, minute}]`."
@spec goal_events(map()) :: [map()]
def goal_events(body) when is_map(body) do
  players = player_map(body)

  for {team, side} <- [{"HomeTeam", :home}, {"AwayTeam", :away}],
      goal <- get_in(body, [team, "Goals"]) || [] do
    %{
      side: side,
      type: fifa_goal_type(goal["Type"]),
      player: Map.get(players, goal["IdPlayer"]) || goal["IdPlayer"],
      minute: to_string(goal["Minute"])
    }
  end
  |> Enum.sort_by(&minute_key(&1.minute))
end

def goal_events(_), do: []

defp fifa_goal_type(1), do: :penalty
defp fifa_goal_type(3), do: :own_goal
defp fifa_goal_type(_), do: :regular
```

Replace `goals_from_last_detail/1`'s body so the summary reuses the decoder (keeps `analyze/1` behaviour):

```elixir
defp goals_from_last_detail([]), do: []
defp goals_from_last_detail(details), do: goal_events(List.last(details).body)
```

If the summary `format/1` references `g.scorer`/`g.type` string values, update those reads to `g.player` and the new atom `g.type` (search `format` for the goals section).

- [ ] **Step 4: Run to verify it passes + the existing capture summary still works**

Run: `mise exec -- mix test test/predictex/capture_test.exs`
Expected: PASS (new tests + any existing `analyze/summary` tests).

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/capture.ex test/predictex/capture_test.exs
git commit -m "feat(recap): Capture.goal_events/1 (lifted from analyze) (p4o)"
```

## Task 6: `MatchRecap.goals/2` — source select + reconciliation

**Files:**
- Modify: `lib/predictex/match_recap.ex`
- Test: `test/predictex/match_recap_test.exs`

**Interfaces:**
- Consumes: `Capture.goal_events/1`; `fixture.goals` (persisted openfootball embeds), `fixture.home_goals`, `fixture.away_goals`.
- Produces: `MatchRecap.goals(fixture, fifa_body | nil) :: [%{side, type, player, minute}]` — FIFA when it reconciles, else openfootball; `MatchRecap.goal_source(fixture, fifa_body) :: :fifa | :openfootball`.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/predictex/match_recap_test.exs — add
describe "goals/2" do
  defp of_goal(side, type \\ :regular), do: %{side: side, type: type, player: "x", minute: "1"}

  test "uses FIFA goals when their per-side count reconciles with the final score" do
    fx = %{home_goals: 2, away_goals: 1, goals: [of_goal(:home)]}  # openfootball (stale/short)
    fifa = %{
      "HomeTeam" => %{"Players" => [], "Goals" => [%{"Type" => 2, "Minute" => "10'"}, %{"Type" => 1, "Minute" => "20'"}]},
      "AwayTeam" => %{"Players" => [], "Goals" => [%{"Type" => 2, "Minute" => "30'"}]}
    }
    assert MatchRecap.goal_source(fx, fifa) == :fifa
    assert length(MatchRecap.goals(fx, fifa)) == 3
  end

  test "falls back to openfootball goals when FIFA does not reconcile (capture gap)" do
    fx = %{home_goals: 2, away_goals: 1,
           goals: [%{side: :home, type: :regular, player: "A", minute: "1"},
                   %{side: :home, type: :penalty, player: "B", minute: "2"},
                   %{side: :away, type: :regular, player: "C", minute: "3"}]}
    fifa = %{"HomeTeam" => %{"Players" => [], "Goals" => [%{"Type" => 2, "Minute" => "10'"}]},
             "AwayTeam" => %{"Players" => [], "Goals" => []}}  # 1-0, doesn't match 2-1
    assert MatchRecap.goal_source(fx, fifa) == :openfootball
    assert length(MatchRecap.goals(fx, fifa)) == 3
  end

  test "falls back to openfootball when there is no FIFA body" do
    fx = %{home_goals: 0, away_goals: 0, goals: []}
    assert MatchRecap.goal_source(fx, nil) == :openfootball
    assert MatchRecap.goals(fx, nil) == []
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/predictex/match_recap_test.exs`
Expected: FAIL — `goals/2`/`goal_source/2` undefined.

- [ ] **Step 3: Implement source selection + reconciliation**

In `lib/predictex/match_recap.ex` add `alias Predictex.Capture` and:

```elixir
@doc """
Goal breakdown for the recap: the FIFA-capture goals when they reconcile with the final
score (guards against a short/incomplete capture), otherwise the persisted openfootball
goals. Both are normalised to `[%{side, type, player, minute}]`.
"""
@spec goals(map(), map() | nil) :: [map()]
def goals(fixture, fifa_body) do
  case fifa_goals_if_reconciled(fixture, fifa_body) do
    nil -> openfootball_goals(fixture)
    fifa -> fifa
  end
end

@doc "Which source `goals/2` selected — `:fifa` or `:openfootball`."
@spec goal_source(map(), map() | nil) :: :fifa | :openfootball
def goal_source(fixture, fifa_body) do
  if fifa_goals_if_reconciled(fixture, fifa_body), do: :fifa, else: :openfootball
end

defp fifa_goals_if_reconciled(_fixture, nil), do: nil

defp fifa_goals_if_reconciled(fixture, body) do
  goals = Capture.goal_events(body)
  if reconciles?(goals, fixture), do: goals, else: nil
end

# Embedded %Goal{} structs → the plain unified shape the LiveView consumes.
defp openfootball_goals(fixture) do
  Enum.map(fixture.goals, &%{side: &1.side, type: &1.type, player: &1.player, minute: &1.minute})
end

# Per-side goal count (side is the scoring side incl. own-goal beneficiary) == final score.
# Count check only — not a content match.
defp reconciles?(goals, fixture) do
  Enum.count(goals, &(&1.side == :home)) == (fixture.home_goals || 0) and
    Enum.count(goals, &(&1.side == :away)) == (fixture.away_goals || 0)
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mise exec -- mix test test/predictex/match_recap_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/match_recap.ex test/predictex/match_recap_test.exs
git commit -m "feat(recap): MatchRecap.goals/2 — FIFA-if-reconciles, else openfootball (p4o)"
```

## Task 7: FixtureLive — goal-breakdown section

**Files:**
- Modify: `lib/predictex_web/live/fixture_live.ex`
- Test: `test/predictex_web/live/fixture_live_test.exs`

**Interfaces:**
- Consumes: `MatchRecap.goals/2`; `Capture.list_snapshots/1`.
- Produces: assign `:goals`; a goal-breakdown section visible when `@recap?`.

- [ ] **Step 1: Write the failing test (openfootball-source path)**

```elixir
# test/predictex_web/live/fixture_live_test.exs — add
test "settled group fixture renders a goal breakdown", %{conn: conn} do
  {:ok, round} = Tournament.create_round(%{name: "Matchday 1", stage: :group, ordinal: 1})
  past = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.truncate(:second)

  {:ok, fx} =
    Tournament.create_fixture(%{
      external_ref: "recap-2", team1: "Egypt", team2: "Belgium",
      status: :completed, home_goals: 1, away_goals: 0, kickoff_at: past, round_id: round.id,
      goals: [%{side: :home, type: :penalty, player: "Salah", minute: "16"}]
    })

  viewer = player_fixture(%{display_name: "Zoe"})
  {:ok, _lv, html} = conn |> log_in_player(viewer) |> live(~p"/fixtures/#{fx.id}")

  assert html =~ "Salah"
  assert html =~ "16"
  assert html =~ "pen"        # penalty marker
end
```

(`create_fixture` accepts `goals` because the changeset now `cast_embed`s it.)

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/predictex_web/live/fixture_live_test.exs`
Expected: FAIL — "Salah" not rendered.

- [ ] **Step 3: Load goals at the edge + render**

In `lib/predictex_web/live/fixture_live.ex`, add `alias Predictex.Capture`. In `load_all/2`, compute the goals assign when in recap:

```elixir
|> assign(:goals, if(recap?, do: recap_goals(fixture), else: []))
```

Add the edge reader + a label helper:

```elixir
defp recap_goals(fixture) do
  body =
    if fixture.fifa_match_id do
      fixture.fifa_match_id
      |> Predictex.Capture.list_snapshots()
      |> Enum.filter(&(&1.endpoint == "detail" and is_map(&1.body)))
      |> List.last()
      |> case do
        nil -> nil
        snap -> snap.body
      end
    end

  MatchRecap.goals(fixture, body)
end

defp goal_label(:penalty), do: " (pen)"
defp goal_label(:own_goal), do: " (OG)"
defp goal_label(:regular), do: ""
```

Add a breakdown section in the template, after "Everyone's picks" (or below the header), guarded by `@recap?`:

```heex
<section :if={@recap?} class="space-y-2">
  <h2 class="px-1 text-sm font-extrabold uppercase tracking-wider text-base-content/60">Goals</h2>
  <div :if={@goals == []} class="rounded-box bg-base-100 p-4 text-sm text-base-content/50 shadow">
    No goals.
  </div>
  <ul :if={@goals != []} class="divide-y divide-base-200 rounded-box bg-base-100 px-3 shadow">
    <li :for={g <- @goals} class="flex items-center justify-between py-2 text-sm">
      <span class="truncate">
        <span class="font-score text-base-content/50">{g.minute}'</span>
        {g.player}{goal_label(g.type)}
      </span>
      <span class="text-xs text-base-content/50">
        {(g.side == :home && @fixture.team1) || @fixture.team2}
      </span>
    </li>
  </ul>
</section>
```

- [ ] **Step 4: Run the test + a FIFA-source assertion**

Run: `mise exec -- mix test test/predictex_web/live/fixture_live_test.exs`
Expected: PASS.

Add one more test exercising the FIFA path (insert a reconciling `Capture` snapshot for the fixture's `fifa_match_id` and assert the FIFA scorer name renders); run it.

- [ ] **Step 5: Full gate**

Run: `mise exec -- mix precommit`
Expected: all green (≈ +12 tests over the slice).

- [ ] **Step 6: Commit**

```bash
git add lib/predictex_web/live/fixture_live.ex test/predictex_web/live/fixture_live_test.exs
git commit -m "feat(recap): goal-breakdown section on settled group fixtures (p4o slice 2)"
```

---

## Self-Review notes (already reconciled)

- **Spec coverage:** points-per-player (Task 1-2), goals column + ingest (Task 3-4), FIFA decoder (Task 5), reconciliation/source (Task 6), UI (Task 2 + Task 7), group-stage scope (`recap?` guard), tests across all units. ✓
- **Round-bonus caveat:** per-fixture points label is `+N` and the recap never claims it sums to the leaderboard total (spec note). ✓
- **Reconciliation is a count check**, not content — comment says so; tests cover reconcile/gap/no-body. ✓
- **Embedded typed schema** retained (Ecto.Enum side/type) per spec + advisor; LiveView consumes the plain unified shape via `MatchRecap`. ✓
- **Knockout/ET out of scope** — `recap?` requires `round.stage == :group`; deferred work captured in the spec. ✓
