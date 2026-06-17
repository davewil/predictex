defmodule Predictex.Workers.FifaLiveCapture do
  @moduledoc """
  SPIKE (predictex-70h): self-rescheduling Oban worker that captures raw FIFA v3 live
  API responses across a single match window, persisting each to `fifa_captures` for
  offline analysis — to decode the live `MatchStatus` code and confirm scores tick in
  real time before building the real LiveScoreSync.

  This is the LiveScoreSync skeleton: same windowed-poll + Gather → Decide → Act shape,
  minus the fixture write. Oban's Cron is minute-granular, so to poll every ~30s the job
  captures once then re-enqueues itself `interval` seconds out while now is inside
  `[start_at, end_at]`; before the window it waits (re-enqueues at `start_at`), after it
  stops. HTTP is the only I/O, injectable via `:fifa_capture_fetch_fun` for tests.

  Drive it from the running prod node (no cron entry needed):

      bin/predictex rpc "Predictex.Workers.FifaLiveCapture.start()"
      bin/predictex rpc "Predictex.Workers.FifaLiveCapture.start(%{\\"interval\\" => 60})"

  Read captures back:

      bin/predictex rpc "Predictex.Spike.list_captures(\\"400021502\\") |> length()"
  """
  # max_attempts: 3 — `capture_one` already rescues, and `reschedule` is the last
  # statement, so the only way `perform` raises is `Oban.insert` itself failing, in
  # which case nothing was scheduled and a retry is the safe, wanted behaviour. The
  # case that must not silently die is the wait-job failing when it fires at the window
  # start: a retry there is the difference between full capture and zero capture for a
  # match that can't be replayed. Worst case is a couple of near-duplicate rows.
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Predictex.Spike

  @now_url "https://api.fifa.com/api/v3/live/football/now"

  # Defaults target Portugal v Congo DR, 2026-06-17 17:00Z (IdMatch 400021502), with a
  # window that brackets kickoff through full time. Override any key via `start/1`.
  @defaults %{
    "match_id" => "400021502",
    "comp" => "17",
    "season" => "285023",
    "stage" => "289273",
    "start_at" => "2026-06-17T16:50:00Z",
    "end_at" => "2026-06-17T19:50:00Z",
    "interval" => 30
  }

  @doc "Enqueue the first capture job, merging `overrides` over the defaults."
  def start(overrides \\ %{}) do
    @defaults
    |> Map.merge(stringify(overrides))
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    start_at = parse_dt(args["start_at"])
    end_at = parse_dt(args["end_at"])
    interval = args["interval"] || 30

    case decide(DateTime.utc_now(), start_at, end_at, interval) do
      {:capture, next_in} ->
        capture(args)
        reschedule(args, next_in)
        :ok

      {:wait, next_in} ->
        Logger.info("fifa capture: before window for #{args["match_id"]}, waiting #{next_in}s")
        reschedule(args, next_in)
        :ok

      :stop ->
        Logger.info("fifa capture: window closed for #{args["match_id"]}, stopping")
        :ok
    end
  end

  @doc """
  Pure scheduling decision:

    * `{:capture, interval}` — inside the window; capture now, run again in `interval`s
    * `{:wait, secs}` — before the window; do nothing, re-enqueue at `start_at`
    * `:stop` — at/after `end_at`; end the chain
  """
  def decide(now, start_at, end_at, interval) do
    cond do
      DateTime.compare(now, end_at) != :lt -> :stop
      DateTime.compare(now, start_at) == :lt -> {:wait, max(DateTime.diff(start_at, now), 1)}
      true -> {:capture, interval}
    end
  end

  defp capture(args) do
    capture_one("now", @now_url, args["match_id"])
    capture_one("detail", detail_url(args), args["match_id"])
  end

  defp capture_one(endpoint, url, match_id) do
    attrs =
      case fetch_fun().(url) do
        {:ok, status, body} -> %{http_status: status, body: normalize_body(body), error: nil}
        {:error, reason} -> %{http_status: nil, body: nil, error: inspect(reason)}
      end

    attrs =
      Map.merge(attrs, %{
        captured_at: DateTime.utc_now(),
        endpoint: endpoint,
        url: url,
        match_id: match_id
      })

    case Spike.record_capture(attrs) do
      {:ok, _} ->
        :ok

      {:error, cs} ->
        Logger.error("fifa capture persist failed (#{endpoint}): #{inspect(cs.errors)}")
    end
  rescue
    e -> Logger.error("fifa capture #{endpoint} crashed: #{Exception.message(e)}")
  end

  # Req decodes JSON to a map; keep maps, wrap anything else so the :map column is happy.
  defp normalize_body(body) when is_map(body), do: body
  defp normalize_body(body), do: %{"_raw" => to_string(body)}

  defp detail_url(a) do
    "https://api.fifa.com/api/v3/live/football/#{a["comp"]}/#{a["season"]}/#{a["stage"]}/#{a["match_id"]}"
  end

  defp reschedule(args, secs) do
    args
    |> new(schedule_in: secs)
    |> Oban.insert()
  end

  @doc false
  def fetch(url) do
    {:ok, _} = Application.ensure_all_started(:req)

    case Req.get(url, receive_timeout: 20_000) do
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, status, body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_fun, do: Application.get_env(:predictex, :fifa_capture_fetch_fun, &fetch/1)

  defp parse_dt(s) when is_binary(s) do
    {:ok, dt, _} = DateTime.from_iso8601(s)
    dt
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
end
