# Knockout Game — Phase 0 Spike + Phase 1 Foundation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let members natively enter their knockout predictions (scoreline + first-team + one booster/round) on `/predictions`, and show a re-based knockout-only leaderboard alongside the cumulative one — plus a research spike that de-risks the follow-up plan (player picker + FIFA result authority).

**Architecture:** Reuse the existing pure `Standings.rank/2` over a knockout-only fixture slice for the second board; add a lockout-aware member write path that reuses the admin sparse-grid + booster semantics; make `MyPredictionsLive` editable for the open knockout round only (group rounds + locked fixtures stay read-only). No new schema, no FIFA-feed changes in this plan — those land in the follow-up after the spike.

**Tech Stack:** Elixir 1.20.1 / OTP 28 (via mise), Phoenix 1.8 LiveView, Ecto/Postgres, ExUnit.

## Global Constraints

- Always run mix via **`mise exec -- mix …`** (plain `mix` is the wrong version).
- The gate is **`mix precommit`** (compile --warnings-as-errors, deps.unlock --check-unused, format --check-formatted, credo --strict, test) — must pass before each commit; lefthook runs it automatically on staged `*.{ex,exs}`.
- **Commit autonomously when green; never `git push` or tag** (push/deploy are the user's explicit call). Never `git commit --no-verify`.
- **Knockout-only scope:** native entry and the second board concern **knockout-stage** rounds only (`round.stage == :knockout`). The group stage stays frozen and read-only.
- **FT-only knockout scoring** (`rules.md` §9.4) is unchanged in this plan (no scoring-engine edits here).
- Tests: `Predictex.DataCase` (DB, `async: true` where possible); `PredictexWeb.ConnCase` for LiveView (this file is `async: false`, matching `fixture_live_test.exs`). Use real openfootball/FIFA-shaped strings in fixtures, never invented data.

---

### Task 0: Phase 0 Spike — FIFA squad-roster & goal-period reconnaissance

Pure investigation. Produces a findings note that the follow-up plan (picker + result authority) depends on. No production code, no TDD.

**Files:**
- Create: `docs/superpowers/research/2026-06-22-knockout-fifa-feed-spike.md`

- [ ] **Step 1: Confirm the squad/scorer id-join structure from a banked sample**

The contract is already verified in code (`lib/predictex/capture.ex:159` `player_map/1`; `goal_events/1:146`). Re-confirm against a banked baseline body that the per-team `Players` array carries `IdPlayer` + `PlayerName`/`ShortName`, and that `Goals[].IdPlayer` resolves against it.

Run:
```bash
ls tmp/fifa-capture/baseline/ 2>/dev/null
# Inspect one body for the Players roster + Goals[].IdPlayer/Period/Minute fields:
mise exec -- elixir -e 'IO.inspect(File.read!("tmp/fifa-capture/baseline/<a-file>.json") |> Jason.decode!() |> Map.take(["HomeTeam","AwayTeam"]), limit: :infinity)' 2>/dev/null | head -60
```
Record: do `Players[]` entries have `IdPlayer`? Do `Goals[]` have `IdPlayer`, `Period`, `Minute`? What `Period` value(s) appear for regulation goals? (ET period value will be unknown until 28 Jun — note that.)

- [ ] **Step 2: Determine pre-match availability of the `Players` roster**

The picker needs the squad **before kickoff** (days ahead for a KO round). Fetch the `/detail` endpoint for an **upcoming** fixture and check whether `HomeTeam.Players` / `AwayTeam.Players` are populated pre-match. Endpoint pattern (from the `fifa-v3-live-api-contract` memory): `GET https://api.fifa.com/api/v3/live/football/17/285023/{stage}/{match}`.

Run (if egress is available; otherwise ask the user to run it and paste the result):
```bash
# pick an upcoming fixture's stage+match id (from Fifa.Reference rounds.json), then:
curl -s 'https://api.fifa.com/api/v3/live/football/17/285023/<stage>/<match>' \
  | mise exec -- elixir -e 'b=IO.read(:stdio,:eof)|>Jason.decode!(); IO.inspect({length(get_in(b,["HomeTeam","Players"])||[]), length(get_in(b,["AwayTeam","Players"])||[])})'
```
Record the roster sizes pre-match. **This is the gate for the v1 picker** (spec decision 8): rosters present pre-match → picker ships in the follow-up's v1; absent → picker is a fast-follow (free-text or post-kickoff) and the follow-up plan reflects that.

- [ ] **Step 3: Write the findings note**

Write `docs/superpowers/research/2026-06-22-knockout-fifa-feed-spike.md` covering: (a) confirmed squad/scorer `IdPlayer` join (yes/no + structure), (b) pre-match roster availability (sizes + verdict for the picker), (c) goal `Period`/`Minute` structure for regulation filtering and the open ET-period unknown, (d) explicit recommendation for the follow-up plan's picker scope and regulation-filter approach. Cross-link the design spec.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/research/2026-06-22-knockout-fifa-feed-spike.md
git commit -m "research(spike): FIFA knockout feed — squad roster availability + goal period structure"
```

---

### Task 1: `Standings.knockout_leaderboard/0` — the re-based knockout-only board

**Files:**
- Modify: `lib/predictex/standings.ex` (add the function near `leaderboard/0`, line ~26)
- Test: `test/predictex/standings_test.exs`

**Interfaces:**
- Consumes: existing private `load_ranking_inputs/0` and pure `rank/2`.
- Produces: `Standings.knockout_leaderboard/0 :: [%{player_id, name, fixtures_total, round_bonus_total, total, bonus_by_round, breakdown}]` — same row shape as `leaderboard/0`, but scored over knockout-stage fixtures only (everyone starts from 0 at the first knockout round).

- [ ] **Step 1: Write the failing test**

In `test/predictex/standings_test.exs`, add (adapt the setup helpers already in that file for rounds/fixtures/players/predictions):

```elixir
describe "knockout_leaderboard/0 (re-based, knockout-only)" do
  test "ranks only knockout-stage points, ignoring group fixtures" do
    {:ok, group} = Tournament.create_round(%{name: "Group 1", stage: :group, ordinal: 1})
    {:ok, ko} = Tournament.create_round(%{name: "Round of 32", stage: :knockout, ordinal: 4})

    {:ok, gfx} =
      Tournament.create_fixture(%{external_ref: "g1", team1: "A", team2: "B",
        round_id: group.id, status: :completed, home_goals: 1, away_goals: 0})

    {:ok, kfx} =
      Tournament.create_fixture(%{external_ref: "k1", team1: "C", team2: "D",
        round_id: ko.id, status: :completed, home_goals: 2, away_goals: 1})

    alice = player_fixture(%{display_name: "Alice"})

    # Exact group pick (would be +30 on the overall board) and exact KO pick (+30 KO-only).
    {:ok, _} = Predictions.create_prediction(%{player_id: alice.id, fixture_id: gfx.id, home_goals: 1, away_goals: 0})
    {:ok, _} = Predictions.admin_upsert_prediction(%{player_id: alice.id, fixture_id: kfx.id, home_goals: 2, away_goals: 1})

    [row] = Standings.knockout_leaderboard()
    assert row.player_id == alice.id
    # Knockout board excludes the group fixture entirely: only the KO pick counts.
    assert row.fixtures_total == 30
    assert Enum.all?(row.breakdown, fn b -> b.fixture_id == kfx.id end)
  end

  test "a player with only group points sits at 0 on the knockout board" do
    {:ok, group} = Tournament.create_round(%{name: "Group 1", stage: :group, ordinal: 1})
    {:ok, gfx} =
      Tournament.create_fixture(%{external_ref: "g2", team1: "A", team2: "B",
        round_id: group.id, status: :completed, home_goals: 1, away_goals: 0})
    bob = player_fixture(%{display_name: "Bob"})
    {:ok, _} = Predictions.create_prediction(%{player_id: bob.id, fixture_id: gfx.id, home_goals: 1, away_goals: 0})

    [row] = Standings.knockout_leaderboard()
    assert row.total == 0
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex/standings_test.exs -v`
Expected: FAIL — `function Predictex.Standings.knockout_leaderboard/0 is undefined`.

- [ ] **Step 3: Implement the function**

In `lib/predictex/standings.ex`, after `leaderboard/0`:

```elixir
@doc """
Re-based knockout-only standings: ranks every player over knockout-stage fixtures only,
so the board starts from 0 at the first knockout round. Reuses the pure `rank/2`, so
booster, risky/cohort and per-round bonus all apply within the knockout stage.
"""
def knockout_leaderboard do
  {players, fixtures} = load_ranking_inputs()
  knockout = Enum.filter(fixtures, &(&1.round.stage == :knockout))
  rank(players, knockout)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/predictex/standings_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/standings.ex test/predictex/standings_test.exs
git commit -m "feat(standings): knockout_leaderboard/0 — re-based knockout-only board"
```

---

### Task 2: Surface both boards on `/` (Overall / Knockout toggle)

**Files:**
- Modify: `lib/predictex_web/live/leaderboard_live.ex`
- Test: `test/predictex_web/live/leaderboard_live_test.exs`

**Interfaces:**
- Consumes: `Standings.leaderboard/0` (Task pre-existing) and `Standings.knockout_leaderboard/0` (Task 1).
- Produces: a `"select_board"` LiveView event toggling `@board` between `:overall` and `:knockout`; the rendered standings (`@standings`) follow the selection.

- [ ] **Step 1: Write the failing test**

In `test/predictex_web/live/leaderboard_live_test.exs` (create if absent; use `PredictexWeb.ConnCase`, `import Phoenix.LiveViewTest`, `import Predictex.AccountsFixtures`):

```elixir
test "toggles between the overall and knockout boards", %{conn: conn} do
  {:ok, group} = Predictex.Tournament.create_round(%{name: "Group 1", stage: :group, ordinal: 1})
  {:ok, ko} = Predictex.Tournament.create_round(%{name: "Round of 32", stage: :knockout, ordinal: 4})
  {:ok, gfx} = Predictex.Tournament.create_fixture(%{external_ref: "g", team1: "A", team2: "B", round_id: group.id, status: :completed, home_goals: 1, away_goals: 0})
  {:ok, kfx} = Predictex.Tournament.create_fixture(%{external_ref: "k", team1: "C", team2: "D", round_id: ko.id, status: :completed, home_goals: 2, away_goals: 1})
  gonly = player_fixture(%{display_name: "GroupOnly"})
  both = player_fixture(%{display_name: "BothRounds"})
  {:ok, _} = Predictex.Predictions.create_prediction(%{player_id: gonly.id, fixture_id: gfx.id, home_goals: 1, away_goals: 0})
  {:ok, _} = Predictex.Predictions.admin_upsert_prediction(%{player_id: both.id, fixture_id: kfx.id, home_goals: 2, away_goals: 1})

  {:ok, lv, html} = live(conn, ~p"/")
  # Default board = overall: GroupOnly (30) leads.
  assert html =~ "GroupOnly"

  # Switch to knockout: only BothRounds has knockout points; GroupOnly sits at 0.
  html = lv |> element("button", "Knockout") |> render_click()
  assert html =~ "BothRounds"
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex_web/live/leaderboard_live_test.exs -v`
Expected: FAIL — no "Knockout" toggle button / event.

- [ ] **Step 3: Implement the toggle**

In `leaderboard_live.ex` `mount/3`, load both boards and default to overall:

```elixir
def mount(_params, _session, socket) do
  overall = Standings.leaderboard()
  knockout = Standings.knockout_leaderboard()

  {:ok,
   socket
   |> assign(:page_title, "Leaderboard")
   |> assign(:completed, Tournament.completed_fixture_count())
   |> assign(:board, :overall)
   |> assign(:overall, overall)
   |> assign(:knockout, knockout)
   |> assign(:standings, overall)
   |> assign(:whatsapp_text, whatsapp_text(overall))
   |> assign(:live_fixtures, Tournament.list_live_fixtures())}
end

@impl true
def handle_event("select_board", %{"board" => board}, socket) do
  board = String.to_existing_atom(board)
  standings = if board == :knockout, do: socket.assigns.knockout, else: socket.assigns.overall

  {:noreply,
   socket
   |> assign(:board, board)
   |> assign(:standings, standings)
   |> assign(:whatsapp_text, whatsapp_text(standings))}
end
```

In `render/1`, add a toggle above the standings (after the header `</div>` block, before the live section). Knockout board only offered once a knockout fixture exists, to avoid an empty board pre-R32:

```heex
<div :if={@knockout != []} class="flex gap-2">
  <button
    phx-click="select_board"
    phx-value-board="overall"
    class={["rounded-full px-3 py-1 text-xs font-bold",
      (@board == :overall && "bg-primary text-primary-content") || "bg-base-200 text-base-content/70"]}
  >
    Overall
  </button>
  <button
    phx-click="select_board"
    phx-value-board="knockout"
    class={["rounded-full px-3 py-1 text-xs font-bold",
      (@board == :knockout && "bg-primary text-primary-content") || "bg-base-200 text-base-content/70"]}
  >
    Knockout
  </button>
</div>
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/predictex_web/live/leaderboard_live_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/predictex_web/live/leaderboard_live.ex test/predictex_web/live/leaderboard_live_test.exs
git commit -m "feat(leaderboard): Overall/Knockout board toggle on /"
```

---

### Task 3: Lockout-aware member write path

**Files:**
- Modify: `lib/predictex/predictions.ex` (add `save_round_predictions/4` near `admin_save_round_predictions/3`, line ~103)
- Test: `test/predictex/predictions_test.exs`

**Interfaces:**
- Consumes: existing private `save_round_row/3`, `clear_round_booster/4`-style booster handling, `locked?/2`, and the `Prediction` schema.
- Produces: `Predictions.save_round_predictions(player_id, round_id, rows, now \\ DateTime.utc_now()) :: {:ok, results_map} | {:error, {:booster_on_blank, results_map}}` — the member-facing sibling of `admin_save_round_predictions/3`. Each `row` is `%{fixture_id, home_goals, away_goals, first_scorer_side, booster}`. **Locked fixtures (kickoff passed) are immutable**: their rows are dropped from the save with result `:locked`, and the up-front booster clear only touches *unlocked* fixtures so a booster already committed to a locked fixture is preserved.

- [ ] **Step 1: Write the failing test**

In `test/predictex/predictions_test.exs`, add:

```elixir
describe "save_round_predictions/4 (member, lockout-aware)" do
  setup %{round: round} do
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
    open = fixture!(round, %{kickoff_at: future})
    locked = fixture!(round, %{kickoff_at: past})
    %{open: open, locked: locked}
  end

  test "saves picks for unlocked fixtures", %{round: round, player: player, open: open} do
    rows = [%{fixture_id: open.id, home_goals: 2, away_goals: 1, booster: false}]
    assert {:ok, results} = Predictions.save_round_predictions(player.id, round.id, rows)
    assert results[open.id] == :upserted
    assert Predictions.get_player_fixture_prediction(player.id, open.id).home_goals == 2
  end

  test "refuses to write a locked fixture", %{round: round, player: player, locked: locked} do
    rows = [%{fixture_id: locked.id, home_goals: 9, away_goals: 9, booster: false}]
    assert {:ok, results} = Predictions.save_round_predictions(player.id, round.id, rows)
    assert results[locked.id] == :locked
    assert Predictions.get_player_fixture_prediction(player.id, locked.id) == nil
  end

  test "a booster on a locked fixture is preserved when other rows save", %{round: round, player: player, open: open, locked: locked} do
    # Pre-existing booster on the (now) locked fixture, written while it was open.
    {:ok, _} = Predictions.admin_upsert_prediction(%{player_id: player.id, fixture_id: locked.id, home_goals: 1, away_goals: 0, booster: true})

    rows = [%{fixture_id: open.id, home_goals: 0, away_goals: 0, booster: false}]
    assert {:ok, _} = Predictions.save_round_predictions(player.id, round.id, rows)

    # The locked fixture keeps its booster — the member can't move it.
    assert Predictions.get_player_fixture_prediction(player.id, locked.id).booster == true
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex/predictions_test.exs -v`
Expected: FAIL — `function Predictex.Predictions.save_round_predictions/4 is undefined`.

- [ ] **Step 3: Implement the write path**

In `lib/predictex/predictions.ex`:

```elixir
@doc """
Member-facing round save (the lockout-aware sibling of `admin_save_round_predictions/3`).

Locked fixtures (kickoff passed) are immutable: their rows are not written (result
`:locked`), and the up-front booster clear only touches unlocked fixtures, so a booster
already committed to a locked fixture is preserved. Otherwise mirrors the admin path:
sparse-grid upsert with the booster-on-blank guard.
"""
def save_round_predictions(player_id, round_id, rows, now \\ DateTime.utc_now())
    when is_list(rows) do
  fixtures = Map.new(Repo.all(from f in Fixture, where: f.round_id == ^round_id), &{&1.id, &1})
  {locked, open} = Enum.split_with(rows, &locked?(Map.get(fixtures, &1.fixture_id), now))

  Repo.transaction(fn ->
    open_ids = Enum.map(open, & &1.fixture_id)

    # Clear boosters only among the unlocked fixtures being (re)saved.
    from(p in Prediction,
      where: p.player_id == ^player_id and p.round_id == ^round_id and p.fixture_id in ^open_ids
    )
    |> Repo.update_all(set: [booster: false])

    saved = Enum.reduce(open, %{}, fn row, acc ->
      Map.put(acc, row.fixture_id, save_round_row(player_id, round_id, row))
    end)

    results = Enum.reduce(locked, saved, fn row, acc -> Map.put(acc, row.fixture_id, :locked) end)

    if Enum.any?(results, fn {_id, r} -> r == {:error, :booster_on_blank} end) do
      Repo.rollback({:booster_on_blank, results})
    else
      results
    end
  end)
end
```

`locked?/2` already returns `false` for a `nil` fixture's `kickoff_at`; guard a missing fixture as not-locked so an unknown id flows to `save_round_row` and surfaces a normal changeset error rather than crashing. (`locked?(nil, _now)` — add a `defp`-level guard if `Fixture` struct match is required: the existing `locked?(%Fixture{kickoff_at: nil}, _)` clause does not match `nil`; add `def locked?(nil, _now), do: false` above it.)

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/predictex/predictions_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/predictions.ex test/predictex/predictions_test.exs
git commit -m "feat(predictions): lockout-aware member save_round_predictions/4"
```

---

### Task 4: Editable `/predictions` for the open knockout round (scoreline + first-team + booster)

**Files:**
- Modify: `lib/predictex_web/live/my_predictions_live.ex`
- Test: `test/predictex_web/live/my_predictions_live_test.exs`

**Interfaces:**
- Consumes: `Predictions.save_round_predictions/4` (Task 3), `Predictions.list_player_predictions/1`, `Tournament.round_open?/1`, the `Dashboard` read model already in `mount/3`.
- Produces: a `"save_round"` LiveView event that reads the submitted grid for the open knockout round and persists it via the member write path, then refreshes the dashboard.

- [ ] **Step 1: Write the failing test**

In `test/predictex_web/live/my_predictions_live_test.exs` (use `PredictexWeb.ConnCase`, `async: false`; `import Phoenix.LiveViewTest`, `import Predictex.AccountsFixtures`):

```elixir
test "member enters native knockout picks on an open knockout round", %{conn: conn} do
  {:ok, ko} = Predictex.Tournament.create_round(%{name: "Round of 32", stage: :knockout, ordinal: 4})
  future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
  {:ok, fx} = Predictex.Tournament.create_fixture(%{external_ref: "k1", team1: "Brazil", team2: "Chile", round_id: ko.id, status: :scheduled, kickoff_at: future})
  player = player_fixture(%{display_name: "Member"})

  {:ok, lv, _html} = conn |> log_in_player(player) |> live(~p"/predictions")

  lv
  |> form("#round-entry-#{ko.ordinal}", %{
    "picks" => %{Integer.to_string(fx.id) => %{"home_goals" => "2", "away_goals" => "1", "first_scorer_side" => "home"}}
  })
  |> render_submit()

  pred = Predictex.Predictions.get_player_fixture_prediction(player.id, fx.id)
  assert pred.home_goals == 2 and pred.away_goals == 1
  assert pred.first_scorer_side == :home
end

test "locked group rounds remain read-only (no entry form)", %{conn: conn} do
  {:ok, group} = Predictex.Tournament.create_round(%{name: "Group 1", stage: :group, ordinal: 1})
  past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
  {:ok, _fx} = Predictex.Tournament.create_fixture(%{external_ref: "g1", team1: "A", team2: "B", round_id: group.id, status: :completed, home_goals: 1, away_goals: 0, kickoff_at: past})
  player = player_fixture(%{display_name: "Member"})

  {:ok, _lv, html} = conn |> log_in_player(player) |> live(~p"/predictions")
  refute html =~ "round-entry-1"
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex_web/live/my_predictions_live_test.exs -v`
Expected: FAIL — no `#round-entry-*` form / `save_round` handler.

- [ ] **Step 3: Implement the entry form + handler**

In `my_predictions_live.ex`, add an `editable?/1` helper and a `save_round` handler, and render an entry `<.form>` when the active round is an open knockout round.

Helper (a round is editable iff it's knockout-stage and still open for predictions):
```elixir
defp editable_round?(%{round: %{stage: :knockout}} = active), do: Tournament.round_open?(active.round)
defp editable_round?(_), do: false
```

Handler:
```elixir
@impl true
def handle_event("save_round", %{"picks" => picks}, socket) do
  player_id = socket.assigns.current_scope.player.id
  ordinal = socket.assigns.active_ordinal
  round = Enum.find(socket.assigns.dash.rounds, &(&1.round.ordinal == ordinal)).round

  rows =
    for {fid, attrs} <- picks,
        attrs["home_goals"] not in [nil, ""] and attrs["away_goals"] not in [nil, ""] do
      %{
        fixture_id: String.to_integer(fid),
        home_goals: String.to_integer(attrs["home_goals"]),
        away_goals: String.to_integer(attrs["away_goals"]),
        first_scorer_side: parse_side(attrs["first_scorer_side"]),
        booster: attrs["booster"] == "true"
      }
    end

  case Predictions.save_round_predictions(player_id, round.id, rows) do
    {:ok, _results} -> {:noreply, refresh(socket) |> put_flash(:info, "Picks saved")}
    {:error, {:booster_on_blank, _}} -> {:noreply, put_flash(socket, :error, "Add a score before using your booster")}
  end
end

defp parse_side("home"), do: :home
defp parse_side("away"), do: :away
defp parse_side(_), do: nil
```

Render — inside the `:if={@active}` block, replace the read-only fixture grid with an editable form **when** `editable_round?(@active)`, else keep the existing read-only `fixture_card` grid:
```heex
<.form
  :if={editable_round?(@active)}
  id={"round-entry-#{@active.round.ordinal}"}
  for={%{}}
  phx-submit="save_round"
>
  <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
    <div :for={fx <- @active.fixtures} class="rounded-box bg-base-100 p-4 shadow space-y-2">
      <div class="flex items-center justify-between text-sm font-bold">
        <span>{Flags.flag(fx.fixture.team1)} {fx.fixture.team1}</span>
        <span class="flex items-center gap-1 font-score">
          <input type="number" min="0" name={"picks[#{fx.fixture.id}][home_goals]"}
            value={fx.prediction && fx.prediction.home_goals} class="w-12 rounded border text-center" />
          –
          <input type="number" min="0" name={"picks[#{fx.fixture.id}][away_goals]"}
            value={fx.prediction && fx.prediction.away_goals} class="w-12 rounded border text-center" />
        </span>
        <span>{fx.fixture.team2} {Flags.flag(fx.fixture.team2)}</span>
      </div>
      <div class="flex items-center gap-3 text-xs">
        <span class="text-base-content/60">First to score:</span>
        <label><input type="radio" name={"picks[#{fx.fixture.id}][first_scorer_side]"} value="home"
          checked={fx.prediction && fx.prediction.first_scorer_side == :home} /> {fx.fixture.team1}</label>
        <label><input type="radio" name={"picks[#{fx.fixture.id}][first_scorer_side]"} value="away"
          checked={fx.prediction && fx.prediction.first_scorer_side == :away} /> {fx.fixture.team2}</label>
      </div>
    </div>
  </div>
  <button type="submit" class="btn btn-primary btn-sm mt-3">Save picks</button>
</.form>

<div :if={not editable_round?(@active)} class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
  <.fixture_card
    :for={fx <- @active.fixtures}
    fx={fx}
    stage={@active.round.stage}
    fifa_url={@fifa_url}
    live_cta?={Predictions.cta_window?(fx.fixture, @now)}
    live_path={~p"/fixtures/#{fx.fixture.id}"}
    tz={@tz}
  />
</div>
```

> Note: this assumes the `Dashboard` fixture entry exposes `fx.fixture` and `fx.prediction` (the read model already renders pick-vs-actual, so the member's pick is present). If the field name differs, read `lib/predictex/dashboard.ex` and adjust the `value=`/`checked=` accessors — the form `name=` attributes and the handler are unaffected. The booster control (one radio across the round) is added the same way once the scoreline grid is verified; it submits `picks[<chosen_fixture_id>][booster]=true`.

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/predictex_web/live/my_predictions_live_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Run the full gate and commit**

Run: `mise exec -- mix precommit`
Expected: all green.
```bash
git add lib/predictex_web/live/my_predictions_live.ex test/predictex_web/live/my_predictions_live_test.exs
git commit -m "feat(predictions): editable native entry for the open knockout round"
```

---

## What this plan deliberately defers (follow-up plan, after the spike)

- **Player picker (first-player) + squad ingestion** (`SquadSync` worker, `Prediction.first_scorer_player_id`, id-based scoring) — contingent on Task 0's pre-match-roster finding.
- **FIFA result authority** — bracket auto-populate, regulation-filtered FIFA scoreline + first-scorer, openfootball reconciliation oracle (`Period`-based filter; ET confirmation only possible from 28 Jun).
- **Marking `/import` superseded** under `2ww`.

These get their own plan once Task 0 confirms the squad-roster availability and goal-period structure.

## Self-Review

- **Spec coverage:** native KO entry surface (Task 4) ✓; re-based knockout-only board (Tasks 1–2) ✓; FT-only unchanged ✓; lockout (Task 3) ✓; spike gating the picker/result-authority (Task 0) ✓. Deferred items explicitly listed and traced to the follow-up plan — no silent gaps.
- **Placeholder scan:** the Task-4 render note about `Dashboard` field names is a real, bounded contingency with a concrete fallback (read `dashboard.ex`, adjust accessors), not a "TODO" — acceptable.
- **Type consistency:** `save_round_predictions/4` row shape `%{fixture_id, home_goals, away_goals, first_scorer_side, booster}` is produced identically in Task 4's handler and consumed in Task 3; `knockout_leaderboard/0` row shape matches `leaderboard/0`; `:overall`/`:knockout` board atoms consistent across Task 2.
