defmodule Mix.Tasks.Predictex.Leaderboard do
  @shortdoc "Score predictions against openfootball results and print the leaderboard (no DB)"

  @moduledoc """
  Score a league's predictions against World Cup results and print the standings —
  without a database. The thin I/O shell over the pure engine
  (`Predictex.Results.Openfootball` → `Predictex.Fifa` → `Predictex.Scoring.Leaderboard`).

      mix predictex.leaderboard --predictions league.json
      mix predictex.leaderboard --predictions league.json --results local_worldcup.json
      mix predictex.leaderboard --predictions league.json --top 10 --breakdown

  ## Options

    * `--predictions PATH` (required) — the league's predictions JSON (see shape below)
    * `--results PATH` — a local openfootball `worldcup.json`; if omitted, the 2026
      feed is fetched from `--results-url`
    * `--results-url URL` — override the openfootball source URL
    * `--top N` — show only the top N players
    * `--breakdown` — print each player's per-fixture points

  ## Structure: Gather → Decide → Act

  `run/1` is exactly three phases. **Gather** performs every read (CLI args, the
  predictions file, the results feed) and returns raw data. **Decide** is a pure
  function — parse, map to FIFA rounds, score, rank, and render the output lines, with
  no I/O. **Act** performs the only output effect (printing). The decision, including
  the exact text rendered, is pure and unit-testable.

  ## Predictions JSON shape

      {
        "players": [
          {
            "name": "Dave",
            "predictions": [
              {"home_team": "Egypt", "away_team": "Belgium", "home": 1, "away": 2,
               "booster": true, "first_scorer_side": "away",
               "first_scorer_player": "Kevin De Bruyne"}
            ]
          }
        ],
        "cohort": [
          {"home_team": "Egypt", "away_team": "Belgium", "home": 30, "draw": 25, "away": 45}
        ]
      }

  `cohort` is the FIFA global home/draw/away % per fixture (for the risky bonus) and
  is optional. Knockout-only fields (`first_scorer_side`, `first_scorer_player`) are
  ignored for group fixtures.
  """

  use Mix.Task

  alias Predictex.{Scoring.Leaderboard, Results.Openfootball}

  @default_url "https://raw.githubusercontent.com/openfootball/worldcup.json/master/2026/worldcup.json"

  @requirements ["compile"]

  @switches [
    predictions: :string,
    results: :string,
    results_url: :string,
    top: :integer,
    breakdown: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    argv
    |> gather()
    |> decide()
    |> act()
  end

  # --- Gather: every read happens here, returning raw data only ---

  defp gather(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)

    predictions_path = opts[:predictions] || Mix.raise("--predictions PATH is required")
    league = predictions_path |> File.read!() |> Jason.decode!()

    unless is_map(league) and is_list(league["players"]),
      do: Mix.raise(~s|predictions JSON must have a "players" list|)

    %{league: league, results_doc: load_results(opts), opts: opts}
  end

  defp load_results(opts) do
    case opts[:results] do
      nil -> opts[:results_url] |> Kernel.||(@default_url) |> fetch!() |> Jason.decode!()
      path -> path |> File.read!() |> Jason.decode!()
    end
  end

  defp fetch!(url) do
    {:ok, _} = Application.ensure_all_started(:req)

    case Req.get(url, decode_body: false, receive_timeout: 15_000) do
      {:ok, %Req.Response{status: 200, body: body}} -> body
      {:ok, %Req.Response{status: status}} -> Mix.raise("Fetching #{url} returned HTTP #{status}")
      {:error, reason} -> Mix.raise("Failed to fetch results from #{url}: #{inspect(reason)}")
    end
  end

  # --- Decide: pure. Parse, map, score, rank, render — no I/O ---

  @doc false
  def decide(%{league: league, results_doc: results_doc, opts: opts}) do
    fixtures = Openfootball.parse(results_doc)
    players = normalize_players(league)
    cohort = normalize_cohort(league)

    standings = Leaderboard.build(fixtures, players, cohort)
    %{lines: render(standings, fixtures, players, opts)}
  end

  defp normalize_players(%{"players" => players}) do
    Enum.map(players, fn p ->
      %{
        name: Map.get(p, "name"),
        predictions: p |> Map.get("predictions", []) |> Enum.map(&normalize_prediction/1)
      }
    end)
  end

  defp normalize_prediction(pr) do
    %{
      home_team: Map.get(pr, "home_team"),
      away_team: Map.get(pr, "away_team"),
      home: Map.get(pr, "home"),
      away: Map.get(pr, "away"),
      booster: Map.get(pr, "booster", false) == true,
      first_scorer_side: Map.get(pr, "first_scorer_side"),
      first_scorer_player: Map.get(pr, "first_scorer_player")
    }
  end

  defp normalize_cohort(league) do
    league
    |> Map.get("cohort", [])
    |> Enum.map(fn c ->
      %{
        home_team: Map.get(c, "home_team"),
        away_team: Map.get(c, "away_team"),
        home: Map.get(c, "home"),
        draw: Map.get(c, "draw"),
        away: Map.get(c, "away")
      }
    end)
  end

  # Pure: build the full list of output lines.
  @doc false
  def render(standings, fixtures, players, opts) do
    completed = Enum.count(fixtures, &(&1.status == :completed))
    shown = standings |> maybe_top(opts[:top])

    header(completed, length(fixtures)) ++
      table(shown) ++
      breakdown(shown, opts[:breakdown]) ++
      unmatched(players, fixtures)
  end

  defp header(completed, total) do
    [
      "",
      "Predictex — FIFA World Cup 2026 Predictor",
      "Completed fixtures available: #{completed} of #{total}",
      "",
      row("#", "Player", "Fixtures", "Bonus", "Total"),
      String.duplicate("-", 56)
    ]
  end

  defp table(standings) do
    standings
    |> Enum.with_index(1)
    |> Enum.map(fn {s, rank} ->
      row(
        Integer.to_string(rank),
        s.name,
        to_string(s.fixtures_total),
        to_string(s.round_bonus_total),
        to_string(s.total)
      )
    end)
  end

  defp breakdown(_standings, true?) when true? != true, do: []

  defp breakdown(standings, true) do
    ["", "Breakdown:"] ++
      Enum.flat_map(standings, fn s ->
        ["", "  #{s.name}:"] ++
          Enum.map(s.breakdown, fn %{fixture: fx, result: r} ->
            "    #{fx.team1} #{fx.home_goals}-#{fx.away_goals} #{fx.team2}" <>
              "  → #{r.fixture_total}#{if r.booster, do: " (2x)", else: ""}"
          end)
      end)
  end

  # Surface predictions that match no fixture at all (likely team-name typos).
  defp unmatched(players, fixtures) do
    keys = MapSet.new(fixtures, &norm_key(&1.team1, &1.team2))

    miss =
      for p <- players,
          pred <- p.predictions,
          not MapSet.member?(keys, norm_key(pred.home_team, pred.away_team)),
          do: "#{p.name}: #{pred.home_team} v #{pred.away_team}"

    case Enum.uniq(miss) do
      [] ->
        [""]

      misses ->
        ["", "[!] #{length(misses)} prediction(s) matched no fixture (check team names):"] ++
          Enum.map(misses, &"    - #{&1}") ++ [""]
    end
  end

  defp maybe_top(standings, nil), do: standings
  defp maybe_top(standings, n), do: Enum.take(standings, n)

  defp row(rank, name, fixtures, bonus, total) do
    [
      String.pad_leading(rank, 3),
      "  ",
      String.pad_trailing(to_string(name), 22),
      String.pad_leading(fixtures, 9),
      String.pad_leading(bonus, 7),
      String.pad_leading(total, 8)
    ]
    |> IO.iodata_to_binary()
  end

  defp norm_key(t1, t2), do: {norm(t1), norm(t2)}
  defp norm(nil), do: nil
  defp norm(s) when is_binary(s), do: s |> String.trim() |> String.downcase()

  # --- Act: the only output side effect ---

  defp act(%{lines: lines}) do
    shell = Mix.shell()
    Enum.each(lines, &shell.info/1)
  end
end
