defmodule Predictex.Workers.LiveScoreSync do
  @moduledoc """
  Live in-play score sync (predictex-c46). Self-rescheduling Oban worker: for every fixture
  with a `fifa_match_id` currently inside its live window, fetch FIFA's per-match detail
  endpoint and write the additive `live_*` columns — never `status`/`home_goals` (openfootball
  stays the result authority). "Live" = `MatchStatus` not in [0,1]. Broadcasts on change.
  Drive on prod: `rpc "Predictex.Workers.LiveScoreSync.start()"`.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger
  import Ecto.Query
  alias Predictex.{Repo, Tournament}
  alias Predictex.Tournament.Fixture

  @detail_base "https://api.fifa.com/api/v3/live/football/17/285023/289273"

  def start(overrides \\ %{}) do
    %{"window_min" => 150, "interval" => 30}
    |> Map.merge(Map.new(overrides, fn {k, v} -> {to_string(k), v} end))
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    window = args["window_min"] || 150
    interval = args["interval"] || 30
    now = DateTime.utc_now()

    fixtures = in_window(now, window)
    Enum.each(fixtures, &sync_one/1)

    if fixtures != [], do: reschedule(args, interval)
    :ok
  end

  defp in_window(now, window_min) do
    cutoff = DateTime.add(now, -window_min * 60)

    Repo.all(
      from f in Fixture,
        where: not is_nil(f.fifa_match_id) and f.kickoff_at <= ^now and f.kickoff_at >= ^cutoff
    )
  end

  defp sync_one(f) do
    case fetch_fun().("#{@detail_base}/#{f.fifa_match_id}") do
      {:ok, 200, body} when is_map(body) -> apply_update(f, body)
      other -> Logger.warning("live score fetch #{f.fifa_match_id}: #{inspect(other)}")
    end
  end

  defp apply_update(f, body) do
    live? = body["MatchStatus"] not in [0, 1]

    attrs = %{
      is_live: live?,
      live_home_goals: get_in(body, ["HomeTeam", "Score"]) || f.live_home_goals,
      live_away_goals: get_in(body, ["AwayTeam", "Score"]) || f.live_away_goals,
      live_minute: body["MatchTime"]
    }

    changed? =
      f.is_live != attrs.is_live or f.live_home_goals != attrs.live_home_goals or
        f.live_away_goals != attrs.live_away_goals or f.live_minute != attrs.live_minute

    case Tournament.update_fixture(f, attrs) do
      {:ok, _} ->
        if changed?,
          do: Phoenix.PubSub.broadcast(Predictex.PubSub, "fixture:#{f.id}", {:live_update, f.id})

      {:error, cs} ->
        Logger.warning("live score update failed for #{f.id}: #{inspect(cs.errors)}")
    end
  end

  defp reschedule(args, secs), do: args |> new(schedule_in: secs) |> Oban.insert()
  defp fetch_fun, do: Application.get_env(:predictex, :live_score_fetch_fun, &fetch/1)

  @doc false
  def fetch(url) do
    {:ok, _} = Application.ensure_all_started(:req)

    case Req.get(url, receive_timeout: 20_000) do
      {:ok, %Req.Response{status: s, body: b}} -> {:ok, s, b}
      {:error, reason} -> {:error, reason}
    end
  end
end
