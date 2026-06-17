defmodule Predictex.Workers.LiveScoreSync do
  @moduledoc """
  Live score producer (predictex-rfm). Self-rescheduling Oban worker: for every fixture
  with a `fifa_match_id` currently inside its capture window, fetches FIFA's per-match detail
  endpoint and broadcasts `{:snapshot, fixture_id, body, captured_at, fifa_match_id, url}` on
  `Predictex.PubSub` topic `"fifa:snapshots"`. The window opens 10 minutes before kickoff and
  closes 150 minutes after — covering pre-kickoff, in-play, and a generous post-match tail.

  The worker does NOT write any fixture columns. `Predictex.Live.Updater` (a PubSub subscriber)
  decodes each snapshot and writes the `live_*` columns.

  Drive on prod: `rpc "Predictex.Workers.LiveScoreSync.start()"`.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger
  import Ecto.Query
  alias Predictex.Repo
  alias Predictex.Tournament.Fixture

  @detail_base "https://api.fifa.com/api/v3/live/football/17/285023/289273"
  @pre_min 10
  @post_min 150
  @interval 30

  def start, do: %{} |> new() |> Oban.insert()

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()
    fixtures = in_window(now)
    Enum.each(fixtures, &publish(&1, now))
    if fixtures != [], do: reschedule()
    :ok
  end

  defp in_window(now) do
    from_t = DateTime.add(now, -@post_min * 60)
    to_t = DateTime.add(now, @pre_min * 60)

    Repo.all(
      from f in Fixture,
        where: not is_nil(f.fifa_match_id) and f.kickoff_at <= ^to_t and f.kickoff_at >= ^from_t
    )
  end

  defp publish(f, now) do
    url = "#{@detail_base}/#{f.fifa_match_id}"

    case fetch_fun().(url) do
      {:ok, 200, body} when is_map(body) ->
        Phoenix.PubSub.broadcast(
          Predictex.PubSub,
          "fifa:snapshots",
          {:snapshot, f.id, body, now, f.fifa_match_id, url}
        )

      other ->
        Logger.warning("live snapshot fetch #{f.fifa_match_id}: #{inspect(other)}")
    end
  end

  defp reschedule, do: %{} |> new(schedule_in: @interval) |> Oban.insert()

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
