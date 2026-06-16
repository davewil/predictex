defmodule Predictex.Workers.CohortSync do
  @moduledoc """
  Oban worker (hourly) that pulls FIFA cohort data and upserts `cohort_*_pct` on fixtures.

  Gather → Decide → Act: `fetch/0` reads `rounds.json` + `matchStats.json` (the only I/O,
  injectable via `:cohort_source_fun` for tests), `Fifa.Cohort.plan/3` is the pure join,
  and `Tournament.update_fixture/2` commits. FIFA is the source — cohort is overwritten.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Predictex.{Fifa, Tournament}

  @rounds_url "https://play.fifa.com/json/match_predictor/rounds.json"
  @stats_url "https://play.fifa.com/json/match_predictor/matchStats.json"

  @impl Oban.Worker
  def perform(_job) do
    case source().() do
      {:ok, %{rounds: rounds, match_stats: stats}} ->
        fixtures = Tournament.list_fixtures()
        updates = Fifa.Cohort.plan(rounds, stats, fixtures)
        {ok, err} = commit(updates, Map.new(fixtures, &{&1.id, &1}))
        Logger.info("cohort sync: #{ok} updated, #{err} errors (#{length(updates)} matched)")
        :ok

      {:error, reason} ->
        Logger.error("cohort sync fetch failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "Fetch FIFA reference + cohort JSON. Returns {:ok, %{rounds, match_stats}} | {:error, _}."
  def fetch do
    with {:ok, rounds} <- get_json(@rounds_url),
         {:ok, stats} <- get_json(@stats_url) do
      {:ok, %{rounds: rounds, match_stats: stats}}
    end
  end

  defp get_json(url) do
    {:ok, _} = Application.ensure_all_started(:req)

    case Req.get(url, receive_timeout: 15_000) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) or is_list(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, Jason.decode!(body)}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp commit(updates, by_id) do
    Enum.reduce(updates, {0, 0}, fn u, {ok, err} ->
      fixture = Map.fetch!(by_id, u.fixture_id)
      attrs = Map.take(u, [:cohort_home_pct, :cohort_draw_pct, :cohort_away_pct])

      case Tournament.update_fixture(fixture, attrs) do
        {:ok, _} -> {ok + 1, err}
        {:error, _} -> {ok, err + 1}
      end
    end)
  end

  defp source, do: Application.get_env(:predictex, :cohort_source_fun, &fetch/0)
end
