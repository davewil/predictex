# xox — FIFA prediction self-import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let each league member import their own FIFA Match Predictor group-stage picks (scoreline + booster) into predictex via a thin bookmarklet that hands a payload to an authenticated `/import` preview-and-confirm page.

**Architecture:** Server-side crosswalk. A thin bookmarklet collects `[{round, matchId, homeScore, awayScore, booster}]` from the member's logged-in `play.fifa.com` session and hands it (URL fragment, base64) to `/import` in the member's predictex session. The server fetches public `rounds.json`, resolves `{round, matchId} → (date, teams) → Fixture` through a shared pure `Fifa.Crosswalk`, and a pure `Fifa.Import.plan/3` partitions rows into matched/unmatched for a preview. On confirm, matched rows are written per round via the existing `Predictions.admin_save_round_predictions/3`.

**Tech Stack:** Elixir 1.20 / Phoenix 1.8 LiveView, Ecto/Postgres, Req (HTTP), Jason, Phoenix colocated JS hooks. Run all mix commands via `mise exec -- mix …`.

**Spec:** `docs/superpowers/specs/2026-06-16-xox-fifa-import-design.md`

---

## File structure

| File | Responsibility |
|------|----------------|
| `lib/predictex/fifa/crosswalk.ex` (create) | **Pure.** The one FIFA↔Fixture matching authority: `{utc_date, team-set}` key, verified `@aliases`, `norm/1`, `utc_date/1`, `index_fixtures/1`, `match_key/3`, `home_first?/2`. |
| `lib/predictex/fifa/cohort.ex` (modify) | Refactor to delegate matching to `Crosswalk` (no behaviour change; existing tests stay green). |
| `lib/predictex/fifa/reference.ex` (create) | **Effects.** Server fetch of FIFA public reference JSON. `fetch_rounds/0`, `get_json/1` (extracted from `CohortSync`). |
| `lib/predictex/workers/cohort_sync.ex` (modify) | Delegate its `get_json/1` to `Fifa.Reference` (DRY; tests use stub so unaffected). |
| `lib/predictex/fifa/import.ex` (create) | **Pure.** `decode_payload/1`, `plan/3` (matched/unmatched partition, composite `{round, matchId}` key, orientation), `to_write_rows/1`. |
| `lib/predictex_web/live/import_live.ex` (create) | Dumb LiveView at `/import`: awaiting → preview → done; paste + hook entry; confirm writes via `Predictions`. Colocated JS hook reads the URL fragment. |
| `lib/predictex_web/router.ex` (modify) | Add `live "/import", ImportLive, :index` to the `:require_authenticated_player` live_session. |
| `config/test.exs` (modify) | Add `:fifa_reference_fun` default stub. |
| `test/predictex/fifa/crosswalk_test.exs` (create) | Pure key/alias/orientation tests. |
| `test/predictex/fifa/import_test.exs` (create) | Pure `plan/3`/`decode_payload/1`/`to_write_rows/1` tests incl. composite-key + scoreline-orientation guards. |
| `test/predictex_web/live/import_live_test.exs` (create) | Auth gate, paste→preview→confirm flow, overwrite, unmatched, booster warning. |

---

## Task 1: Extract `Fifa.Crosswalk` and refactor `Cohort` onto it

**Files:**
- Create: `lib/predictex/fifa/crosswalk.ex`
- Create: `test/predictex/fifa/crosswalk_test.exs`
- Modify: `lib/predictex/fifa/cohort.ex`
- Test (regression): `test/predictex/fifa/cohort_test.exs` (unchanged — must stay green)

- [ ] **Step 1: Write the failing test** — `test/predictex/fifa/crosswalk_test.exs`

```elixir
defmodule Predictex.Fifa.CrosswalkTest do
  use ExUnit.Case, async: true

  alias Predictex.Fifa.Crosswalk
  alias Predictex.Tournament.Fixture

  defp fixture(id, team1, team2, kickoff),
    do: %Fixture{id: id, team1: team1, team2: team2, kickoff_at: kickoff, round_id: 1}

  test "match_key reduces an offset ISO date + team pair to {utc_date, unordered set}" do
    key = Crosswalk.match_key("2026-06-11T20:00:00+01:00", "Mexico", "South Africa")
    assert key == {~D[2026-06-11], MapSet.new(["mexico", "south africa"])}
  end

  test "match_key is order-independent on the team pair" do
    assert Crosswalk.match_key("2026-06-11T20:00:00+01:00", "Mexico", "South Africa") ==
             Crosswalk.match_key("2026-06-11T20:00:00+01:00", "South Africa", "Mexico")
  end

  test "match_key applies the FIFA->openfootball alias table" do
    # FIFA "Korea Republic" must key the same as openfootball "South Korea"
    fifa = Crosswalk.match_key("2026-06-15T18:00:00Z", "Korea Republic", "Czechia")
    ours = Crosswalk.match_key("2026-06-15T18:00:00Z", "South Korea", "Czech Republic")
    assert fifa == ours
  end

  test "index_fixtures keys fixtures by their match_key" do
    fx = fixture(7, "Mexico", "South Africa", ~U[2026-06-11 19:00:00Z])
    index = Crosswalk.index_fixtures([fx])
    assert Map.get(index, Crosswalk.match_key("2026-06-11T20:00:00+01:00", "Mexico", "South Africa")) == fx
  end

  test "home_first? is true when FIFA home matches our team1, false (swap) otherwise" do
    assert Crosswalk.home_first?("Mexico", "Mexico")
    assert Crosswalk.home_first?("Korea Republic", "South Korea")
    refute Crosswalk.home_first?("Iran", "Spain")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex/fifa/crosswalk_test.exs`
Expected: FAIL — `module Predictex.Fifa.Crosswalk is not available`.

- [ ] **Step 3: Create the module** — `lib/predictex/fifa/crosswalk.ex`

```elixir
defmodule Predictex.Fifa.Crosswalk do
  @moduledoc """
  Pure FIFA <-> Fixture matching authority. Shared by `Fifa.Cohort` (cohort %) and
  `Fifa.Import` (member predictions) so the match identity and the verified name-alias
  table live in exactly one place.

  Match identity is the `{utc_date, unordered team-set}` of a fixture vs a FIFA match
  (`rounds.json` `tournaments[]`). Group stage runs several matches per calendar date, so
  the team-set is part of the key, not a tiebreaker. Home/away is oriented by the
  first-listed-is-home convention (our `team1` == FIFA `homeSquadName`).
  """

  # FIFA -> openfootball normalized-name divergences, derived by diffing the live
  # squads.json vs worldcup.json feeds (the predictex-c9s shared artifact).
  @aliases %{
    "bosnia and herzegovina" => "bosnia & herzegovina",
    "cabo verde" => "cape verde",
    "congo dr" => "dr congo",
    "czechia" => "czech republic",
    "côte d'ivoire" => "ivory coast",
    "ir iran" => "iran",
    "korea republic" => "south korea",
    "türkiye" => "turkey"
  }

  @doc "Index fixtures by their match key for O(1) crosswalk lookup."
  def index_fixtures(fixtures) when is_list(fixtures),
    do: Map.new(fixtures, fn f -> {match_key(f.kickoff_at, f.team1, f.team2), f} end)

  @doc "The `{utc_date, MapSet of normalized names}` identity key."
  def match_key(datetime_or_iso, a, b),
    do: {utc_date(datetime_or_iso), MapSet.new([norm(a), norm(b)])}

  @doc "True when FIFA's home team is our `team1` (no swap needed)."
  def home_first?(fifa_home_name, fixture_team1),
    do: norm(fifa_home_name) == norm(fixture_team1)

  @doc "Lowercase, collapse whitespace, then apply the FIFA->openfootball alias."
  def norm(nil), do: ""

  def norm(name) when is_binary(name) do
    n = name |> String.downcase() |> String.trim() |> String.replace(~r/\s+/, " ")
    Map.get(@aliases, n, n)
  end

  # FIFA `date` is offset-bearing ISO8601 ("...+01:00"); fixture kickoff_at is UTC.
  # Both reduce to a UTC Date for the key.
  def utc_date(%DateTime{} = dt), do: DateTime.to_date(dt)

  def utc_date(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> DateTime.to_date(dt)
      _ -> nil
    end
  end

  def utc_date(_), do: nil
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/predictex/fifa/crosswalk_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Refactor `Cohort` to delegate to `Crosswalk`** — `lib/predictex/fifa/cohort.ex`

Replace the body so matching/aliasing/orientation come from `Crosswalk`. Replace the `@aliases`
attribute, the `plan/3` index + lookup, `orient/3`, `key/3`, `norm/1`, and the `utc_date` clauses
with the delegated versions below. Keep `complete?/1` and the module doc.

```elixir
  alias Predictex.Fifa.Crosswalk

  def plan(rounds, match_stats, fixtures)
      when is_list(rounds) and is_map(match_stats) and is_list(fixtures) do
    index = Crosswalk.index_fixtures(fixtures)

    rounds
    |> Enum.flat_map(fn r -> r["tournaments"] || [] end)
    |> Enum.flat_map(fn m ->
      stats = match_stats[to_string(m["id"])]
      fixture = Map.get(index, Crosswalk.match_key(m["date"], m["homeSquadName"], m["awaySquadName"]))

      if is_map(stats) and not is_nil(fixture) and complete?(stats),
        do: [orient(m, stats, fixture)],
        else: []
    end)
  end

  defp complete?(stats),
    do:
      not is_nil(stats["homeWin"]) and not is_nil(stats["draw"]) and not is_nil(stats["awayWin"])

  defp orient(m, stats, f) do
    {home, away} =
      if Crosswalk.home_first?(m["homeSquadName"], f.team1) do
        {stats["homeWin"], stats["awayWin"]}
      else
        Logger.warning(
          "cohort orientation swap for fixture #{f.id} (#{f.team1} v #{f.team2}); " <>
            "FIFA match_id=#{m["id"]} home=#{m["homeSquadName"]}"
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
```

Delete from `cohort.ex`: the `@aliases` module attribute and the now-unused private `key/3`,
`norm/1`, and `utc_date/*` clauses (they live in `Crosswalk` now). Keep `require Logger`.

- [ ] **Step 6: Run cohort regression + crosswalk tests**

Run: `mise exec -- mix test test/predictex/fifa/`
Expected: PASS — both `cohort_test.exs` (unchanged behaviour) and `crosswalk_test.exs`.

- [ ] **Step 7: Commit**

```bash
git add lib/predictex/fifa/crosswalk.ex lib/predictex/fifa/cohort.ex test/predictex/fifa/crosswalk_test.exs
git commit -m "refactor: extract Fifa.Crosswalk as shared FIFA<->Fixture matching authority (predictex-xox)"
```

---

## Task 2: `Fifa.Reference` server fetch + test stub

**Files:**
- Create: `lib/predictex/fifa/reference.ex`
- Modify: `lib/predictex/workers/cohort_sync.ex`
- Modify: `config/test.exs`

- [ ] **Step 1: Create the module** — `lib/predictex/fifa/reference.ex`

```elixir
defmodule Predictex.Fifa.Reference do
  @moduledoc """
  Server-side fetch of FIFA's PUBLIC static reference JSON (no auth, CDN-cached). Only the
  `/api/...` prediction endpoints are Akamai/cookie gated; `/json/...` is plain-fetchable.

  `fetch_rounds/0` is the crosswalk source for `Fifa.Import`; `get_json/1` is the shared
  HTTP helper reused by `Workers.CohortSync`.
  """
  @rounds_url "https://play.fifa.com/json/match_predictor/rounds.json"

  @doc "Fetch `rounds.json`. Returns `{:ok, rounds_list} | {:error, reason}`."
  def fetch_rounds, do: get_json(@rounds_url)

  @doc "GET a URL and return decoded JSON. `{:ok, map | list} | {:error, reason}`."
  def get_json(url) do
    {:ok, _} = Application.ensure_all_started(:req)

    case Req.get(url, receive_timeout: 15_000) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) or is_list(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        Jason.decode(body)

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

- [ ] **Step 2: Point `CohortSync` at the shared helper** — `lib/predictex/workers/cohort_sync.ex`

Replace the private `get_json/1` definition (lines ~42-61) with a delegation, and keep the rest:

```elixir
  defp get_json(url), do: Predictex.Fifa.Reference.get_json(url)
```

(Leave `@rounds_url`/`@stats_url`, `fetch/0`, `perform/1`, `commit/2`, `source_fun/0` as-is.)

- [ ] **Step 3: Add the test stub** — `config/test.exs` (next to `:cohort_source_fun`)

```elixir
config :predictex, :fifa_reference_fun, fn -> {:ok, []} end
```

- [ ] **Step 4: Run the cohort worker + full fifa tests to confirm no regression**

Run: `mise exec -- mix test test/predictex/fifa/ test/predictex/workers/`
Expected: PASS (CohortSync tests use `:cohort_source_fun`, so the `get_json` delegation is exercised only structurally; nothing breaks).

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/fifa/reference.ex lib/predictex/workers/cohort_sync.ex config/test.exs
git commit -m "refactor: extract Fifa.Reference for shared FIFA JSON fetch + import stub (predictex-xox)"
```

---

## Task 3: `Fifa.Import` pure core (`decode_payload`, `plan/3`, `to_write_rows`)

**Files:**
- Create: `lib/predictex/fifa/import.ex`
- Create: `test/predictex/fifa/import_test.exs`

- [ ] **Step 1: Write the failing tests** — `test/predictex/fifa/import_test.exs`

```elixir
defmodule Predictex.Fifa.ImportTest do
  use ExUnit.Case, async: true

  alias Predictex.Fifa.Import
  alias Predictex.Tournament.Fixture

  defp fixture(id, team1, team2, kickoff, round_id),
    do: %Fixture{id: id, team1: team1, team2: team2, kickoff_at: kickoff, round_id: round_id}

  defp fifa_match(id, home, away, date),
    do: %{"id" => id, "homeSquadName" => home, "awaySquadName" => away, "date" => date}

  defp round(round_id, matches), do: %{"id" => round_id, "stage" => "group", "tournaments" => matches}

  defp payload_row(round, match_id, hs, as, booster),
    do: %{"round" => round, "matchId" => match_id, "homeScore" => hs, "awayScore" => as, "booster" => booster}

  describe "decode_payload/1" do
    test "decodes a base64url JSON array of rows" do
      rows = [payload_row(1, 1, 2, 0, true)]
      b64 = rows |> Jason.encode!() |> Base.url_encode64(padding: false)
      assert {:ok, ^rows} = Import.decode_payload(b64)
    end

    test "rejects non-base64 input" do
      assert {:error, :bad_payload} = Import.decode_payload("not base64 !!!")
    end

    test "rejects valid base64 that is not a JSON array" do
      b64 = "{}" |> Base.url_encode64(padding: false)
      assert {:error, :bad_payload} = Import.decode_payload(b64)
    end
  end

  describe "plan/3" do
    test "matches a group row to its fixture (positional, no swap)" do
      fx = fixture(7, "Mexico", "South Africa", ~U[2026-06-11 19:00:00Z], 1)
      rounds = [round(1, [fifa_match(1, "Mexico", "South Africa", "2026-06-11T20:00:00+01:00")])]

      %{matched: [m], unmatched: []} = Import.plan([payload_row(1, 1, 2, 0, true)], rounds, [fx])

      assert m == %{
               fixture_id: 7,
               team1: "Mexico",
               team2: "South Africa",
               home_goals: 2,
               away_goals: 0,
               booster: true,
               round_id: 1
             }
    end

    test "scoreline follows the FIFA home team across an orientation swap" do
      # Our fixture lists Spain first (home); FIFA lists Iran first (home). FIFA Iran 1 - 3 Spain.
      fx = fixture(9, "Spain", "Iran", ~U[2026-06-20 19:00:00Z], 1)
      rounds = [round(1, [fifa_match(5, "Iran", "Spain", "2026-06-20T20:00:00+01:00")])]

      %{matched: [m]} = Import.plan([payload_row(1, 5, 1, 3, false)], rounds, [fx])
      # Our home is Spain = FIFA away; Spain's 3 must land in home_goals.
      assert m.home_goals == 3
      assert m.away_goals == 1
    end

    test "composite {round, matchId} key: same matchId in different rounds maps to distinct fixtures" do
      fx1 = fixture(1, "Mexico", "South Africa", ~U[2026-06-11 19:00:00Z], 1)
      fx2 = fixture(2, "Brazil", "Serbia", ~U[2026-06-18 19:00:00Z], 2)

      rounds = [
        round(1, [fifa_match(1, "Mexico", "South Africa", "2026-06-11T20:00:00+01:00")]),
        round(2, [fifa_match(1, "Brazil", "Serbia", "2026-06-18T20:00:00+01:00")])
      ]

      payload = [payload_row(1, 1, 2, 0, false), payload_row(2, 1, 1, 1, false)]
      %{matched: matched} = Import.plan(payload, rounds, [fx1, fx2])

      by_fixture = Map.new(matched, &{&1.fixture_id, &1})
      assert by_fixture[1].home_goals == 2
      assert by_fixture[2].home_goals == 1
    end

    test "unmatched reasons: unknown_match_id, out_of_scope, invalid, no_fixture" do
      fx = fixture(7, "Mexico", "South Africa", ~U[2026-06-11 19:00:00Z], 1)
      rounds = [round(1, [fifa_match(1, "Mexico", "South Africa", "2026-06-11T20:00:00+01:00")])]

      # unknown_match_id: round 1 has no matchId 999
      assert %{unmatched: [%{reason: :unknown_match_id}]} =
               Import.plan([payload_row(1, 999, 1, 0, false)], rounds, [fx])

      # out_of_scope: round 4 is a knockout round, not imported in this cut
      assert %{unmatched: [%{reason: :out_of_scope}]} =
               Import.plan([payload_row(4, 1, 1, 0, false)], rounds, [fx])

      # invalid: one score is nil
      assert %{unmatched: [%{reason: :invalid}]} =
               Import.plan([payload_row(1, 1, nil, 0, false)], rounds, [fx])

      # no_fixture: the match exists in rounds.json but no fixture has that date+team-set
      rounds_only = [round(1, [fifa_match(2, "Qatar", "Ecuador", "2026-06-12T20:00:00+01:00")])]
      assert %{unmatched: [%{reason: :no_fixture}]} =
               Import.plan([payload_row(1, 2, 1, 0, false)], rounds_only, [fx])
    end

    test "unmatched row carries booster so the UI can warn" do
      rounds = [round(1, [])]
      %{unmatched: [u]} = Import.plan([payload_row(1, 999, 2, 0, true)], rounds, [])
      assert u.booster == true
      assert u.reason == :unknown_match_id
    end
  end

  describe "to_write_rows/1" do
    test "groups matched entries by round_id, stripped to the write contract" do
      matched = [
        %{fixture_id: 7, team1: "A", team2: "B", home_goals: 2, away_goals: 0, booster: true, round_id: 1},
        %{fixture_id: 8, team1: "C", team2: "D", home_goals: 1, away_goals: 1, booster: false, round_id: 1},
        %{fixture_id: 9, team1: "E", team2: "F", home_goals: 0, away_goals: 0, booster: false, round_id: 2}
      ]

      grouped = Import.to_write_rows(matched)
      assert grouped[1] == [
               %{fixture_id: 7, home_goals: 2, away_goals: 0, booster: true},
               %{fixture_id: 8, home_goals: 1, away_goals: 1, booster: false}
             ]
      assert grouped[2] == [%{fixture_id: 9, home_goals: 0, away_goals: 0, booster: false}]
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mise exec -- mix test test/predictex/fifa/import_test.exs`
Expected: FAIL — `module Predictex.Fifa.Import is not available`.

- [ ] **Step 3: Create the module** — `lib/predictex/fifa/import.ex`

```elixir
defmodule Predictex.Fifa.Import do
  @moduledoc """
  Pure core for member FIFA prediction import (group-stage scoreline + booster).

  `plan/3` partitions a decoded payload into `matched` (resolved to a Fixture, oriented to our
  home/away) and `unmatched` (with a reason). Lookup is keyed by the composite `{round, matchId}`
  against `rounds.json` — never a flat `matchId` map — because FIFA `tournaments[].id` may repeat
  per round; a flat map could resolve to the wrong real fixture and silently corrupt a result.

  No DB, no network. The edge (`ImportLive`) supplies `rounds` (via `Fifa.Reference`) and
  `fixtures` (via `Tournament`).
  """
  require Logger

  alias Predictex.Fifa.Crosswalk

  @group_rounds 1..3

  @doc "Decode a base64url-encoded JSON array of payload rows. `{:ok, rows} | {:error, :bad_payload}`."
  def decode_payload(b64) when is_binary(b64) do
    with {:ok, json} <- url_decode(b64),
         {:ok, rows} when is_list(rows) <- Jason.decode(json) do
      {:ok, rows}
    else
      _ -> {:error, :bad_payload}
    end
  end

  defp url_decode(b64) do
    case Base.url_decode64(b64, padding: false) do
      {:ok, bin} -> {:ok, bin}
      :error -> :error
    end
  end

  @doc """
  Partition payload rows into `%{matched: [...], unmatched: [...]}`.

  A matched entry: `%{fixture_id, team1, team2, home_goals, away_goals, booster, round_id}`
  (`team1`/`team2` are for preview display only). An unmatched entry:
  `%{round, matchId, booster, reason}` with reason in
  `:out_of_scope | :unknown_match_id | :no_fixture | :invalid`.
  """
  def plan(payload_rows, rounds, fixtures)
      when is_list(payload_rows) and is_list(rounds) and is_list(fixtures) do
    index = Crosswalk.index_fixtures(fixtures)
    matches = build_match_index(rounds)

    {matched, unmatched} =
      Enum.reduce(payload_rows, {[], []}, fn row, {m, u} ->
        case resolve(row, matches, index) do
          {:ok, entry} -> {[entry | m], u}
          {:error, reason} -> {m, [unmatched_entry(row, reason) | u]}
        end
      end)

    %{matched: Enum.reverse(matched), unmatched: Enum.reverse(unmatched)}
  end

  defp build_match_index(rounds) do
    for r <- rounds, m <- r["tournaments"] || [], into: %{} do
      {{r["id"], m["id"]}, m}
    end
  end

  defp resolve(row, matches, index) do
    round = row["round"]
    match_id = row["matchId"]

    cond do
      round not in @group_rounds ->
        {:error, :out_of_scope}

      is_nil(match = Map.get(matches, {round, match_id})) ->
        {:error, :unknown_match_id}

      true ->
        key = Crosswalk.match_key(match["date"], match["homeSquadName"], match["awaySquadName"])

        case Map.get(index, key) do
          nil -> {:error, :no_fixture}
          fixture -> build_matched(row, match, fixture)
        end
    end
  end

  defp build_matched(row, match, fixture) do
    hs = row["homeScore"]
    as = row["awayScore"]

    if is_integer(hs) and is_integer(as) do
      {home_goals, away_goals} =
        if Crosswalk.home_first?(match["homeSquadName"], fixture.team1) do
          {hs, as}
        else
          Logger.info("import orientation swap for fixture #{fixture.id} (#{fixture.team1} v #{fixture.team2})")
          {as, hs}
        end

      {:ok,
       %{
         fixture_id: fixture.id,
         team1: fixture.team1,
         team2: fixture.team2,
         home_goals: home_goals,
         away_goals: away_goals,
         booster: row["booster"] == true,
         round_id: fixture.round_id
       }}
    else
      {:error, :invalid}
    end
  end

  defp unmatched_entry(row, reason),
    do: %{round: row["round"], matchId: row["matchId"], booster: row["booster"] == true, reason: reason}

  @doc "Group matched entries by `round_id`, stripped to the `save_round_row/3` write contract."
  def to_write_rows(matched) when is_list(matched) do
    matched
    |> Enum.group_by(& &1.round_id, fn m ->
      %{fixture_id: m.fixture_id, home_goals: m.home_goals, away_goals: m.away_goals, booster: m.booster}
    end)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mise exec -- mix test test/predictex/fifa/import_test.exs`
Expected: PASS. (The `payload`/`with_no_fixture_date` lines in the reasons test are inert scaffolding; the focused `assert`s below them are what matter.)

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/fifa/import.ex test/predictex/fifa/import_test.exs
git commit -m "feat: Fifa.Import pure core — payload decode + composite-key crosswalk plan (predictex-xox)"
```

---

## Task 4: `ImportLive` — paste → preview → confirm flow + route

**Files:**
- Create: `lib/predictex_web/live/import_live.ex`
- Modify: `lib/predictex_web/router.ex`
- Create: `test/predictex_web/live/import_live_test.exs`

This task builds the LiveView's server logic and the **paste-JSON path** (the path tests can drive — LiveViewTest does not run JS hooks). The bookmarklet + colocated fragment hook are Task 5.

- [ ] **Step 1: Add the route** — `lib/predictex_web/router.ex`

In the existing `live_session :require_authenticated_player` block (the one containing
`live "/predictions", MyPredictionsLive, :index`), add:

```elixir
      live "/import", ImportLive, :index
```

- [ ] **Step 2: Write the failing LiveView tests** — `test/predictex_web/live/import_live_test.exs`

```elixir
defmodule PredictexWeb.ImportLiveTest do
  use PredictexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  alias Predictex.{Predictions, Tournament}

  defp group_round(ordinal) do
    {:ok, r} = Tournament.create_round(%{name: "Matchday #{ordinal}", stage: :group, ordinal: ordinal})
    r
  end

  defp fixture!(round, team1, team2, kickoff) do
    {:ok, f} =
      Tournament.create_fixture(%{
        external_ref: "ref-#{System.unique_integer([:positive])}",
        team1: team1,
        team2: team2,
        status: :scheduled,
        kickoff_at: kickoff,
        round_id: round.id
      })

    f
  end

  # rounds.json shape for the stub: FIFA round id -> tournaments[]
  defp fifa_round(id, matches), do: %{"id" => id, "stage" => "group", "tournaments" => matches}
  defp fifa_match(id, home, away, date), do: %{"id" => id, "homeSquadName" => home, "awaySquadName" => away, "date" => date}

  defp stub_rounds(rounds) do
    prev = Application.get_env(:predictex, :fifa_reference_fun)
    Application.put_env(:predictex, :fifa_reference_fun, fn -> {:ok, rounds} end)
    on_exit(fn -> Application.put_env(:predictex, :fifa_reference_fun, prev) end)
  end

  defp paste_json(rows), do: Jason.encode!(rows)

  test "redirects to login when logged out", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/players/log-in"}}} = live(conn, ~p"/import")
  end

  describe "authenticated import" do
    setup :register_and_log_in_player

    test "paste -> preview shows matched picks, then confirm writes them for the member", ctx do
      %{conn: conn, player: player} = ctx
      round = group_round(1)
      fx = fixture!(round, "Mexico", "South Africa", ~U[2026-06-11 19:00:00Z])

      stub_rounds([fifa_round(1, [fifa_match(1, "Mexico", "South Africa", "2026-06-11T20:00:00+01:00")])])

      {:ok, view, _html} = live(conn, ~p"/import")

      rows = [%{"round" => 1, "matchId" => 1, "homeScore" => 2, "awayScore" => 0, "booster" => true}]

      html =
        view
        |> form("#paste-form", paste: %{json: paste_json(rows)})
        |> render_submit()

      assert html =~ "Mexico"
      assert html =~ "South Africa"

      render_click(view, "confirm", %{})

      [pred] = Predictions.list_player_predictions(player.id)
      assert pred.fixture_id == fx.id
      assert pred.home_goals == 2
      assert pred.away_goals == 0
      assert pred.booster == true
    end

    test "import overwrites an existing pick for the same fixture", ctx do
      %{conn: conn, player: player} = ctx
      round = group_round(1)
      fx = fixture!(round, "Mexico", "South Africa", ~U[2026-06-11 19:00:00Z])

      {:ok, _} =
        Predictions.admin_upsert_prediction(%{
          player_id: player.id, fixture_id: fx.id, home_goals: 0, away_goals: 0, booster: false
        })

      stub_rounds([fifa_round(1, [fifa_match(1, "Mexico", "South Africa", "2026-06-11T20:00:00+01:00")])])
      {:ok, view, _} = live(conn, ~p"/import")

      rows = [%{"round" => 1, "matchId" => 1, "homeScore" => 3, "awayScore" => 1, "booster" => false}]
      view |> form("#paste-form", paste: %{json: paste_json(rows)}) |> render_submit()
      render_click(view, "confirm", %{})

      [pred] = Predictions.list_player_predictions(player.id)
      assert pred.home_goals == 3
      assert pred.away_goals == 1
    end

    test "unmatched rows render with a reason and do not block matched", ctx do
      %{conn: conn} = ctx
      round = group_round(1)
      _fx = fixture!(round, "Mexico", "South Africa", ~U[2026-06-11 19:00:00Z])

      stub_rounds([fifa_round(1, [fifa_match(1, "Mexico", "South Africa", "2026-06-11T20:00:00+01:00")])])
      {:ok, view, _} = live(conn, ~p"/import")

      rows = [
        %{"round" => 1, "matchId" => 1, "homeScore" => 2, "awayScore" => 0, "booster" => false},
        %{"round" => 1, "matchId" => 999, "homeScore" => 1, "awayScore" => 1, "booster" => false}
      ]

      html = view |> form("#paste-form", paste: %{json: paste_json(rows)}) |> render_submit()
      assert html =~ "Mexico"
      assert html =~ "couldn&#39;t match" or html =~ "couldn't match"
    end

    test "booster on an unmatched row shows the warning", ctx do
      %{conn: conn} = ctx
      round = group_round(1)
      _fx = fixture!(round, "Mexico", "South Africa", ~U[2026-06-11 19:00:00Z])

      stub_rounds([fifa_round(1, [fifa_match(1, "Mexico", "South Africa", "2026-06-11T20:00:00+01:00")])])
      {:ok, view, _} = live(conn, ~p"/import")

      rows = [%{"round" => 1, "matchId" => 999, "homeScore" => 2, "awayScore" => 0, "booster" => true}]
      html = view |> form("#paste-form", paste: %{json: paste_json(rows)}) |> render_submit()
      assert html =~ "booster"
    end

    test "malformed paste keeps the awaiting state with an error", ctx do
      %{conn: conn} = ctx
      stub_rounds([])
      {:ok, view, _} = live(conn, ~p"/import")

      html = view |> form("#paste-form", paste: %{json: "not json"}) |> render_submit()
      assert html =~ "could not read"
    end
  end
end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mise exec -- mix test test/predictex_web/live/import_live_test.exs`
Expected: FAIL — `ImportLive` undefined / route not found.

- [ ] **Step 4: Create the LiveView** — `lib/predictex_web/live/import_live.ex`

```elixir
defmodule PredictexWeb.ImportLive do
  @moduledoc """
  Member self-import of FIFA group-stage picks. A thin bookmarklet (Task 5) hands a base64
  payload via the URL fragment; this LiveView also accepts a pasted JSON array as a fallback.
  Both feed the pure `Fifa.Import.plan/3`. Dumb view: the pure core validates; the view renders
  and, on confirm, writes via `Predictions.admin_save_round_predictions/3` for the current member.
  """
  use PredictexWeb, :live_view

  alias Predictex.Fifa.Import
  alias Predictex.{Predictions, Tournament}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(step: :awaiting, matched: [], unmatched: [], error: nil, summary: nil)}
  end

  @impl true
  def handle_event("paste", %{"paste" => %{"json" => raw}}, socket) do
    case Jason.decode(raw) do
      {:ok, rows} when is_list(rows) -> preview(socket, rows)
      _ -> {:noreply, assign(socket, error: "We could not read that — paste the JSON the bookmarklet produced.")}
    end
  end

  # Entry from the colocated fragment hook (Task 5): a base64url payload string.
  def handle_event("payload", %{"data" => b64}, socket) do
    case Import.decode_payload(b64) do
      {:ok, rows} -> preview(socket, rows)
      {:error, _} -> {:noreply, assign(socket, error: "We could not read the import payload. Try the paste box below.")}
    end
  end

  def handle_event("confirm", _params, socket) do
    player_id = socket.assigns.current_scope.player.id

    summary =
      socket.assigns.matched
      |> Import.to_write_rows()
      |> Enum.reduce(%{imported: 0, errors: 0}, fn {round_id, rows}, acc ->
        case Predictions.admin_save_round_predictions(player_id, round_id, rows) do
          {:ok, results} ->
            imported = Enum.count(results, fn {_id, r} -> r == :upserted end)
            %{acc | imported: acc.imported + imported}

          {:error, _} ->
            %{acc | errors: acc.errors + 1}
        end
      end)

    {:noreply, assign(socket, step: :done, summary: summary)}
  end

  defp preview(socket, rows) do
    case reference_fun().() do
      {:ok, rounds} ->
        %{matched: matched, unmatched: unmatched} = Import.plan(rows, rounds, Tournament.list_fixtures())

        {:noreply,
         assign(socket,
           step: :preview,
           matched: matched,
           unmatched: unmatched,
           error: nil,
           booster_unmatched: Enum.any?(unmatched, & &1.booster)
         )}

      {:error, _} ->
        {:noreply, assign(socket, error: "Couldn't reach FIFA reference data. Try again, or use the paste box.")}
    end
  end

  defp reference_fun,
    do: Application.get_env(:predictex, :fifa_reference_fun, &Predictex.Fifa.Reference.fetch_rounds/0)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-2xl">
        <h1 class="text-2xl font-bold mb-4">Import your FIFA picks</h1>

        <p :if={@error} class="alert alert-error mb-4">{@error}</p>

        <div :if={@step == :awaiting}>
          <p class="mb-4">
            Paste the JSON your import bookmarklet produced, then preview before saving.
          </p>
          <.paste_form />
        </div>

        <div :if={@step == :preview}>
          <p :if={assigns[:booster_unmatched]} class="alert alert-warning mb-4">
            Your booster is on a match we couldn't import — saving this round will leave you
            without a booster. Fix the unmatched row on FIFA, or proceed knowingly.
          </p>

          <p class="mb-2 font-semibold">
            This will overwrite your existing picks for these {length(@matched)} matches:
          </p>
          <ul class="mb-4">
            <li :for={m <- @matched}>
              {m.team1} {m.home_goals}–{m.away_goals} {m.team2}{if m.booster, do: " ⚡"}
            </li>
          </ul>

          <div :if={@unmatched != []} class="mb-4">
            <p class="font-semibold">We couldn't match these rows:</p>
            <ul>
              <li :for={u <- @unmatched}>round {u.round}, match {u.matchId} — {reason_text(u.reason)}</li>
            </ul>
          </div>

          <button class="btn btn-primary" phx-click="confirm" disabled={@matched == []}>
            Confirm import
          </button>
        </div>

        <div :if={@step == :done}>
          <p class="alert alert-success">
            Imported {@summary.imported} picks{if @summary.errors > 0, do: " (#{@summary.errors} errors)"}.
          </p>
          <.link navigate={~p"/predictions"} class="btn">See my predictions</.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp paste_form(assigns) do
    ~H"""
    <form id="paste-form" phx-submit="paste">
      <textarea name="paste[json]" rows="6" class="textarea textarea-bordered w-full"
                placeholder="[{&quot;round&quot;:1,&quot;matchId&quot;:1,&quot;homeScore&quot;:2,&quot;awayScore&quot;:0,&quot;booster&quot;:true}]"></textarea>
      <button type="submit" class="btn btn-primary mt-2">Preview</button>
    </form>
    """
  end

  defp reason_text(:unknown_match_id), do: "couldn't match this FIFA match"
  defp reason_text(:no_fixture), do: "couldn't match the teams/date to a fixture"
  defp reason_text(:out_of_scope), do: "knockout rounds aren't imported yet"
  defp reason_text(:invalid), do: "the scoreline was incomplete"
  end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mise exec -- mix test test/predictex_web/live/import_live_test.exs`
Expected: PASS (6 tests). If the `couldn't match`/HTML-entity assertion is brittle, adjust the test to match `reason_text/1` output verbatim.

- [ ] **Step 6: Commit**

```bash
git add lib/predictex_web/live/import_live.ex lib/predictex_web/router.ex test/predictex_web/live/import_live_test.exs
git commit -m "feat: ImportLive preview/confirm flow + paste fallback + /import route (predictex-xox)"
```

---

## Task 5: The bookmarklet + colocated fragment hook + awaiting-page instructions

**Files:**
- Modify: `lib/predictex_web/live/import_live.ex` (awaiting-state instructions + colocated hook)

The bookmarklet runs on `play.fifa.com`, collects the member's group-round predictions, and opens
`/import#<base64>`. A colocated JS hook on the `/import` page reads the fragment and pushes it to
the LiveView. This task has **no automated test** — the assembled bookmarklet in a live FIFA session
is validated manually in Task 6.

- [ ] **Step 1: Add the colocated fragment hook + bookmarklet UI to the awaiting block**

In `import_live.ex`, replace the `@step == :awaiting` `<div>` with the version below, and add the
colocated hook `<script>` (mirrors the existing `.CopyWhatsApp` hook in `leaderboard_live.ex`). The
hook reads `location.hash`, pushes a `"payload"` event, then clears the hash.

```heex
        <div :if={@step == :awaiting} id="import-root" phx-hook=".FifaFragment">
          <ol class="list-decimal ml-5 mb-4 space-y-1">
            <li>Log in to predictex (you already are) and to the FIFA Match Predictor.</li>
            <li>Drag this button to your bookmarks bar: <a href={bookmarklet()} class="btn btn-sm">Import FIFA picks</a></li>
            <li>Open the FIFA Match Predictor, then click the bookmark. It opens this page with your picks ready to preview.</li>
          </ol>
          <p class="mb-2 text-sm opacity-70">
            If the bookmarklet is blocked, run it in the browser console and paste the JSON it prints here:
          </p>
          <.paste_form />
        </div>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".FifaFragment">
          export default {
            mounted() {
              const hash = window.location.hash.slice(1)
              if (hash) {
                this.pushEvent("payload", {data: hash})
                history.replaceState(null, "", window.location.pathname)
              }
            }
          }
        </script>
```

- [ ] **Step 2: Add the `bookmarklet/0` helper** to `import_live.ex` (above `reason_text/1`)

The bookmarklet: fetch rounds 1..3 of the authed prediction endpoint, await all, flatten to the
thin payload, base64url-encode, open `/import#<payload>`. The payload carries **only ints + bool**
(no team names), so `btoa` is ASCII-safe.

```elixir
  @import_url "https://wc-predict.davewil.dev/import"

  defp bookmarklet do
    js = """
    (async () => {
      const base = 'https://play.fifa.com/api/en/match-predictor/prediction/show/';
      let rows = [];
      for (let r = 1; r <= 3; r++) {
        try {
          const res = await fetch(base + r, {credentials: 'include'});
          const json = await res.json();
          const preds = (json && json.success && json.success.predictions) || [];
          for (const p of preds) {
            rows.push({round: r, matchId: p.matchId, homeScore: p.homeScore, awayScore: p.awayScore, booster: !!p.booster});
          }
        } catch (e) {}
      }
      const b64 = btoa(JSON.stringify(rows)).replace(/\\+/g, '-').replace(/\\//g, '_').replace(/=+$/, '');
      window.open('#{@import_url}#' + b64, '_blank');
    })();
    """

    # Encode aggressively: a bare '#' or space in a javascript: href would break it, and
    # URI.encode/1 leaves reserved chars (incl. '#') alone. char_unreserved? escapes them.
    "javascript:" <> URI.encode(js, &URI.char_unreserved?/1)
  end
```

- [ ] **Step 3: Compile and run the full suite** (the page must still render; hooks are compiled by esbuild)

Run: `mise exec -- mix test test/predictex_web/live/import_live_test.exs`
Expected: PASS (awaiting state now renders the instructions + bookmarklet; existing assertions unaffected).

- [ ] **Step 4: Verify the colocated hook compiles into the bundle**

Run: `mise exec -- mix assets.build`
Expected: builds without error; `_build/dev/phoenix-colocated/predictex/` contains the new hook.

- [ ] **Step 5: Commit**

```bash
git add lib/predictex_web/live/import_live.ex
git commit -m "feat: import bookmarklet + colocated fragment hook + instructions (predictex-xox)"
```

---

## Task 6: Full quality gate + manual real-session validation + close-out

**Files:** none (verification + issue close).

- [ ] **Step 1: Run the full quality gate**

```bash
mise exec -- mix test
mise exec -- mix format --check-formatted
mise exec -- mix compile --warnings-as-errors
mise exec -- mix deps.unlock --check-unused
```

Expected: all green (251 prior tests + the new crosswalk/import/import_live tests).

- [ ] **Step 2: Manual real-session validation (acceptance criterion — CI cannot cover the bookmarklet)**

This is the feature's one untestable artifact. Perform end-to-end in a real browser:
1. Log in to predictex and to the FIFA Match Predictor in the same browser.
2. Add the bookmarklet from `/import`. On the FIFA predictor page, click it.
3. Confirm the new tab opens `/import#…`, the preview shows your real picks resolved to the
   right fixtures, and confirming writes them (check `/predictions`).
4. Verify the **named unknowns** from the spec:
   - `window.open` is not popup-blocked (it runs from a user click = a gesture, but confirm).
   - The URL fragment carries all ~rows for 3 rounds without truncation.
   - All three round fetches complete before the tab opens (no partial payload).

Record the outcome in the issue. If `window.open` is blocked, fall back to the console-snippet +
paste path and note it. **Do not declare the feature production-ready** — surface the evidence and
let the maintainer make the call (per project preference).

- [ ] **Step 3: Update RESUME.md** with the shipped state (xox group-stage import; knockout deferred).

- [ ] **Step 4: Close the issue and commit**

```bash
bd close predictex-xox --reason="Group-stage scoreline+booster self-import shipped: thin bookmarklet -> /import preview/confirm, server-side {round,matchId} crosswalk via Fifa.Crosswalk. Knockout/first-scorer deferred to a new issue."
git add RESUME.md
git commit -m "docs: RESUME — xox group-stage FIFA import shipped (predictex-xox)"
```

- [ ] **Step 5: File the deferred knockout follow-up**

```bash
bd create --title="xox knockout import + first-scorer matching" --type=feature --priority=3 \
  --description="Extend FIFA import to knockout rounds (4-8): resolve firstSquadScored->side and firstPlayerScored->player name (fuzzy cross-source match vs openfootball). Blocked until knockout rounds open and a populated prediction/show sample exists. See docs/superpowers/specs/2026-06-16-xox-fifa-import-design.md (Out of scope)."
```

---

## Notes for the implementer

- **Always** prefix mix with `mise exec --` (the repo pins Elixir 1.20 via mise; plain `mix` is the wrong version).
- The pure cores (`Crosswalk`, `Import`) hold the testable logic; the LiveView stays dumb (no `try/raise`, validation upstream) per the project's LiveView discipline rule.
- `Cohort`'s existing tests are the regression guard for the Task 1 extraction — if they go red, the extraction changed behaviour and must be corrected, not the tests.
- The composite `{round, matchId}` key is a correctness requirement (silent-corruption guard), not an optimization — do not simplify it to a flat `matchId` map.
- Test brittleness: the unmatched-reason HTML assertions match `reason_text/1` output. If you reword that copy, update the assertions to match verbatim.
