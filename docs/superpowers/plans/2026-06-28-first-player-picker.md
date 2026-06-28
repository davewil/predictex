# First-Player-to-Score Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give members a searchable, app-styled picker to choose the first player to score on each editable knockout fixture — writing both the player name (existing `first_scorer_player` field) and the FIFA `fifaId` (new field) — sourced from FIFA's static `players.json` + `squads.json`.

**Architecture:** A pure `Fifa.Players` parser joins `players.json` (by `squadId`) to `squads.json` (squadId→team name) and keys squads by `Crosswalk.norm(team)`. A supervised ETS cache (`Fifa.Players.Cache`, lazy-load-on-miss + boot-warm + a cron `PlayersSync` worker for goal refresh) holds the parsed squads. `MyPredictionsLive` reads the cache at render time to populate a per-fixture modal; a colocated JS hook handles open/close/team-toggle/search/select, writing two sr-only inputs the existing `parse_pick_rows/2` → `save_round_predictions/5` path already (and newly) persists. Scoring's `norm/1` gains accent-folding to recover the accent-only name divergences.

**Tech Stack:** Elixir 1.20.1 / OTP 28 (via `mise exec -- mix …`), Phoenix 1.8.8 LiveView, colocated hooks (`Phoenix.LiveView.ColocatedHook`), Ecto/Postgres, Oban 2.23, `Req` (HTTP), daisyUI/Tailwind.

## Global Constraints

- **Always run `mise exec -- mix …`** — plain `mix` is the wrong Elixir version.
- **The gate is `mix precommit`** (compile --warnings-as-errors, deps.unlock --check-unused, format --check-formatted, credo --strict, test). Run it green before every commit. Credo nesting max is 3.
- **No new deps.** Reuse `Predictex.Fifa.Reference.get_json/1` for HTTP and `Predictex.Fifa.Crosswalk.norm/1` for FIFA↔openfootball name normalization — do not duplicate either.
- **Oban tests run `testing: :manual`.** FIFA fetches are network-free in tests via an injectable source function (mirror `:cohort_source_fun`); here the key is `:players_source_fun`.
- **When a test creates multiple rounds, insert them ascending by `:ordinal`** (deadlock invariant, documented in `DataCase.setup_sandbox`).
- **Flag isolation:** native-KO LiveView tests use `@tag :native_ko` + `FunWithFlags.enable(:native_ko_entry)` with an `on_exit` `FunWithFlags.Store.Cache.flush/0`. Never override `:fun_with_flags, :cache` in `config/test.exs` (compile-env CI gotcha).
- **Data-contract finding (the reason for the fifaId field + accent-fold):** the picker stores a FIFA `shortName`; scoring matches it against openfootball's `first_scorer_player`. Verified 2026-06-28: under scoring's `trim+downcase`, only ~72% of correct picks match (2022 OF goals × 2026 FIFA names, ~68 same-player pairs); ~12% miss on accents alone (Julián Álvarez, Théo Hernández), ~16% miss structurally (Mbappé→"Kylian Mbappé", Rashford, Mac Allister). Accent-folding (Task 5) recovers the accent group; the structural group needs `fifaId`-exact scoring — captured by storing the id now (Tasks 4/7), wired to scoring in follow-up bead `predictex-i9k`. **v1 keeps free-text scoring; it does NOT add fifaId-exact actual-side matching.**
- **Player map shape** (the one type every task shares): `%{name: String.t(), position: String.t(), goals: integer(), fifa_id: integer()}`. `position` is the decoded label `"GK" | "DEF" | "MID" | "FWD"`. Squad lists are sorted **goals descending, then name ascending**.
- **Feed shapes** (verified live 2026-06-28): `players.json` is a JSON list of `%{"shortName", "position" (1=GK 2=DEF 3=MID 4=FWD), "stats" => %{"goals"}, "squadId", "fifaId"}` (1264 players). `squads.json` is a JSON list of `%{"id", "name", "abbr"}` (48 squads; FIFA-side names like "Bosnia and Herzegovina"/"Cabo Verde"/"Congo DR" are normalized to openfootball names by `Crosswalk.norm/1`).

---

### Task 1: `Fifa.Players` — pure parse + for_team

**Files:**
- Create: `lib/predictex/fifa/players.ex`
- Test: `test/predictex/fifa/players_test.exs`

**Interfaces:**
- Consumes: `Predictex.Fifa.Crosswalk.norm/1` (existing).
- Produces:
  - `Predictex.Fifa.Players.parse(players :: [map], squads :: [map]) :: %{String.t() => [player]}` where `player` is the shared shape above. Keys are `Crosswalk.norm(squad_name)`.
  - `Predictex.Fifa.Players.for_team(map :: %{String.t() => [player]}, team :: String.t()) :: [player]` (unknown team → `[]`).

- [ ] **Step 1: Write the failing test**

```elixir
# test/predictex/fifa/players_test.exs
defmodule Predictex.Fifa.PlayersTest do
  use ExUnit.Case, async: true

  alias Predictex.Fifa.Players

  # Two squads incl. a FIFA-side name that diverges from openfootball ("Bosnia and Herzegovina").
  defp squads,
    do: [
      %{"id" => 7, "name" => "Brazil", "abbr" => "BRA"},
      %{"id" => 9, "name" => "Bosnia and Herzegovina", "abbr" => "BIH"}
    ]

  defp players,
    do: [
      %{"shortName" => "Matheus Cunha", "position" => 4, "stats" => %{"goals" => 3}, "squadId" => 7, "fifaId" => 430_609},
      %{"shortName" => "Alisson Becker", "position" => 1, "stats" => %{"goals" => 0}, "squadId" => 7, "fifaId" => 100_001},
      %{"shortName" => "Neymar", "position" => 4, "stats" => %{"goals" => 3}, "squadId" => 7, "fifaId" => 100_002},
      %{"shortName" => "Edin Dzeko", "position" => 4, "stats" => %{"goals" => 1}, "squadId" => 9, "fifaId" => 200_001},
      # squad with no name entry — must be dropped, not crash:
      %{"shortName" => "Ghost", "position" => 3, "stats" => %{"goals" => 0}, "squadId" => 99, "fifaId" => 300_001}
    ]

  describe "parse/2" do
    test "keys squads by Crosswalk.norm and decodes the shared player shape" do
      map = Players.parse(players(), squads())

      assert Map.has_key?(map, "brazil")
      # FIFA "Bosnia and Herzegovina" normalises to openfootball "bosnia & herzegovina":
      assert Map.has_key?(map, "bosnia & herzegovina")
      refute Map.has_key?(map, "99")

      cunha = map["brazil"] |> Enum.find(&(&1.name == "Matheus Cunha"))
      assert cunha == %{name: "Matheus Cunha", position: "FWD", goals: 3, fifa_id: 430_609}
    end

    test "sorts each squad goals-desc then name-asc" do
      names = Players.parse(players(), squads())["brazil"] |> Enum.map(& &1.name)
      # goals: Cunha 3, Neymar 3 (tie → name asc), Alisson 0
      assert names == ["Matheus Cunha", "Neymar", "Alisson Becker"]
    end

    test "decodes all four position codes" do
      sq = [%{"id" => 1, "name" => "Algeria", "abbr" => "ALG"}]

      ps =
        for {code, label} <- [{1, "GK"}, {2, "DEF"}, {3, "MID"}, {4, "FWD"}] do
          %{"shortName" => label, "position" => code, "stats" => %{"goals" => 0}, "squadId" => 1, "fifaId" => code}
        end

      decoded = Players.parse(ps, sq)["algeria"] |> Map.new(&{&1.name, &1.position})
      assert decoded == %{"GK" => "GK", "DEF" => "DEF", "MID" => "MID", "FWD" => "FWD"}
    end
  end

  describe "for_team/2" do
    test "returns the squad for a known team, [] for unknown" do
      map = Players.parse(players(), squads())
      assert Players.for_team(map, "Brazil") |> Enum.map(& &1.name) |> Enum.member?("Neymar")
      # alias-normalised lookup works from either spelling:
      assert Players.for_team(map, "Bosnia & Herzegovina") |> length() == 1
      assert Players.for_team(map, "Narnia") == []
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex/fifa/players_test.exs`
Expected: FAIL — `Predictex.Fifa.Players.parse/2 is undefined (module Predictex.Fifa.Players is not available)`.

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/predictex/fifa/players.ex
defmodule Predictex.Fifa.Players do
  @moduledoc """
  Pure join of FIFA's static `players.json` and `squads.json` into per-team squad lists,
  keyed by `Crosswalk.norm(team)` so the openfootball fixture team name finds its squad
  (predictex-u4k). Each player is `%{name, position, goals, fifa_id}`; `fifa_id` is the
  canonical FIFA player id stored alongside the picked name for the exact-scoring follow-up.

  No I/O — `Fifa.Players.Cache` owns fetching and caching.
  """
  alias Predictex.Fifa.Crosswalk

  @positions %{1 => "GK", 2 => "DEF", 3 => "MID", 4 => "FWD"}

  @doc "Join players to squads, returning `%{norm(team) => [player]}` sorted goals-desc then name."
  @spec parse([map()], [map()]) :: %{String.t() => [map()]}
  def parse(players, squads) when is_list(players) and is_list(squads) do
    names = Map.new(squads, fn s -> {s["id"], s["name"]} end)

    players
    |> Enum.group_by(& &1["squadId"])
    |> Enum.flat_map(fn {squad_id, ps} ->
      case Map.get(names, squad_id) do
        nil -> []
        team -> [{Crosswalk.norm(team), build_squad(ps)}]
      end
    end)
    |> Map.new()
  end

  @doc "The squad list for one team name (alias-normalised); unknown team → `[]`."
  @spec for_team(%{String.t() => [map()]}, String.t()) :: [map()]
  def for_team(map, team) when is_map(map), do: Map.get(map, Crosswalk.norm(team), [])

  defp build_squad(players) do
    players
    |> Enum.map(fn p ->
      %{
        name: p["shortName"],
        position: Map.get(@positions, p["position"], ""),
        goals: get_in(p, ["stats", "goals"]) || 0,
        fifa_id: p["fifaId"]
      }
    end)
    |> Enum.sort_by(&{-&1.goals, &1.name})
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/predictex/fifa/players_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/fifa/players.ex test/predictex/fifa/players_test.exs
git commit -m "feat(fifa): pure Players.parse/for_team squad join (predictex-u4k)"
```

---

### Task 2: `Fifa.Players.Cache` — supervised ETS cache (lazy-load + boot-warm + refresh)

**Files:**
- Create: `lib/predictex/fifa/players/cache.ex`
- Modify: `lib/predictex/application.ex` (add the cache to the supervision tree)
- Modify: `config/config.exs` (no change yet — cron added in Task 3) — **skip**, see Task 3.
- Modify: `config/test.exs` (disable boot-warm so tests don't hit the network)
- Test: `test/predictex/fifa/players/cache_test.exs`

**Interfaces:**
- Consumes: `Predictex.Fifa.Players.parse/2`, `Predictex.Fifa.Crosswalk.norm/1`, `Predictex.Fifa.Reference.get_json/1`.
- Produces:
  - `Predictex.Fifa.Players.Cache.for_team(team :: String.t()) :: [player]` — lazy-loads on first miss, then reads ETS; unknown team / failed load → `[]`.
  - `Predictex.Fifa.Players.Cache.refresh() :: :ok | {:error, term}` — force re-fetch + repopulate (the worker calls this).
  - Source override config key: `:players_source_fun`, a 0-arity fun returning `{:ok, %{players: [map], squads: [map]}} | {:error, term}` (defaults to `&Cache.fetch/0`).
  - Boot-warm config key: `:warm_players_cache` (default `true`; `false` in test).

- [ ] **Step 1: Write the failing test**

```elixir
# test/predictex/fifa/players/cache_test.exs
defmodule Predictex.Fifa.Players.CacheTest do
  # async: false — the cache is a named singleton with a shared ETS table.
  use ExUnit.Case, async: false

  alias Predictex.Fifa.Players.Cache

  defp ok_source do
    fn ->
      {:ok,
       %{
         players: [
           %{"shortName" => "Neymar", "position" => 4, "stats" => %{"goals" => 2}, "squadId" => 7, "fifaId" => 1},
           %{"shortName" => "Alisson Becker", "position" => 1, "stats" => %{"goals" => 0}, "squadId" => 7, "fifaId" => 2}
         ],
         squads: [%{"id" => 7, "name" => "Brazil", "abbr" => "BRA"}]
       }}
    end
  end

  setup do
    # Cache is started by the app (warm disabled in test); reset between cases.
    Application.put_env(:predictex, :players_source_fun, ok_source())
    on_exit(fn -> Application.delete_env(:predictex, :players_source_fun) end)
    :ok
  end

  test "refresh/0 populates the cache and for_team/1 reads it" do
    assert Cache.refresh() == :ok
    assert Cache.for_team("Brazil") |> Enum.map(& &1.name) == ["Neymar", "Alisson Becker"]
    assert Cache.for_team("Brazil") |> hd() |> Map.get(:fifa_id) == 1
  end

  test "unknown team returns []" do
    Cache.refresh()
    assert Cache.for_team("Narnia") == []
  end

  test "a failing source leaves the cache usable (empty), no crash" do
    Application.put_env(:predictex, :players_source_fun, fn -> {:error, :boom} end)
    assert {:error, :boom} = Cache.refresh()
    assert Cache.for_team("Brazil") == []
    # GenServer still alive:
    assert Process.alive?(Process.whereis(Cache))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex/fifa/players/cache_test.exs`
Expected: FAIL — `Predictex.Fifa.Players.Cache` is not available / not started.

- [ ] **Step 3: Write the cache, supervise it, disable boot-warm in test**

```elixir
# lib/predictex/fifa/players/cache.ex
defmodule Predictex.Fifa.Players.Cache do
  @moduledoc """
  Supervised ETS cache of FIFA squads for the first-player picker (predictex-u4k).

  `for_team/1` reads the table lock-free in the caller; the first miss funnels through the
  GenServer owner (which re-checks a `:__loaded__` sentinel to guard against a thundering-herd
  double-load), fetches `players.json` + `squads.json` once, and repopulates. `refresh/0` is the
  same load forced (the cron `PlayersSync` worker calls it so `stats.goals` stays current).

  The table is `:set, :public, read_concurrency: true` — only the owner writes. The fetch source
  is injectable via `:players_source_fun` (network-free tests); boot-warm via `:warm_players_cache`.
  """
  use GenServer

  require Logger

  alias Predictex.Fifa.{Crosswalk, Players, Reference}

  @table __MODULE__
  @players_url "https://play.fifa.com/json/match_predictor/players.json"
  @squads_url "https://play.fifa.com/json/match_predictor/squads.json"

  ## Public API

  @doc "Squad list for `team` (alias-normalised). Lazy-loads on first miss; `[]` on unknown/failed."
  @spec for_team(String.t()) :: [map()]
  def for_team(team) do
    ensure_loaded()

    case :ets.lookup(@table, Crosswalk.norm(team)) do
      [{_key, players}] -> players
      [] -> []
    end
  end

  @doc "Force a re-fetch + repopulate. `:ok | {:error, reason}`."
  @spec refresh() :: :ok | {:error, term()}
  def refresh, do: GenServer.call(__MODULE__, :load, 30_000)

  @doc "Fetch `players.json` + `squads.json`. `{:ok, %{players, squads}} | {:error, reason}`."
  def fetch do
    with {:ok, players} <- Reference.get_json(@players_url),
         {:ok, squads} <- Reference.get_json(@squads_url) do
      {:ok, %{players: players, squads: squads}}
    end
  end

  ## GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, {:read_concurrency, true}])
    if Application.get_env(:predictex, :warm_players_cache, true), do: send(self(), :warm)
    {:ok, :no_state}
  end

  @impl GenServer
  def handle_info(:warm, state) do
    _ = load()
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:load, _from, state), do: {:reply, load(), state}

  def handle_call(:ensure, _from, state) do
    unless loaded?(), do: load()
    {:reply, :ok, state}
  end

  ## Internals

  defp ensure_loaded do
    if loaded?(), do: :ok, else: GenServer.call(__MODULE__, :ensure, 30_000)
  end

  defp loaded? do
    case :ets.lookup(@table, :__loaded__) do
      [{:__loaded__, true}] -> true
      [] -> false
    end
  end

  defp load do
    case source_fun().() do
      {:ok, %{players: players, squads: squads}} ->
        map = Players.parse(players, squads)
        :ets.delete_all_objects(@table)
        Enum.each(map, fn {team, list} -> :ets.insert(@table, {team, list}) end)
        :ets.insert(@table, {:__loaded__, true})
        Logger.info("players cache: #{map_size(map)} squads loaded")
        :ok

      {:error, reason} ->
        Logger.error("players cache load failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp source_fun, do: Application.get_env(:predictex, :players_source_fun, &fetch/0)
end
```

Add the cache to the supervision tree. In `lib/predictex/application.ex`, change the children assembly so it appends the cache:

```elixir
      ] ++ capture_subscribers() ++ replay_cache() ++ [Predictex.Fifa.Players.Cache]
```

Disable boot-warm in `config/test.exs` (add near the other `:predictex` test config):

```elixir
# The players cache is started by the app in tests; don't let it fetch the network on boot.
# Tests that exercise it inject `:players_source_fun` and call `refresh/0`/`for_team/1`.
config :predictex, warm_players_cache: false
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/predictex/fifa/players/cache_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/fifa/players/cache.ex lib/predictex/application.ex config/test.exs test/predictex/fifa/players/cache_test.exs
git commit -m "feat(fifa): supervised Players.Cache (lazy-load + boot-warm + refresh) (predictex-u4k)"
```

---

### Task 3: `Workers.PlayersSync` — cron refresh worker

**Files:**
- Create: `lib/predictex/workers/players_sync.ex`
- Modify: `config/config.exs` (add the cron entry)
- Test: `test/predictex/workers/players_sync_test.exs`

**Interfaces:**
- Consumes: `Predictex.Fifa.Players.Cache.refresh/0`.
- Produces: `Predictex.Workers.PlayersSync` Oban worker whose `perform/1` returns `:ok` (always — a failed refresh is logged inside the cache, and a stale cache is acceptable; the worker must not crash-loop the queue) — see Step 3 rationale.

- [ ] **Step 1: Write the failing test**

```elixir
# test/predictex/workers/players_sync_test.exs
defmodule Predictex.Workers.PlayersSyncTest do
  use Predictex.DataCase, async: false

  alias Predictex.Fifa.Players.Cache
  alias Predictex.Workers.PlayersSync

  test "perform/1 refreshes the cache from the injected source" do
    Application.put_env(:predictex, :players_source_fun, fn ->
      {:ok,
       %{
         players: [%{"shortName" => "Neymar", "position" => 4, "stats" => %{"goals" => 2}, "squadId" => 7, "fifaId" => 1}],
         squads: [%{"id" => 7, "name" => "Brazil", "abbr" => "BRA"}]
       }}
    end)

    on_exit(fn -> Application.delete_env(:predictex, :players_source_fun) end)

    assert :ok = perform_job(PlayersSync, %{})
    assert Cache.for_team("Brazil") |> Enum.map(& &1.name) == ["Neymar"]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex/workers/players_sync_test.exs`
Expected: FAIL — `Predictex.Workers.PlayersSync` is undefined.

- [ ] **Step 3: Write the worker + add the cron entry**

```elixir
# lib/predictex/workers/players_sync.ex
defmodule Predictex.Workers.PlayersSync do
  @moduledoc """
  Oban worker (cron, every 30 min) that refreshes the FIFA squads cache so the first-player
  picker's `stats.goals` track played matches (predictex-u4k). The roster itself is static;
  this is purely a freshness tick. A failed fetch is logged inside `Cache.refresh/0` and the
  stale cache is kept — so `perform/1` always returns `:ok` (no queue crash-loop for a flaky feed).
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Predictex.Fifa.Players.Cache

  @impl Oban.Worker
  def perform(_job) do
    _ = Cache.refresh()
    :ok
  end
end
```

In `config/config.exs`, add the entry to the `Oban.Plugins.Cron` `crontab` list (alongside the others around line 96-105):

```elixir
       {"*/30 * * * *", Predictex.Workers.PlayersSync}
```

(Add a trailing comma to the previous last entry as needed so the list stays valid.)

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/predictex/workers/players_sync_test.exs`
Expected: PASS (1 test). Also run `mise exec -- mix compile` to confirm the cron list parses (Oban validates the crontab at boot).

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/workers/players_sync.ex config/config.exs test/predictex/workers/players_sync_test.exs
git commit -m "feat(fifa): PlayersSync cron worker refreshes squads cache (predictex-u4k)"
```

---

### Task 4: Persist `first_scorer_fifaid` through the intake boundary

**Files:**
- Create: `priv/repo/migrations/<timestamp>_add_first_scorer_fifaid_to_predictions.exs` (generate with the mix task — see Step 1)
- Modify: `lib/predictex/predictions/prediction.ex` (schema field + cast)
- Modify: `lib/predictex/predictions.ex:408-417` (`build_row/3` — read the new param)
- Test: `test/predictex/predictions_test.exs` (add cases — find the existing `parse_pick_rows` describe block)

**Interfaces:**
- Consumes: the form param `attrs["first_scorer_fifaid"]` (a string or nil from the picker's sr-only input).
- Produces: pick rows now carry `first_scorer_fifaid: integer() | nil`; `Prediction` persists the column.

- [ ] **Step 1: Generate the migration and write it**

Run: `mise exec -- mix ecto.gen.migration add_first_scorer_fifaid_to_predictions`

Then write the generated file:

```elixir
# priv/repo/migrations/<timestamp>_add_first_scorer_fifaid_to_predictions.exs
defmodule Predictex.Repo.Migrations.AddFirstScorerFifaidToPredictions do
  use Ecto.Migration

  def change do
    alter table(:predictions) do
      add :first_scorer_fifaid, :integer
    end
  end
end
```

- [ ] **Step 2: Write the failing test**

In `test/predictex/predictions_test.exs`, inside the `parse_pick_rows` describe block, add:

```elixir
    test "carries first_scorer_fifaid (parsed to integer) into the row" do
      picks = %{
        "10" => %{
          "home_goals" => "1",
          "away_goals" => "0",
          "first_scorer_player" => "Neymar",
          "first_scorer_fifaid" => "100002"
        }
      }

      assert {:ok, [row]} = Predictions.parse_pick_rows(picks, nil)
      assert row.first_scorer_player == "Neymar"
      assert row.first_scorer_fifaid == 100_002
    end

    test "blank first_scorer_fifaid parses to nil" do
      picks = %{"10" => %{"home_goals" => "1", "away_goals" => "0", "first_scorer_fifaid" => ""}}
      assert {:ok, [row]} = Predictions.parse_pick_rows(picks, nil)
      assert row.first_scorer_fifaid == nil
    end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex/predictions_test.exs`
Expected: FAIL — row has no `:first_scorer_fifaid` key (`assert row.first_scorer_fifaid` raises `KeyError`).

- [ ] **Step 4: Add the field to the row, schema, and changeset**

In `lib/predictex/predictions.ex`, extend `build_row/3` (line 408-417) — add the line before `booster:`:

```elixir
      first_scorer_player: blank_to_nil(attrs["first_scorer_player"]),
      first_scorer_fifaid: parse_int(attrs["first_scorer_fifaid"]),
```

In `lib/predictex/predictions/prediction.ex`, add the schema field after `:first_scorer_player` (line 16):

```elixir
    field :first_scorer_fifaid, :integer
```

and add `:first_scorer_fifaid` to the `cast/3` field list (after `:first_scorer_player`, line 33):

```elixir
      :first_scorer_player,
      :first_scorer_fifaid,
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mise exec -- mix ecto.migrate && mise exec -- mix test test/predictex/predictions_test.exs`
Expected: PASS. (`MIX_ENV=test` migration runs automatically when `mix test` first creates the DB; the explicit `ecto.migrate` updates the dev DB.)

- [ ] **Step 6: Commit**

```bash
git add priv/repo/migrations lib/predictex/predictions.ex lib/predictex/predictions/prediction.ex test/predictex/predictions_test.exs
git commit -m "feat(predictions): persist first_scorer_fifaid from the intake boundary (predictex-u4k)"
```

---

### Task 5: Accent-fold scoring's `norm/1`

**Files:**
- Modify: `lib/predictex/scoring.ex:167-168` (`norm/1`)
- Test: `test/predictex/scoring_test.exs` (add cases — find the first-player describe block)

**Interfaces:**
- Consumes/Produces: internal `norm/1` — no signature change. Behaviour change: names now compare accent-insensitively, so a stored "Julián Álvarez" matches an actual "Julian Alvarez" (and vice-versa). This applies to **all** first-player scoring (member, admin, import), not just the picker.

- [ ] **Step 1: Write the failing test**

In `test/predictex/scoring_test.exs`, find where `first_player_points`/first-player scoring is tested and add:

```elixir
    test "first-player award is accent-insensitive (FIFA vs openfootball spelling)" do
      fixture = %{
        first_scorer_player: "Julian Alvarez",
        first_goal_owngoal: false,
        home_goals: 1,
        away_goals: 0,
        status: :completed,
        stage: :knockout
      }

      prediction = %{first_scorer_player: "Julián Álvarez", home_goals: 1, away_goals: 0}

      # The +10 first-player component must fire despite the accent difference.
      assert Scoring.score(prediction, fixture, :knockout).points >= 10
    end
```

> NOTE: match the exact `Scoring.score/3` call shape and the `%{components: …}`/`points` field the neighbouring tests use; adjust the fixture/prediction maps to the minimal fields those tests already pass. The assertion's job is only that the first-player +10 fires across an accent difference.

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex/scoring_test.exs`
Expected: FAIL — current `norm/1` is `trim + downcase`, so "julián álvarez" ≠ "julian alvarez", award is 0.

- [ ] **Step 3: Add accent-folding to `norm/1`**

In `lib/predictex/scoring.ex`, replace the binary clause of `norm/1` (line 168):

```elixir
  defp norm(nil), do: nil

  defp norm(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.replace(~r/\s+/u, " ")
  end
```

(`characters_to_nfd_binary` decomposes accented letters into base + combining mark; `\p{Mn}` strips the combining marks; the final replace collapses any whitespace. Structural divergences — mononyms like "Mbappé"→"Kylian Mbappé" — are out of scope here and handled by the deferred `fifaId`-exact scoring, `predictex-i9k`.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `mise exec -- mix test test/predictex/scoring_test.exs`
Expected: PASS — the new test plus all existing scoring tests (the fold is a superset of trim+downcase for ASCII names).

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/scoring.ex test/predictex/scoring_test.exs
git commit -m "feat(scoring): accent-fold first-player name match (predictex-u4k)"
```

---

### Task 6: Render the picker — squads assign + modal markup

**Files:**
- Modify: `lib/predictex_web/live/my_predictions_live.ex` (render assign + the editable KO card's "First scorer" section + a new private helper)
- Test: `test/predictex_web/live/my_predictions_live_test.exs` (add a `@tag :native_ko` render case)

**Interfaces:**
- Consumes: `Predictex.Fifa.Players.Cache.for_team/1`, the existing `@fixture_states`/`@active` assigns, `PredictexWeb.Flags`.
- Produces: a new assign `@squads :: %{fixture_id => %{team1: [player], team2: [player]}}` (editable KO fixtures only); a "First Player To Score" button + a per-fixture modal element carrying both squads' rows server-rendered (so a render test can assert names/goals are present). The hook (Task 7) toggles/searches/selects.

- [ ] **Step 1: Write the failing test**

In `test/predictex_web/live/my_predictions_live_test.exs`, add (mirror an existing `@tag :native_ko` editable-KO test for setup — enabling the flag, settling the predecessor, an editable R32 fixture with real team names; reuse that helper):

```elixir
  @tag :native_ko
  test "editable KO card renders the first-player picker with both squads", %{conn: conn} do
    # ... set up an editable R32 fixture Brazil v Argentina (reuse the existing native-KO setup) ...
    # Warm the players cache with a stub so the modal has rows to render:
    Application.put_env(:predictex, :players_source_fun, fn ->
      {:ok,
       %{
         players: [
           %{"shortName" => "Neymar", "position" => 4, "stats" => %{"goals" => 2}, "squadId" => 7, "fifaId" => 1},
           %{"shortName" => "Lionel Messi", "position" => 4, "stats" => %{"goals" => 3}, "squadId" => 2, "fifaId" => 9}
         ],
         squads: [
           %{"id" => 7, "name" => "Brazil", "abbr" => "BRA"},
           %{"id" => 2, "name" => "Argentina", "abbr" => "ARG"}
         ]
       }}
    end)

    on_exit(fn -> Application.delete_env(:predictex, :players_source_fun) end)
    Predictex.Fifa.Players.Cache.refresh()

    {:ok, _lv, html} = live(conn, ~p"/predictions")

    assert html =~ "First Player To Score"
    assert html =~ "Neymar"
    assert html =~ "Lionel Messi"
    assert html =~ "No first scorer"
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex_web/live/my_predictions_live_test.exs --only native_ko`
Expected: FAIL — "First Player To Score" / player names absent.

- [ ] **Step 3: Assign `@squads` and render the picker**

In `lib/predictex_web/live/my_predictions_live.ex`, change the render assigns block (lines 134-138) to compute `fixture_states` once and derive squads from it:

```elixir
    states = fixture_states(active, assigns.now)

    assigns =
      assigns
      |> assign(:active, active)
      |> assign(:native_ko_round?, native_ko_round?(active, assigns.current_scope.player))
      |> assign(:fixture_states, states)
      |> assign(:squads, squads_for(active, states))
```

Add the private helper (near `fixture_states/2`, ~line 515):

```elixir
  # Squads for the first-player picker — only editable KO fixtures need them. Reads the FIFA
  # squads cache (lazy-loads on first miss); a cold cache yields [] and the modal renders empty
  # (the card still saves a blank first-player, exactly as before the picker).
  defp squads_for(%{fixtures: fixtures}, states) do
    for fx <- fixtures, states[fx.fixture.id] == :editable, into: %{} do
      {fx.fixture.id,
       %{
         team1: Predictex.Fifa.Players.Cache.for_team(fx.fixture.team1),
         team2: Predictex.Fifa.Players.Cache.for_team(fx.fixture.team2)
       }}
    end
  end

  defp squads_for(_active, _states), do: %{}
```

In the editable card's "First scorer" section, after the two side-toggle buttons' closing `</div>` (after line 322, inside the `space-y-2` block), add the picker control + modal. Insert this block (it uses two new sr-only inputs the hook writes, plus a hidden modal):

```heex
                  <div class="flex items-center justify-between gap-2">
                    <span class="text-xs font-semibold text-base-content/60">First player</span>
                    <button
                      type="button"
                      data-picker-open
                      data-fixture={fx.fixture.id}
                      class="btn btn-xs btn-ghost"
                    >
                      <span data-picker-label={fx.fixture.id}>
                        {fx.prediction && fx.prediction.first_scorer_player || "First Player To Score"}
                      </span>
                    </button>
                  </div>
                  <input
                    type="text"
                    class="sr-only"
                    tabindex="-1"
                    aria-hidden="true"
                    name={"picks[#{fx.fixture.id}][first_scorer_player]"}
                    value={fx.prediction && fx.prediction.first_scorer_player}
                    data-player-input={fx.fixture.id}
                  />
                  <input
                    type="text"
                    class="sr-only"
                    tabindex="-1"
                    aria-hidden="true"
                    name={"picks[#{fx.fixture.id}][first_scorer_fifaid]"}
                    value={fx.prediction && fx.prediction.first_scorer_fifaid}
                    data-fifaid-input={fx.fixture.id}
                  />

                  <%!-- Hidden modal; the .RoundEntry hook toggles `hidden`, filters, and selects. --%>
                  <div
                    data-picker-modal={fx.fixture.id}
                    class="hidden fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
                  >
                    <div class="rounded-box bg-base-100 border border-base-content/10 w-full max-w-md max-h-[80vh] flex flex-col shadow-xl">
                      <div class="flex items-center justify-between gap-2 p-3 border-b border-base-content/10">
                        <span class="font-bold">Which player will score first?</span>
                        <button type="button" data-picker-close class="btn btn-xs btn-ghost">✕</button>
                      </div>
                      <div class="flex gap-1 p-2">
                        <button type="button" data-picker-team="team1" data-fixture={fx.fixture.id} class="btn btn-xs btn-primary flex-1">
                          {Flags.flag(fx.fixture.team1)} {fx.fixture.team1}
                        </button>
                        <button type="button" data-picker-team="team2" data-fixture={fx.fixture.id} class="btn btn-xs btn-ghost flex-1">
                          {Flags.flag(fx.fixture.team2)} {fx.fixture.team2}
                        </button>
                      </div>
                      <input type="text" data-picker-search class="input input-bordered input-sm mx-2 mb-2" placeholder="Search player…" />
                      <ul class="overflow-y-auto px-2 pb-3 space-y-1">
                        <li>
                          <button
                            type="button"
                            data-picker-select
                            data-name=""
                            data-fifaid=""
                            class="w-full text-left btn btn-ghost btn-sm justify-start"
                          >
                            No first scorer
                          </button>
                        </li>
                        <li :for={{side, players} <- [{"team1", @squads[fx.fixture.id][:team1] || []}, {"team2", @squads[fx.fixture.id][:team2] || []}]} :if={players != []} class="contents">
                          <ul data-picker-list={side} class={if side == "team1", do: "contents", else: "hidden"}>
                            <li :for={pl <- players}>
                              <button
                                type="button"
                                data-picker-select
                                data-name={pl.name}
                                data-fifaid={pl.fifa_id}
                                data-search={String.downcase(pl.name)}
                                class="w-full text-left btn btn-ghost btn-sm justify-between"
                              >
                                <span class="truncate">{pl.name}</span>
                                <span class="flex items-center gap-2 shrink-0 text-xs opacity-70">
                                  <span class="badge badge-ghost badge-xs">{pl.position}</span>
                                  <span class="font-score">{pl.goals}⚽</span>
                                </span>
                              </button>
                            </li>
                          </ul>
                        </li>
                      </ul>
                    </div>
                  </div>
```

> The original side-toggle (`data-scorer-*`) inputs stay — a member can set first-team and/or first-player. The `first_scorer_player` sr-only input here REPLACES needing a visible text field; it is written by the hook.

- [ ] **Step 4: Run the render test**

Run: `mise exec -- mix test test/predictex_web/live/my_predictions_live_test.exs --only native_ko`
Expected: PASS — names, "First Player To Score", and "No first scorer" present.

- [ ] **Step 5: Commit**

```bash
git add lib/predictex_web/live/my_predictions_live.ex test/predictex_web/live/my_predictions_live_test.exs
git commit -m "feat(web): first-player picker modal markup + squads assign (predictex-u4k)"
```

---

### Task 7: Wire the hook + verify the full save→score chain

**Files:**
- Modify: `lib/predictex_web/live/my_predictions_live.ex` (the `.RoundEntry` colocated hook, lines 422-496)
- Test: `test/predictex_web/live/my_predictions_live_test.exs` (a save-and-persist case driving the form params the hook produces)

**Interfaces:**
- Consumes: the markup data-attributes from Task 6 (`data-picker-open`, `data-picker-modal`, `data-picker-team`, `data-picker-search`, `data-picker-select`, `data-picker-close`, `data-player-input`, `data-fifaid-input`, `data-picker-label`, `data-picker-list`).
- Produces: on select, the hook writes the chosen `name`/`fifaid` into the two sr-only inputs and updates the button label; the existing `phx-submit="save_round"` then carries `picks[fid][first_scorer_player]` + `picks[fid][first_scorer_fifaid]` through `parse_pick_rows/2` → `save_round_predictions/5` (Task 4 persists both).

- [ ] **Step 1: Write the failing test (the chain the hook drives, simulated via form submit)**

In `test/predictex_web/live/my_predictions_live_test.exs`, add (the LiveView test can't run JS, so submit the params the hook would have written, asserting the server side of the contract):

```elixir
  @tag :native_ko
  test "saving a KO round persists the picked first-player name and fifaid", %{conn: conn} do
    # ... reuse the editable-KO setup: an editable R32 fixture, capture its id as `fixture_id`,
    #     the round id, and the logged-in member; warm the players cache as in Task 6 ...

    {:ok, lv, _html} = live(conn, ~p"/predictions")

    lv
    |> form("#round-entry-#{round_ordinal}", %{
      "picks" => %{
        "#{fixture_id}" => %{
          "home_goals" => "2",
          "away_goals" => "1",
          "first_scorer_side" => "home",
          "first_scorer_player" => "Neymar",
          "first_scorer_fifaid" => "1"
        }
      }
    })
    |> render_submit()

    pred = Predictex.Predictions.get_player_fixture_prediction(member.id, fixture_id)
    assert pred.first_scorer_player == "Neymar"
    assert pred.first_scorer_fifaid == 1
  end
```

> Confirm the exact getter name (`Predictions.get_player_fixture_prediction/2` or the equivalent the suite already uses) and the `form/3` selector (`#round-entry-<ordinal>`) against the existing native-KO save test, and reuse its setup helper verbatim for the fixture/round/member bindings.

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex_web/live/my_predictions_live_test.exs --only native_ko`
Expected: FAIL — `pred.first_scorer_fifaid` is nil (the hook/markup names are right, but verify Task 4's persistence is reached through the LiveView). If Task 4 is already merged this may pass on the persistence half; the value of this test is locking the **end-to-end** contract (form field names → DB) so a later markup rename can't silently break scoring.

- [ ] **Step 3: Extend the `.RoundEntry` hook to drive the picker**

In `lib/predictex_web/live/my_predictions_live.ex`, add these methods to the `.RoundEntry` hook object (inside the `export default { … }`, alongside `toggleScorer`/`toggleBooster`), and extend the `click`/`input` listeners in `mounted()`:

```javascript
          // --- first-player picker ---
          openPicker(fid) {
            const modal = this.el.querySelector(`[data-picker-modal="${fid}"]`)
            if (modal) { modal.classList.remove("hidden"); this.showTeam(fid, "team1") }
          },
          closePicker(modal) {
            if (modal) modal.classList.add("hidden")
          },
          showTeam(fid, side) {
            const modal = this.el.querySelector(`[data-picker-modal="${fid}"]`)
            if (!modal) return
            modal.querySelectorAll("[data-picker-list]").forEach((ul) => {
              ul.classList.toggle("hidden", ul.dataset.pickerList !== side)
              ul.classList.toggle("contents", ul.dataset.pickerList === side)
            })
            modal.querySelectorAll("[data-picker-team]").forEach((b) =>
              this.setPressed(b, b.dataset.pickerTeam === side))
            const search = modal.querySelector("[data-picker-search]")
            if (search) { search.value = ""; this.filterPicker(modal, "") }
          },
          filterPicker(modal, q) {
            const needle = q.toLowerCase()
            modal.querySelectorAll("[data-picker-select][data-search]").forEach((btn) => {
              const li = btn.closest("li")
              if (li) li.classList.toggle("hidden", !btn.dataset.search.includes(needle))
            })
          },
          selectPlayer(btn) {
            const modal = btn.closest("[data-picker-modal]")
            const fid = modal.dataset.pickerModal
            const card = btn.closest("[data-fixture-card]")
            card.querySelector(`[data-player-input="${fid}"]`).value = btn.dataset.name
            card.querySelector(`[data-fifaid-input="${fid}"]`).value = btn.dataset.fifaid
            const label = card.querySelector(`[data-picker-label="${fid}"]`)
            if (label) label.textContent = btn.dataset.name || "First Player To Score"
            this.closePicker(modal)
          },
```

In `mounted()`, replace the single `click` listener with one that also routes the picker controls:

```javascript
            this.el.addEventListener("click", (e) => {
              const open = e.target.closest("[data-picker-open]")
              if (open) { this.openPicker(open.dataset.fixture); return }
              const close = e.target.closest("[data-picker-close]")
              if (close) { this.closePicker(close.closest("[data-picker-modal]")); return }
              const team = e.target.closest("[data-picker-team]")
              if (team) { this.showTeam(team.dataset.fixture, team.dataset.pickerTeam); return }
              const sel = e.target.closest("[data-picker-select]")
              if (sel) { this.selectPlayer(sel); return }
              const scorer = e.target.closest("[data-scorer-btn]")
              if (scorer) { this.toggleScorer(scorer); return }
              const booster = e.target.closest("[data-booster-btn]")
              if (booster) { this.toggleBooster(booster) }
            })
```

And in the existing `input` listener, add a branch for the search box (before the goal-input handling, since it's a different element):

```javascript
            this.el.addEventListener("input", (e) => {
              const search = e.target.closest && e.target.closest("[data-picker-search]")
              if (search) {
                this.filterPicker(search.closest("[data-picker-modal]"), search.value)
                return
              }
              const el = e.target
              if (!el.matches || !el.matches("[data-goal-input]")) return
              // ... existing goal-input logic unchanged ...
```

- [ ] **Step 4: Run the test + the full gate**

Run: `mise exec -- mix test test/predictex_web/live/my_predictions_live_test.exs --only native_ko`
Expected: PASS.

Then the whole gate: `mise exec -- mix precommit`
Expected: compile (no warnings), format, credo --strict, and the full suite all green.

- [ ] **Step 5: Commit**

```bash
git add lib/predictex_web/live/my_predictions_live.ex test/predictex_web/live/my_predictions_live_test.exs
git commit -m "feat(web): first-player picker hook + end-to-end save chain (predictex-u4k)"
```

---

## Manual verification (before tagging `v0.11.21`)

1. `iex -S mix phx.server`, then in the IEx session: `FunWithFlags.enable(:native_ko_entry)` and `Predictex.Fifa.Players.Cache.refresh()`.
2. `mise exec -- mix predictex.preview_knockout` (opens R32 locally) → load `/predictions` as an admin → on an editable R32 card, click **First Player To Score** → the modal opens, team-toggle switches squads, search filters, selecting a player updates the button label, **No first scorer** clears it.
3. Submit the round → reload → the picked player persists and shows on the card.
4. Phone over Tailscale (per RESUME) for touch sanity: modal scrolls, search keyboard behaves, targets are tappable.

## Deploy (the user's explicit call — do NOT auto-tag)

- Bundles with the undeployed `dum` + tidy-up batch as `v0.11.21`. Run `scripts/pre-deploy` first.
- **Never tag mid-capture** — tag before the 20:00 UTC R32 kickoff (realistically ≤ ~19:30, ahead of the first match capturing).
- **Post-deploy: warm the cache immediately** so the first member doesn't pay the ~408 KB fetch at peak:
  `docker compose -f /root/predictex/docker-compose.prod.yml exec app bin/predictex rpc 'Predictex.Fifa.Players.Cache.refresh()'`
- No flag needed — member visibility rides the already-on `:native_ko_entry`. A cold cache degrades to an empty picker (still saves blank), so a missed warm is not a hard failure.

## Follow-ups (file as beads)

- **`predictex-i9k`** (exists) — `fifaId`-exact actual-side scoring: capture the FIFA first-scorer `IdPlayer` per fixture and match it against the stored `first_scorer_fifaid`, removing name-normalisation fragility for the structural-divergence cases (Mbappé/Rashford/Mac Allister). Needs the capture-side scorer-id pipeline; the `first_scorer_fifaid` column (Task 4) is the predictions-side half, already in place.
- Position-filter chips + player photos (deferred per spec; photos need a source `players.json` lacks).
```
