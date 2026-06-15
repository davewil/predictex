# Admin Console Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the admin-only console at `/admin` that lets an admin enter predictions on behalf of players (the playability unlock), sync/override results, set cohort percentages, and promote players to admin.

**Architecture:** Three focused sub-route LiveViews (`AdminPredictionsLive`, `AdminFixturesLive`, `AdminPlayersLive`) plus a landing `AdminLive`, all under one `:require_admin` `live_session`. New domain code is small and lives in existing contexts (`Predictions`, `Accounts`); the LiveViews are thin shells that validate form params at the boundary and pass clean, typed maps to context functions. Admin prediction entry bypasses the kickoff lockout and uses a transactional booster-clear so moving a booster cannot trip the non-deferrable `one_booster_per_player_round` unique index.

**Tech Stack:** Elixir 1.20 / OTP 28 (via `mise`), Phoenix 1.8 LiveView, Ecto/Postgres, daisyUI/Tailwind. All `mix` calls are `mise exec -- mix …`.

**Spec:** `docs/superpowers/specs/2026-06-15-admin-console-design.md`

---

## File structure

| File | Responsibility | Action |
|------|----------------|--------|
| `lib/predictex/predictions.ex` | `admin_upsert_prediction/1`, `admin_save_round_predictions/3`, `list_fixture_predictions/1` | Modify |
| `lib/predictex/accounts.ex` | `set_player_admin/2` | Modify |
| `lib/predictex_web/router.ex` | `:require_admin` live_session + 4 routes | Modify |
| `lib/predictex_web/components/layouts.ex` | conditional **Admin** nav link | Modify |
| `lib/predictex_web/live/admin_live.ex` | landing + section nav + shared `admin_nav/1` | Create |
| `lib/predictex_web/live/admin_predictions_live.ex` | by-player / by-fixture entry | Create |
| `lib/predictex_web/live/admin_fixtures_live.ex` | sync + result override + cohort % | Create |
| `lib/predictex_web/live/admin_players_live.ex` | list + promote | Create |
| `test/support/fixtures/accounts_fixtures.ex` | `admin_player_fixture/1` | Modify |
| `test/predictex/predictions_admin_test.exs` | domain tests | Create |
| `test/predictex/accounts_test.exs` | `set_player_admin/2` test | Modify |
| `test/predictex_web/live/admin_live_test.exs` | gate + nav | Create |
| `test/predictex_web/live/admin_predictions_live_test.exs` | entry flow | Create |
| `test/predictex_web/live/admin_fixtures_live_test.exs` | sync/result/cohort | Create |
| `test/predictex_web/live/admin_players_live_test.exs` | promote flow | Create |

Sequencing: Phase 1 (test helper) → Phase 2 (Predictions domain) → Phase 3 (router + gate + landing) → Phase 4 (AdminPredictionsLive — **playability unlock, shippable here**) → Phase 5 (Accounts.set_player_admin) → Phase 6 (AdminFixturesLive) → Phase 7 (AdminPlayersLive).

---

## Phase 1 — Test helper: admin player fixture

### Task 1: `admin_player_fixture/1`

**Files:**
- Modify: `test/support/fixtures/accounts_fixtures.ex`

- [ ] **Step 1: Add the helper** (uses the production promote path)

In `test/support/fixtures/accounts_fixtures.ex`, after `player_fixture/1`, add:

```elixir
  @doc "A confirmed player promoted to admin via the production `Accounts.promote_admin/1` path."
  def admin_player_fixture(attrs \\ %{}) do
    player = player_fixture(attrs)
    Accounts.promote_admin(player.email)
  end
```

- [ ] **Step 2: Verify it compiles**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: compiles clean (no test references it yet; this just guards the syntax).

- [ ] **Step 3: Commit**

```bash
git add test/support/fixtures/accounts_fixtures.ex
git commit -m "test: add admin_player_fixture helper (predictex-a02)"
```

---

## Phase 2 — Predictions domain (admin entry, no lockout)

### Task 2: `admin_upsert_prediction/1` — insert path

**Files:**
- Modify: `lib/predictex/predictions.ex`
- Create: `test/predictex/predictions_admin_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/predictex/predictions_admin_test.exs`:

```elixir
defmodule Predictex.PredictionsAdminTest do
  use Predictex.DataCase, async: true

  alias Predictex.{Predictions, Tournament}
  import Predictex.AccountsFixtures

  defp fixture!(round, attrs \\ %{}) do
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

  setup do
    {:ok, round} = Tournament.create_round(%{name: "Round 1", stage: :group, ordinal: 1})
    player = player_fixture(%{display_name: "Dave"})
    %{round: round, player: player}
  end

  test "admin_upsert_prediction inserts a new prediction with round_id from the fixture",
       %{round: round, player: player} do
    f = fixture!(round)

    assert {:ok, pred} =
             Predictions.admin_upsert_prediction(%{
               player_id: player.id,
               fixture_id: f.id,
               home_goals: 2,
               away_goals: 1
             })

    assert pred.round_id == round.id
    assert pred.home_goals == 2
    assert pred.away_goals == 1
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex/predictions_admin_test.exs -v`
Expected: FAIL with `function Predictex.Predictions.admin_upsert_prediction/1 is undefined`.

- [ ] **Step 3: Implement `admin_upsert_prediction/1`**

In `lib/predictex/predictions.ex`, after `create_prediction/2`, add:

```elixir
  @doc """
  Insert-or-update a prediction on behalf of a player (admin path).

  Unlike `create_prediction/2`, this does **not** check the kickoff lockout — the
  admin transcribes screenshots after the fact, and the screenshot is the proof the
  player picked in time. Keyed on `{player_id, fixture_id}`. Runs in a transaction:
  if the row sets `booster: true`, any other booster for the player in that round is
  cleared first, so moving a booster cannot trip the non-deferrable
  `one_booster_per_player_round` unique index.

  Returns `{:ok, prediction}`, `{:error, changeset}`, or `{:error, :fixture_not_found}`.
  """
  def admin_upsert_prediction(attrs) do
    case fetch_fixture(attrs) do
      {:ok, fixture} ->
        player_id = take(attrs, :player_id)

        attrs =
          attrs
          |> Map.put(:round_id, fixture.round_id)
          |> Map.put(:fixture_id, fixture.id)

        Repo.transaction(fn ->
          if booster_set?(attrs) do
            clear_round_booster(player_id, fixture.round_id, fixture.id)
          end

          existing = Repo.get_by(Prediction, player_id: player_id, fixture_id: fixture.id)

          case Repo.insert_or_update(Prediction.changeset(existing || %Prediction{}, attrs)) do
            {:ok, pred} -> pred
            {:error, cs} -> Repo.rollback(cs)
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Read a key whether the attrs map is atom- or string-keyed.
  defp take(attrs, key), do: attrs[key] || attrs[Atom.to_string(key)]

  defp booster_set?(attrs), do: take(attrs, :booster) in [true, "true"]

  defp clear_round_booster(player_id, round_id, except_fixture_id) do
    from(p in Prediction,
      where:
        p.player_id == ^player_id and p.round_id == ^round_id and
          p.fixture_id != ^except_fixture_id and p.booster == true
    )
    |> Repo.update_all(set: [booster: false])
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/predictex/predictions_admin_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/predictions.ex test/predictex/predictions_admin_test.exs
git commit -m "feat: Predictions.admin_upsert_prediction insert path (predictex-a02)"
```

---

### Task 3: `admin_upsert_prediction/1` — update, no-lockout, booster move

**Files:**
- Modify: `test/predictex/predictions_admin_test.exs`

- [ ] **Step 1: Add the failing tests**

Append inside the test module in `test/predictex/predictions_admin_test.exs`:

```elixir
  test "admin_upsert_prediction overwrites an existing pick for the same fixture",
       %{round: round, player: player} do
    f = fixture!(round)
    {:ok, _} = Predictions.admin_upsert_prediction(%{player_id: player.id, fixture_id: f.id, home_goals: 0, away_goals: 0})

    assert {:ok, pred} =
             Predictions.admin_upsert_prediction(%{player_id: player.id, fixture_id: f.id, home_goals: 3, away_goals: 2})

    assert pred.home_goals == 3
    assert pred.away_goals == 2
    # overwrite, not a second row
    assert Repo.aggregate(Predictex.Predictions.Prediction, :count) == 1
  end

  test "admin_upsert_prediction succeeds even after kickoff (no lockout)",
       %{round: round, player: player} do
    past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
    f = fixture!(round, %{kickoff_at: past})

    assert {:ok, _pred} =
             Predictions.admin_upsert_prediction(%{player_id: player.id, fixture_id: f.id, home_goals: 1, away_goals: 1})
  end

  test "admin_upsert_prediction moving a booster A->B clears the old booster",
       %{round: round, player: player} do
    a = fixture!(round)
    b = fixture!(round)

    {:ok, _} = Predictions.admin_upsert_prediction(%{player_id: player.id, fixture_id: a.id, home_goals: 1, away_goals: 0, booster: true})

    assert {:ok, pred_b} =
             Predictions.admin_upsert_prediction(%{player_id: player.id, fixture_id: b.id, home_goals: 2, away_goals: 0, booster: true})

    assert pred_b.booster
    pred_a = Repo.get_by(Predictex.Predictions.Prediction, player_id: player.id, fixture_id: a.id)
    refute pred_a.booster
  end

  test "admin_upsert_prediction returns :fixture_not_found for an unknown fixture",
       %{player: player} do
    assert {:error, :fixture_not_found} =
             Predictions.admin_upsert_prediction(%{player_id: player.id, fixture_id: -1, home_goals: 1, away_goals: 0})
  end
```

- [ ] **Step 2: Run tests to verify they pass** (implementation from Task 2 already covers these)

Run: `mise exec -- mix test test/predictex/predictions_admin_test.exs -v`
Expected: PASS for all five tests. If the booster-move test fails, the transactional clear in Task 2 is wrong — fix `clear_round_booster/3` before proceeding.

- [ ] **Step 3: Commit**

```bash
git add test/predictex/predictions_admin_test.exs
git commit -m "test: admin_upsert update/no-lockout/booster-move (predictex-a02)"
```

---

### Task 4: `admin_save_round_predictions/3` — batch save with partial rows

**Files:**
- Modify: `lib/predictex/predictions.ex`
- Modify: `test/predictex/predictions_admin_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `test/predictex/predictions_admin_test.exs`:

```elixir
  test "admin_save_round_predictions upserts complete rows, skips blank, errors half-filled",
       %{round: round, player: player} do
    full = fixture!(round)
    blank = fixture!(round)
    half = fixture!(round)

    rows = [
      %{fixture_id: full.id, home_goals: 2, away_goals: 1, booster: false},
      %{fixture_id: blank.id, home_goals: nil, away_goals: nil, booster: false},
      %{fixture_id: half.id, home_goals: 1, away_goals: nil, booster: false}
    ]

    {:ok, results} = Predictions.admin_save_round_predictions(player.id, round.id, rows)

    assert results[full.id] == :upserted
    assert results[blank.id] == :skipped
    assert match?({:error, _}, results[half.id])
    assert Repo.aggregate(Predictex.Predictions.Prediction, :count) == 1
  end

  test "admin_save_round_predictions sets exactly one booster across the round",
       %{round: round, player: player} do
    a = fixture!(round)
    b = fixture!(round)

    {:ok, _} =
      Predictions.admin_save_round_predictions(player.id, round.id, [
        %{fixture_id: a.id, home_goals: 1, away_goals: 0, booster: true},
        %{fixture_id: b.id, home_goals: 0, away_goals: 0, booster: false}
      ])

    # Move the booster to B in a second save.
    {:ok, _} =
      Predictions.admin_save_round_predictions(player.id, round.id, [
        %{fixture_id: a.id, home_goals: 1, away_goals: 0, booster: false},
        %{fixture_id: b.id, home_goals: 0, away_goals: 0, booster: true}
      ])

    boosted = Repo.all(from p in Predictex.Predictions.Prediction, where: p.booster == true)
    assert length(boosted) == 1
    assert hd(boosted).fixture_id == b.id
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex/predictions_admin_test.exs -v`
Expected: FAIL with `function Predictex.Predictions.admin_save_round_predictions/3 is undefined`.

- [ ] **Step 3: Implement `admin_save_round_predictions/3`**

In `lib/predictex/predictions.ex`, after `admin_upsert_prediction/1`, add:

```elixir
  @doc """
  Batch-save one player's predictions for a whole round (the by-player "Save all" path).

  Runs in a single transaction: clears every booster for `{player_id, round_id}` first
  (so the radio's single selection cannot collide with the non-deferrable unique index),
  then upserts each row. A row is **skipped** when both goals are nil; **upserted** when
  both are present and valid; reported as `{:error, changeset}` when invalid (e.g. exactly
  one goal). Returns `{:ok, results}` where `results` maps `fixture_id => :upserted | :skipped | {:error, cs}`.
  """
  def admin_save_round_predictions(player_id, round_id, rows) when is_list(rows) do
    Repo.transaction(fn ->
      from(p in Prediction, where: p.player_id == ^player_id and p.round_id == ^round_id)
      |> Repo.update_all(set: [booster: false])

      Enum.reduce(rows, %{}, fn row, acc ->
        Map.put(acc, row.fixture_id, save_round_row(player_id, round_id, row))
      end)
    end)
  end

  defp save_round_row(_player_id, _round_id, %{home_goals: nil, away_goals: nil}), do: :skipped

  defp save_round_row(player_id, round_id, row) do
    attrs =
      row
      |> Map.put(:player_id, player_id)
      |> Map.put(:round_id, round_id)

    existing = Repo.get_by(Prediction, player_id: player_id, fixture_id: row.fixture_id)

    case Repo.insert_or_update(Prediction.changeset(existing || %Prediction{}, attrs)) do
      {:ok, _pred} -> :upserted
      {:error, cs} -> {:error, cs}
    end
  end
```

> Note: because the whole call is one transaction, an invalid row's failed `insert_or_update`
> does **not** roll the transaction back (we capture the `{:error, cs}` rather than calling
> `Repo.rollback/1`), so valid rows in the same batch still persist. This is intended:
> partial saves over a sparse grid are the normal case.

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/predictex/predictions_admin_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/predictions.ex test/predictex/predictions_admin_test.exs
git commit -m "feat: Predictions.admin_save_round_predictions batch save (predictex-a02)"
```

---

### Task 5: `list_fixture_predictions/1`

**Files:**
- Modify: `lib/predictex/predictions.ex`
- Modify: `test/predictex/predictions_admin_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `test/predictex/predictions_admin_test.exs`:

```elixir
  test "list_fixture_predictions returns every player's pick for a fixture, player preloaded",
       %{round: round, player: player} do
    other = player_fixture(%{display_name: "Sam"})
    f = fixture!(round)

    {:ok, _} = Predictions.admin_upsert_prediction(%{player_id: player.id, fixture_id: f.id, home_goals: 1, away_goals: 0})
    {:ok, _} = Predictions.admin_upsert_prediction(%{player_id: other.id, fixture_id: f.id, home_goals: 2, away_goals: 2})

    preds = Predictions.list_fixture_predictions(f.id)

    assert length(preds) == 2
    assert Enum.all?(preds, fn p -> p.player.display_name in ["Dave", "Sam"] end)
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex/predictions_admin_test.exs -v`
Expected: FAIL with `function Predictex.Predictions.list_fixture_predictions/1 is undefined`.

- [ ] **Step 3: Implement**

In `lib/predictex/predictions.ex`, after `list_player_predictions/1`, add:

```elixir
  @doc "All players' predictions for one fixture, with the player preloaded (by-fixture admin lens)."
  def list_fixture_predictions(fixture_id) do
    from(p in Prediction, where: p.fixture_id == ^fixture_id, preload: [:player])
    |> Repo.all()
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/predictex/predictions_admin_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/predictions.ex test/predictex/predictions_admin_test.exs
git commit -m "feat: Predictions.list_fixture_predictions (predictex-a02)"
```

---

## Phase 3 — Router, gate, and landing

### Task 6: `:require_admin` live_session + AdminLive landing + nav link

**Files:**
- Modify: `lib/predictex_web/router.ex`
- Create: `lib/predictex_web/live/admin_live.ex`
- Modify: `lib/predictex_web/components/layouts.ex`
- Create: `test/predictex_web/live/admin_live_test.exs`

- [ ] **Step 1: Write the failing gate test**

Create `test/predictex_web/live/admin_live_test.exs`:

```elixir
defmodule PredictexWeb.AdminLiveTest do
  use PredictexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Predictex.AccountsFixtures

  test "redirects a logged-out visitor to login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/players/log-in"}}} = live(conn, ~p"/admin")
  end

  test "redirects a non-admin player to /", %{conn: conn} do
    player = player_fixture()
    assert {:error, {:redirect, %{to: "/"}}} = conn |> log_in_player(player) |> live(~p"/admin")
  end

  test "an admin sees the console landing with section links", %{conn: conn} do
    admin = admin_player_fixture()
    {:ok, _lv, html} = conn |> log_in_player(admin) |> live(~p"/admin")

    assert html =~ "Admin"
    assert html =~ ~p"/admin/predictions"
    assert html =~ ~p"/admin/fixtures"
    assert html =~ ~p"/admin/players"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex_web/live/admin_live_test.exs -v`
Expected: FAIL (no `/admin` route / `AdminLive` undefined).

- [ ] **Step 3: Add the routes**

In `lib/predictex_web/router.ex`, inside the existing
`scope "/", PredictexWeb do pipe_through [:browser, :require_authenticated_player]` block,
add a new `live_session` next to `:require_authenticated_player`:

```elixir
    live_session :require_admin,
      on_mount: [
        {PredictexWeb.PlayerAuth, :require_authenticated},
        {PredictexWeb.PlayerAuth, :require_admin}
      ] do
      live "/admin", AdminLive, :index
      live "/admin/predictions", AdminPredictionsLive, :index
      live "/admin/fixtures", AdminFixturesLive, :index
      live "/admin/players", AdminPlayersLive, :index
    end
```

> The three `Admin*Live` modules referenced here are created in later tasks. To let this task
> compile and its gate tests pass now, also create empty stub modules in Step 4 for the three
> not-yet-built LiveViews (they render a placeholder; real content lands in Phases 4/6/7).

- [ ] **Step 4: Create AdminLive (landing + shared nav) and stub the other three**

Create `lib/predictex_web/live/admin_live.ex`:

```elixir
defmodule PredictexWeb.AdminLive do
  @moduledoc "Admin console landing: section navigation and at-a-glance counts."
  use PredictexWeb, :live_view

  alias Predictex.{Accounts, Tournament}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Admin")
     |> assign(:player_count, length(Accounts.list_players()))
     |> assign(:fixture_count, length(Tournament.list_fixtures()))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.admin_nav active={:home} />
      <h1 class="text-xl font-semibold mb-4">Admin console</h1>
      <ul class="menu bg-base-200 rounded-box w-full">
        <li><.link navigate={~p"/admin/predictions"}>Enter predictions ({@player_count} players)</.link></li>
        <li><.link navigate={~p"/admin/fixtures"}>Fixtures &amp; results ({@fixture_count} fixtures)</.link></li>
        <li><.link navigate={~p"/admin/players"}>Players</.link></li>
      </ul>
    </Layouts.app>
    """
  end

  @doc "Shared section nav bar for all admin LiveViews."
  attr :active, :atom, required: true

  def admin_nav(assigns) do
    ~H"""
    <nav class="tabs tabs-boxed mb-4">
      <.link navigate={~p"/admin"} class={["tab", @active == :home && "tab-active"]}>Home</.link>
      <.link navigate={~p"/admin/predictions"} class={["tab", @active == :predictions && "tab-active"]}>Predictions</.link>
      <.link navigate={~p"/admin/fixtures"} class={["tab", @active == :fixtures && "tab-active"]}>Fixtures</.link>
      <.link navigate={~p"/admin/players"} class={["tab", @active == :players && "tab-active"]}>Players</.link>
    </nav>
    """
  end
end
```

Create stub `lib/predictex_web/live/admin_predictions_live.ex`:

```elixir
defmodule PredictexWeb.AdminPredictionsLive do
  @moduledoc "Admin prediction entry (by player / by fixture). Built in Phase 4."
  use PredictexWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, :page_title, "Predictions")}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <PredictexWeb.AdminLive.admin_nav active={:predictions} />
      <p>Prediction entry — coming in Phase 4.</p>
    </Layouts.app>
    """
  end
end
```

Create stub `lib/predictex_web/live/admin_fixtures_live.ex` (same shape, `active={:fixtures}`, title `"Fixtures"`, copy `"Fixtures — coming in Phase 6."`) and stub `lib/predictex_web/live/admin_players_live.ex` (`active={:players}`, title `"Players"`, copy `"Players — coming in Phase 7."`). Use the identical module skeleton, swapping the module name, title, `active`, and copy.

- [ ] **Step 5: Add the conditional Admin nav link**

In `lib/predictex_web/components/layouts.ex`, inside `def app/1`'s `<ul class="flex flex-column ...">` (after line 46), add as the first `<li>`:

```heex
          <li :if={@current_scope && @current_scope.player && @current_scope.player.is_admin}>
            <.link navigate={~p"/admin"} class="btn btn-ghost">Admin</.link>
          </li>
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mise exec -- mix test test/predictex_web/live/admin_live_test.exs -v`
Expected: PASS (all three).

- [ ] **Step 7: Run full suite + gates**

Run: `mise exec -- mix test && mise exec -- mix format --check-formatted && mise exec -- mix compile --warnings-as-errors`
Expected: all green.

- [ ] **Step 8: Commit**

```bash
git add lib/predictex_web/router.ex lib/predictex_web/live/admin_live.ex lib/predictex_web/live/admin_predictions_live.ex lib/predictex_web/live/admin_fixtures_live.ex lib/predictex_web/live/admin_players_live.ex lib/predictex_web/components/layouts.ex test/predictex_web/live/admin_live_test.exs
git commit -m "feat: admin console gate, landing, nav link, section stubs (predictex-a02)"
```

---

## Phase 4 — AdminPredictionsLive (playability unlock)

### Task 7: By-player entry grid

**Files:**
- Modify: `lib/predictex_web/live/admin_predictions_live.ex`
- Create: `test/predictex_web/live/admin_predictions_live_test.exs`

- [ ] **Step 1: Write the failing flow test**

Create `test/predictex_web/live/admin_predictions_live_test.exs`:

```elixir
defmodule PredictexWeb.AdminPredictionsLiveTest do
  use PredictexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Predictex.AccountsFixtures
  alias Predictex.{Predictions, Tournament}

  defp fixture!(round, attrs \\ %{}) do
    base = %{external_ref: "ref-#{System.unique_integer([:positive])}", team1: "Brazil", team2: "Serbia", status: :scheduled, round_id: round.id}
    {:ok, f} = Tournament.create_fixture(Map.merge(base, attrs))
    f
  end

  setup %{conn: conn} do
    admin = admin_player_fixture()
    {:ok, round} = Tournament.create_round(%{name: "Matchday 1", stage: :group, ordinal: 1})
    player = player_fixture(%{display_name: "Dave"})
    %{conn: log_in_player(conn, admin), round: round, player: player}
  end

  test "admin enters a player's pick by player, and it persists", %{conn: conn, round: round, player: player} do
    f = fixture!(round)
    {:ok, lv, _html} = live(conn, ~p"/admin/predictions?view=player")

    lv
    |> form("#by-player-form",
      player_id: player.id,
      round_id: round.id,
      rows: %{"#{f.id}" => %{"home_goals" => "2", "away_goals" => "1"}},
      booster_fixture_id: ""
    )
    |> render_submit()

    [pred] = Predictions.list_player_predictions(player.id)
    assert pred.fixture_id == f.id
    assert pred.home_goals == 2
    assert pred.away_goals == 1
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex_web/live/admin_predictions_live_test.exs -v`
Expected: FAIL (form `#by-player-form` not found — stub still in place).

- [ ] **Step 3: Implement AdminPredictionsLive (by-player view)**

Replace `lib/predictex_web/live/admin_predictions_live.ex` with:

```elixir
defmodule PredictexWeb.AdminPredictionsLive do
  @moduledoc """
  Admin prediction entry on behalf of players. Two lenses over the same data:
  `?view=player` (default, primary entry) and `?view=fixture` (audit). The LiveView is the
  anti-corruption boundary: it parses raw form params into clean typed rows and hands them
  to `Predictions.admin_save_round_predictions/3` / `admin_upsert_prediction/1`.
  """
  use PredictexWeb, :live_view

  alias Predictex.{Accounts, Predictions, Tournament}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Predictions")
     |> assign(:players, Accounts.list_players())
     |> assign(:rounds, Tournament.list_rounds())
     |> assign(:selected_player_id, nil)
     |> assign(:selected_round_id, nil)
     |> assign(:selected_fixture_id, nil)
     |> assign(:fixtures, [])
     |> assign(:existing, %{})
     |> assign(:fixture_preds, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :view, view_of(params))}
  end

  defp view_of(%{"view" => "fixture"}), do: :fixture
  defp view_of(_), do: :player

  @impl true
  def handle_event("load_player_round", %{"player_id" => pid, "round_id" => rid}, socket) do
    player_id = to_int(pid)
    round_id = to_int(rid)
    fixtures = fixtures_for_round(round_id)
    existing = existing_for(player_id, fixtures)

    {:noreply,
     socket
     |> assign(:selected_player_id, player_id)
     |> assign(:selected_round_id, round_id)
     |> assign(:fixtures, fixtures)
     |> assign(:existing, existing)}
  end

  def handle_event("save_player_round", params, socket) do
    player_id = to_int(params["player_id"])
    round_id = to_int(params["round_id"])
    boost_id = to_int(params["booster_fixture_id"])
    rows = parse_rows(params["rows"] || %{}, boost_id)

    case Predictions.admin_save_round_predictions(player_id, round_id, rows) do
      {:ok, results} ->
        fixtures = fixtures_for_round(round_id)

        {:noreply,
         socket
         |> assign(:existing, existing_for(player_id, fixtures))
         |> put_flash(:info, summarize(results))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not save predictions.")}
    end
  end

  # --- parsing (anti-corruption boundary) ---

  defp parse_rows(rows, boost_id) do
    Enum.map(rows, fn {fid, attrs} ->
      fixture_id = to_int(fid)

      %{
        fixture_id: fixture_id,
        home_goals: to_int_or_nil(attrs["home_goals"]),
        away_goals: to_int_or_nil(attrs["away_goals"]),
        first_scorer_side: side_or_nil(attrs["first_scorer_side"]),
        first_scorer_player: blank_to_nil(attrs["first_scorer_player"]),
        booster: fixture_id == boost_id
      }
    end)
  end

  defp fixtures_for_round(round_id) do
    Tournament.list_fixtures()
    |> Enum.filter(&(&1.round_id == round_id))
    |> Enum.sort_by(& &1.id)
  end

  defp existing_for(player_id, fixtures) do
    ids = Enum.map(fixtures, & &1.id)

    Predictions.list_player_predictions(player_id)
    |> Enum.filter(&(&1.fixture_id in ids))
    |> Map.new(&{&1.fixture_id, &1})
  end

  defp summarize(results) do
    counts = results |> Map.values() |> Enum.frequencies_by(&result_kind/1)
    "Saved: #{Map.get(counts, :upserted, 0)} · skipped #{Map.get(counts, :skipped, 0)} · errors #{Map.get(counts, :error, 0)}"
  end

  defp result_kind(:upserted), do: :upserted
  defp result_kind(:skipped), do: :skipped
  defp result_kind({:error, _}), do: :error

  defp to_int(nil), do: nil
  defp to_int(""), do: nil
  defp to_int(i) when is_integer(i), do: i
  defp to_int(s) when is_binary(s), do: String.to_integer(s)
  defp to_int_or_nil(""), do: nil
  defp to_int_or_nil(nil), do: nil
  defp to_int_or_nil(s), do: String.to_integer(s)
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(s), do: s
  defp side_or_nil("home"), do: :home
  defp side_or_nil("away"), do: :away
  defp side_or_nil(_), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <PredictexWeb.AdminLive.admin_nav active={:predictions} />

      <div class="tabs tabs-boxed mb-4">
        <.link patch={~p"/admin/predictions?view=player"} class={["tab", @view == :player && "tab-active"]}>By player</.link>
        <.link patch={~p"/admin/predictions?view=fixture"} class={["tab", @view == :fixture && "tab-active"]}>By fixture</.link>
      </div>

      <div :if={@view == :player}>
        <form phx-change="load_player_round" class="flex gap-2 mb-4">
          <select name="player_id" class="select select-bordered">
            <option value="">Player…</option>
            <option :for={p <- @players} value={p.id} selected={p.id == @selected_player_id}>{p.display_name}</option>
          </select>
          <select name="round_id" class="select select-bordered">
            <option value="">Round…</option>
            <option :for={r <- @rounds} value={r.id} selected={r.id == @selected_round_id}>{r.name}</option>
          </select>
        </form>

        <form :if={@fixtures != [] && @selected_player_id} id="by-player-form" phx-submit="save_player_round">
          <input type="hidden" name="player_id" value={@selected_player_id} />
          <input type="hidden" name="round_id" value={@selected_round_id} />
          <table class="table">
            <thead><tr><th>Fixture</th><th>H</th><th>A</th><th>1st side</th><th>1st player</th><th>⚡</th></tr></thead>
            <tbody>
              <tr :for={f <- @fixtures}>
                <td>{f.team1} v {f.team2}</td>
                <td><input type="number" min="0" class="input input-bordered w-16" name={"rows[#{f.id}][home_goals]"} value={existing_val(@existing, f.id, :home_goals)} /></td>
                <td><input type="number" min="0" class="input input-bordered w-16" name={"rows[#{f.id}][away_goals]"} value={existing_val(@existing, f.id, :away_goals)} /></td>
                <td>
                  <select name={"rows[#{f.id}][first_scorer_side]"} class="select select-bordered">
                    <option value="">—</option>
                    <option value="home" selected={existing_val(@existing, f.id, :first_scorer_side) == :home}>Home</option>
                    <option value="away" selected={existing_val(@existing, f.id, :first_scorer_side) == :away}>Away</option>
                  </select>
                </td>
                <td><input type="text" class="input input-bordered" name={"rows[#{f.id}][first_scorer_player]"} value={existing_val(@existing, f.id, :first_scorer_player)} /></td>
                <td><input type="radio" class="radio" name="booster_fixture_id" value={f.id} checked={existing_val(@existing, f.id, :booster) == true} /></td>
              </tr>
            </tbody>
          </table>
          <button type="submit" class="btn btn-primary mt-4">Save all</button>
        </form>
      </div>

      <div :if={@view == :fixture}>
        <p>By-fixture view — Task 9.</p>
      </div>
    </Layouts.app>
    """
  end

  defp existing_val(existing, fixture_id, field) do
    case Map.get(existing, fixture_id) do
      nil -> nil
      pred -> Map.get(pred, field)
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/predictex_web/live/admin_predictions_live_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/predictex_web/live/admin_predictions_live.ex test/predictex_web/live/admin_predictions_live_test.exs
git commit -m "feat: admin by-player prediction entry grid (predictex-a02)"
```

---

### Task 8: By-player entry → appears on /predictions (cross-page flow)

**Files:**
- Modify: `test/predictex_web/live/admin_predictions_live_test.exs`

- [ ] **Step 1: Write the failing cross-page test**

Append to `test/predictex_web/live/admin_predictions_live_test.exs`:

```elixir
  test "a pick entered by admin shows on the player's /predictions page", %{conn: conn, round: round, player: player} do
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    f = fixture!(round, %{team1: "Mexico", team2: "Poland", kickoff_at: future})

    {:ok, lv, _} = live(conn, ~p"/admin/predictions?view=player")

    lv
    |> form("#by-player-form",
      player_id: player.id,
      round_id: round.id,
      rows: %{"#{f.id}" => %{"home_goals" => "3", "away_goals" => "0"}},
      booster_fixture_id: "#{f.id}"
    )
    |> render_submit()

    # Now visit the player's own dashboard as that player.
    player_conn = build_conn() |> log_in_player(player)
    {:ok, _lv2, html} = live(player_conn, ~p"/predictions")

    assert html =~ "Mexico"
    assert html =~ "3"
  end
```

- [ ] **Step 2: Run test to verify it passes** (implementation already supports it)

Run: `mise exec -- mix test test/predictex_web/live/admin_predictions_live_test.exs -v`
Expected: PASS. If `/predictions` does not render the entered scoreline, re-check that `Dashboard.for_player/1` reads the same `home_goals`/`away_goals` fields (it does per the spec data contract) before changing anything.

- [ ] **Step 3: Commit**

```bash
git add test/predictex_web/live/admin_predictions_live_test.exs
git commit -m "test: admin entry surfaces on player /predictions (predictex-a02)"
```

---

### Task 9: By-fixture audit lens

**Files:**
- Modify: `lib/predictex_web/live/admin_predictions_live.ex`
- Modify: `test/predictex_web/live/admin_predictions_live_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `test/predictex_web/live/admin_predictions_live_test.exs`:

```elixir
  test "by-fixture view lists every player's pick and flags missing ones", %{conn: conn, round: round, player: player} do
    other = player_fixture(%{display_name: "Sam"})
    f = fixture!(round)
    {:ok, _} = Predictions.admin_upsert_prediction(%{player_id: player.id, fixture_id: f.id, home_goals: 1, away_goals: 0})

    {:ok, lv, _} = live(conn, ~p"/admin/predictions?view=fixture")

    html =
      lv
      |> form("#by-fixture-select", fixture_id: f.id)
      |> render_change()

    assert html =~ "Dave"
    assert html =~ "Sam"
    assert html =~ "no pick" or html =~ "missing"
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex_web/live/admin_predictions_live_test.exs -v`
Expected: FAIL (`#by-fixture-select` not found).

- [ ] **Step 3: Implement the by-fixture lens**

In `lib/predictex_web/live/admin_predictions_live.ex`, add a handler and replace the by-fixture `<div>`:

Add this `handle_event`:

```elixir
  def handle_event("load_fixture", %{"fixture_id" => fid}, socket) do
    fixture_id = to_int(fid)
    preds = Predictions.list_fixture_predictions(fixture_id)
    predicted_ids = MapSet.new(preds, & &1.player_id)
    missing = Enum.reject(socket.assigns.players, &MapSet.member?(predicted_ids, &1.id))

    {:noreply,
     socket
     |> assign(:selected_fixture_id, fixture_id)
     |> assign(:fixture_preds, preds)
     |> assign(:missing_players, missing)}
  end
```

Add `|> assign(:missing_players, [])` to `mount/1`. Replace the by-fixture `<div>` in `render/1` with:

```heex
      <div :if={@view == :fixture}>
        <form id="by-fixture-select" phx-change="load_fixture" class="mb-4">
          <select name="fixture_id" class="select select-bordered">
            <option value="">Fixture…</option>
            <option :for={f <- all_fixtures()} value={f.id} selected={f.id == @selected_fixture_id}>{f.team1} v {f.team2}</option>
          </select>
        </form>

        <table :if={@selected_fixture_id} class="table">
          <thead><tr><th>Player</th><th>Pick</th><th>⚡</th></tr></thead>
          <tbody>
            <tr :for={p <- @fixture_preds}>
              <td>{p.player.display_name}</td>
              <td>{p.home_goals}–{p.away_goals}</td>
              <td>{if p.booster, do: "⚡"}</td>
            </tr>
            <tr :for={pl <- @missing_players} class="opacity-60">
              <td>{pl.display_name}</td>
              <td colspan="2"><span class="badge badge-warning">no pick</span></td>
            </tr>
          </tbody>
        </table>
      </div>
```

Add helper `defp all_fixtures(), do: Tournament.list_fixtures() |> Enum.sort_by(& &1.id)`.

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/predictex_web/live/admin_predictions_live_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/predictex_web/live/admin_predictions_live.ex test/predictex_web/live/admin_predictions_live_test.exs
git commit -m "feat: admin by-fixture audit lens (predictex-a02)"
```

---

## Phase 5 — Accounts.set_player_admin

### Task 10: `set_player_admin/2`

**Files:**
- Modify: `lib/predictex/accounts.ex`
- Modify: `test/predictex/accounts_test.exs`

- [ ] **Step 1: Write the failing test**

Append a test to `test/predictex/accounts_test.exs` (inside the module, reusing its existing imports/aliases — it already `import Predictex.AccountsFixtures` and aliases `Accounts`):

```elixir
  describe "set_player_admin/2" do
    test "promotes and demotes by id, returning {:ok, player}" do
      player = player_fixture()
      refute player.is_admin

      assert {:ok, promoted} = Accounts.set_player_admin(player.id, true)
      assert promoted.is_admin

      assert {:ok, demoted} = Accounts.set_player_admin(player.id, false)
      refute demoted.is_admin
    end
  end
```

> If `accounts_test.exs` does not already import fixtures / alias `Accounts`, add
> `import Predictex.AccountsFixtures` and `alias Predictex.Accounts` at the top of the module.

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex/accounts_test.exs -v`
Expected: FAIL with `function Predictex.Accounts.set_player_admin/2 is undefined`.

- [ ] **Step 3: Implement**

In `lib/predictex/accounts.ex`, after `promote_admin/1`, add:

```elixir
  @doc """
  Set a player's `is_admin` flag by id. Id-based, tuple-returning sibling to
  `promote_admin/1`, for the admin Players UI. Returns `{:ok, player}` or `{:error, changeset}`.
  """
  def set_player_admin(player_id, is_admin) when is_boolean(is_admin) do
    Player
    |> Repo.get!(player_id)
    |> Ecto.Changeset.change(is_admin: is_admin)
    |> Repo.update()
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/predictex/accounts_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/accounts.ex test/predictex/accounts_test.exs
git commit -m "feat: Accounts.set_player_admin/2 (predictex-a02)"
```

---

## Phase 6 — AdminFixturesLive (sync, result override, cohort)

### Task 11: Fixtures list + result override + cohort %

**Files:**
- Modify: `lib/predictex_web/live/admin_fixtures_live.ex`
- Create: `test/predictex_web/live/admin_fixtures_live_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/predictex_web/live/admin_fixtures_live_test.exs`:

```elixir
defmodule PredictexWeb.AdminFixturesLiveTest do
  use PredictexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Predictex.AccountsFixtures
  alias Predictex.Tournament

  defp fixture!(round, attrs \\ %{}) do
    base = %{external_ref: "ref-#{System.unique_integer([:positive])}", team1: "Brazil", team2: "Serbia", status: :scheduled, round_id: round.id}
    {:ok, f} = Tournament.create_fixture(Map.merge(base, attrs))
    f
  end

  setup %{conn: conn} do
    admin = admin_player_fixture()
    {:ok, round} = Tournament.create_round(%{name: "Matchday 1", stage: :group, ordinal: 1})
    %{conn: log_in_player(conn, admin), round: round}
  end

  test "shows 'cohort not set' when a fixture has no cohort percentages", %{conn: conn, round: round} do
    _f = fixture!(round)
    {:ok, _lv, html} = live(conn, ~p"/admin/fixtures")
    assert html =~ "cohort not set"
  end

  test "admin records a result and it persists", %{conn: conn, round: round} do
    f = fixture!(round)
    {:ok, lv, _} = live(conn, ~p"/admin/fixtures")

    lv
    |> form("#fixture-#{f.id}-result", fixture: %{home_goals: "2", away_goals: "1", status: "completed"})
    |> render_submit()

    reloaded = Tournament.get_fixture!(f.id)
    assert reloaded.home_goals == 2
    assert reloaded.away_goals == 1
    assert reloaded.status == :completed
  end

  test "admin sets cohort percentages and they persist", %{conn: conn, round: round} do
    f = fixture!(round)
    {:ok, lv, _} = live(conn, ~p"/admin/fixtures")

    lv
    |> form("#fixture-#{f.id}-cohort", fixture: %{cohort_home_pct: "50", cohort_draw_pct: "30", cohort_away_pct: "20"})
    |> render_submit()

    reloaded = Tournament.get_fixture!(f.id)
    assert reloaded.cohort_home_pct == 50
    assert reloaded.cohort_draw_pct == 30
    assert reloaded.cohort_away_pct == 20
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mise exec -- mix test test/predictex_web/live/admin_fixtures_live_test.exs -v`
Expected: FAIL (stub LiveView, forms not found).

- [ ] **Step 3: Implement AdminFixturesLive**

Replace `lib/predictex_web/live/admin_fixtures_live.ex` with:

```elixir
defmodule PredictexWeb.AdminFixturesLive do
  @moduledoc """
  Admin fixtures: trigger a results sync, override a result by hand, and enter per-fixture
  FIFA cohort percentages (which drive the risky bonus). Unset cohort is shown explicitly.
  """
  use PredictexWeb, :live_view

  alias Predictex.Results.Ingest
  alias Predictex.Tournament

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Fixtures")
     |> assign(:syncing, false)
     |> load_fixtures()}
  end

  defp load_fixtures(socket) do
    assign(socket, :fixtures, Tournament.list_fixtures() |> Enum.sort_by(& &1.id))
  end

  @impl true
  def handle_event("sync", _params, socket) do
    {:noreply,
     socket
     |> assign(:syncing, true)
     |> start_async(:sync, fn -> Ingest.sync_from_url() end)}
  end

  def handle_event("save_result", %{"id" => id, "fixture" => attrs}, socket) do
    update_fixture(socket, id, attrs, "Result saved.")
  end

  def handle_event("save_cohort", %{"id" => id, "fixture" => attrs}, socket) do
    update_fixture(socket, id, attrs, "Cohort saved.")
  end

  @impl true
  def handle_async(:sync, {:ok, summary}, socket) do
    {:noreply,
     socket
     |> assign(:syncing, false)
     |> load_fixtures()
     |> put_flash(:info, "Sync complete: #{inspect(summary)}")}
  end

  def handle_async(:sync, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:syncing, false)
     |> put_flash(:error, "Sync failed: #{inspect(reason)}")}
  end

  defp update_fixture(socket, id, attrs, ok_msg) do
    fixture = Tournament.get_fixture!(id)

    case Tournament.update_fixture(fixture, attrs) do
      {:ok, _} -> {:noreply, socket |> load_fixtures() |> put_flash(:info, ok_msg)}
      {:error, _cs} -> {:noreply, put_flash(socket, :error, "Could not save fixture.")}
    end
  end

  defp cohort_set?(f), do: f.cohort_home_pct && f.cohort_draw_pct && f.cohort_away_pct

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <PredictexWeb.AdminLive.admin_nav active={:fixtures} />

      <button phx-click="sync" class="btn btn-secondary mb-4" disabled={@syncing}>
        {if @syncing, do: "Syncing…", else: "Sync from feed"}
      </button>

      <div :for={f <- @fixtures} class="card bg-base-200 p-4 mb-3">
        <div class="font-medium mb-2">{f.team1} v {f.team2}</div>

        <form id={"fixture-#{f.id}-result"} phx-submit="save_result" class="flex flex-wrap gap-2 items-end mb-2">
          <input type="hidden" name="id" value={f.id} />
          <label class="text-xs">H<input type="number" min="0" name="fixture[home_goals]" value={f.home_goals} class="input input-bordered input-sm w-16" /></label>
          <label class="text-xs">A<input type="number" min="0" name="fixture[away_goals]" value={f.away_goals} class="input input-bordered input-sm w-16" /></label>
          <label class="text-xs">Status
            <select name="fixture[status]" class="select select-bordered select-sm">
              <option value="scheduled" selected={f.status == :scheduled}>scheduled</option>
              <option value="completed" selected={f.status == :completed}>completed</option>
            </select>
          </label>
          <button type="submit" class="btn btn-sm btn-primary">Save result</button>
        </form>

        <form id={"fixture-#{f.id}-cohort"} phx-submit="save_cohort" class="flex flex-wrap gap-2 items-end">
          <input type="hidden" name="id" value={f.id} />
          <label class="text-xs">Home%<input type="number" min="0" max="100" name="fixture[cohort_home_pct]" value={f.cohort_home_pct} class="input input-bordered input-sm w-16" /></label>
          <label class="text-xs">Draw%<input type="number" min="0" max="100" name="fixture[cohort_draw_pct]" value={f.cohort_draw_pct} class="input input-bordered input-sm w-16" /></label>
          <label class="text-xs">Away%<input type="number" min="0" max="100" name="fixture[cohort_away_pct]" value={f.cohort_away_pct} class="input input-bordered input-sm w-16" /></label>
          <button type="submit" class="btn btn-sm">Save cohort</button>
          <span :if={!cohort_set?(f)} class="badge badge-warning">cohort not set — risky bonus off</span>
        </form>
      </div>
    </Layouts.app>
    """
  end
end
```

> The `save_result`/`save_cohort` handlers read `%{"id" => id, "fixture" => attrs}` but the
> form nests `id` as a sibling field, so it arrives as a top-level param — correct. Confirm
> the status enum cast accepts the string values via the existing `Fixture.changeset/2`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mise exec -- mix test test/predictex_web/live/admin_fixtures_live_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/predictex_web/live/admin_fixtures_live.ex test/predictex_web/live/admin_fixtures_live_test.exs
git commit -m "feat: admin fixtures result override + cohort + sync (predictex-a02)"
```

---

### Task 12: Sync button uses a stubbed source (no network in tests)

**Files:**
- Modify: `lib/predictex_web/live/admin_fixtures_live.ex`
- Modify: `config/test.exs`
- Modify: `test/predictex_web/live/admin_fixtures_live_test.exs`

- [ ] **Step 1: Make the sync source configurable**

In `lib/predictex_web/live/admin_fixtures_live.ex`, change the `handle_event("sync", …)` async thunk to use an injectable function, defaulting to the live URL sync but overridable in tests:

```elixir
  def handle_event("sync", _params, socket) do
    sync_fun = Application.get_env(:predictex, :admin_sync_fun, &Ingest.sync_from_url/0)

    {:noreply,
     socket
     |> assign(:syncing, true)
     |> start_async(:sync, sync_fun)}
  end
```

- [ ] **Step 2: Point tests at the bundled fixture file**

In `config/test.exs`, add (using the openfootball fixture the ingest tests already use — confirm its path in `test/predictex/results/ingest_test.exs` and reuse it):

```elixir
config :predictex, :admin_sync_fun, fn ->
  Predictex.Results.Ingest.sync_from_file("test/support/fixtures/openfootball_sample.json")
end
```

> Before writing this line, open `test/predictex/results/ingest_test.exs` and copy the exact
> fixture path it loads with `sync_from_file/1`. If none exists as a file, create a minimal
> one-round/one-fixture JSON at that path. Do not invent a path.

- [ ] **Step 3: Write the sync flow test**

Append to `test/predictex_web/live/admin_fixtures_live_test.exs`:

```elixir
  test "the sync button runs without hitting the network and reports completion", %{conn: conn} do
    {:ok, lv, _} = live(conn, ~p"/admin/fixtures")
    html = lv |> element("button", "Sync from feed") |> render_click()
    # async completes; re-render shows the flash
    assert render_async(lv) =~ "Sync complete"
    _ = html
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mise exec -- mix test test/predictex_web/live/admin_fixtures_live_test.exs -v`
Expected: PASS, with no network access.

- [ ] **Step 5: Commit**

```bash
git add lib/predictex_web/live/admin_fixtures_live.ex config/test.exs test/predictex_web/live/admin_fixtures_live_test.exs
git commit -m "test: admin sync button uses stubbed source, no network (predictex-a02)"
```

---

## Phase 7 — AdminPlayersLive

### Task 13: Players list + promote

**Files:**
- Modify: `lib/predictex_web/live/admin_players_live.ex`
- Create: `test/predictex_web/live/admin_players_live_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/predictex_web/live/admin_players_live_test.exs`:

```elixir
defmodule PredictexWeb.AdminPlayersLiveTest do
  use PredictexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Predictex.AccountsFixtures
  alias Predictex.Accounts

  setup %{conn: conn} do
    admin = admin_player_fixture()
    %{conn: log_in_player(conn, admin)}
  end

  test "lists players and promotes one to admin", %{conn: conn} do
    member = player_fixture(%{display_name: "Member"})
    {:ok, lv, html} = live(conn, ~p"/admin/players")

    assert html =~ "Member"

    lv |> element("button[phx-value-id='#{member.id}']", "Make admin") |> render_click()

    assert Accounts.get_player!(member.id).is_admin
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex_web/live/admin_players_live_test.exs -v`
Expected: FAIL (stub LiveView).

- [ ] **Step 3: Implement AdminPlayersLive**

Replace `lib/predictex_web/live/admin_players_live.ex` with:

```elixir
defmodule PredictexWeb.AdminPlayersLive do
  @moduledoc "Admin player management: list players and promote to admin."
  use PredictexWeb, :live_view

  alias Predictex.Accounts

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "Players") |> load_players()}
  end

  defp load_players(socket), do: assign(socket, :players, Accounts.list_players())

  @impl true
  def handle_event("promote", %{"id" => id}, socket) do
    case Accounts.set_player_admin(String.to_integer(id), true) do
      {:ok, _} -> {:noreply, socket |> load_players() |> put_flash(:info, "Promoted to admin.")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not promote player.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <PredictexWeb.AdminLive.admin_nav active={:players} />
      <table class="table">
        <thead><tr><th>Name</th><th>Email</th><th>Admin?</th><th></th></tr></thead>
        <tbody>
          <tr :for={p <- @players}>
            <td>{p.display_name}</td>
            <td>{p.email}</td>
            <td>{if p.is_admin, do: "✓"}</td>
            <td>
              <button :if={!p.is_admin} phx-click="promote" phx-value-id={p.id} class="btn btn-sm">Make admin</button>
            </td>
          </tr>
        </tbody>
      </table>
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/predictex_web/live/admin_players_live_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/predictex_web/live/admin_players_live.ex test/predictex_web/live/admin_players_live_test.exs
git commit -m "feat: admin players list + promote (predictex-a02)"
```

---

## Phase 8 — Full-suite gate & close-out

### Task 14: Green gates and issue close

- [ ] **Step 1: Run the full quality gate**

```bash
mise exec -- mix test
mise exec -- mix format --check-formatted
mise exec -- mix compile --warnings-as-errors
mise exec -- mix deps.unlock --check-unused
```
Expected: all green. Fix any failures before closing.

- [ ] **Step 2: Manual smoke (optional but recommended)**

Run the app (`mise exec -- mix phx.server`), log in as an admin (promote your dev user via
`mise exec -- mix run -e 'Predictex.Accounts.promote_admin("you@example.com")'`), visit
`/admin`, enter a prediction by player, confirm it shows on `/predictions`.

- [ ] **Step 3: Close the beads issue**

```bash
bd close predictex-a02 --reason="Admin console shipped: prediction entry (both lenses), fixtures sync/override/cohort, player promote"
```

- [ ] **Step 4: Final commit if anything changed**

```bash
git add -A && git commit -m "chore: close predictex-a02 admin console" || true
```

---

## Self-review notes (author)

- **Spec coverage:** prediction entry by-player (Task 7/8) + by-fixture (Task 9); fixtures sync (Task 11/12) + result override (Task 11) + cohort with visible unset (Task 11); player promote (Task 13); auth chain + gate (Task 6); `admin_upsert`/`admin_save_round`/`list_fixture_predictions`/`set_player_admin` all covered (Tasks 2–5, 10). Bypass-lockout (Task 3), booster-move (Tasks 3,4), partial-row (Task 4), network-free sync (Task 12) — all present.
- **Verify-before-invent flags:** the openfootball sample fixture path (Task 12) and the `Fixture.changeset/2` status-cast acceptance (Task 11) must be confirmed against existing code, not assumed.
