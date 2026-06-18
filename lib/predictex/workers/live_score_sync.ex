defmodule Predictex.Workers.LiveScoreSync do
  @moduledoc """
  Live score producer (predictex-rfm). Self-rescheduling Oban worker: for every fixture
  with a `fifa_match_id` currently inside its capture window, fetches FIFA's per-match detail
  endpoint and broadcasts `{:snapshot, fixture_id, body, captured_at, fifa_match_id, url}` on
  `Predictex.PubSub` topic `"fifa:snapshots"`. The window opens 10 minutes before kickoff and
  closes 210 minutes after — wide enough to cover knockout extra-time and penalties (~155-185min)
  plus the finished frame that clears `is_live` (predictex-cvx).

  The worker does NOT write any fixture `live_*` columns from snapshots. `Predictex.Live.Updater`
  (a PubSub subscriber) decodes each snapshot and writes them.

  It DOES run an independent `is_live` auto-clear sweep on every tick (`clear_stuck_live/1`) —
  the one place it touches `is_live` directly — to self-heal a fixture left stuck live when no
  finished frame ever arrived (predictex-cvx / predictex-d17).

  Drive on prod: `rpc "Predictex.Workers.LiveScoreSync.start()"`.
  """
  # states is [:scheduled] — deliberately just the one state, for two reasons:
  #   1. :executing is excluded. The 30s chain reschedules from INSIDE a running
  #      (:executing) job with identical args. If :executing counted toward uniqueness
  #      that insert would conflict with the current job and the reschedule would be
  #      dropped — the chain would die after one tick and we'd capture only once per
  #      */5 cron. With :executing excluded the reschedule (a :scheduled job) inserts
  #      fine, so the self-chain survives. This is the load-bearing invariant.
  #   2. [:scheduled] is Oban 2.23's no-warning special case (Oban.Job.warn_unique/1,
  #      deps/oban/lib/oban/job.ex:844). A fuller list like [:available, :scheduled]
  #      would warn under --warnings-as-errors: Oban wants either all of the :incomplete
  #      states or exactly [:scheduled], and including all :incomplete states would re-add
  #      :executing and kill the chain (reason 1). So [:scheduled] is the only list that
  #      satisfies both compile-clean and chain-survival.
  # Cron dedupe: the chain refreshes a :scheduled job every 30s, so during a match there
  # is always a :scheduled job inserted ≤30s ago, inside period: 40. The */5 cron's insert
  # finds it and dedupes. When the window closes the chain stops, no :scheduled job remains,
  # and the next cron tick correctly starts a fresh chain.
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 40, states: [:scheduled]]

  require Logger
  import Ecto.Query
  alias Predictex.{LiveScore, Repo}
  alias Predictex.Tournament.Fixture

  @detail_base "https://api.fifa.com/api/v3/live/football/17/285023/289273"
  @pre_min 10
  @post_min 210
  @interval 30

  def start, do: %{} |> new() |> Oban.insert()

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()
    fixtures = in_window(now)
    # Reschedule first: a crash in publish/sweep must not break the 30s self-chain.
    if fixtures != [], do: reschedule()
    Enum.each(fixtures, &publish(&1, now))
    clear_stuck_live(now)
    :ok
  end

  # Fixtures to actively capture: have a fifa_match_id and sit inside the time window. We do
  # NOT gate on openfootball's `status` here. openfootball derives `:completed` from a full-time
  # (regulation) score, so it could in principle flag a knockout `:completed` while extra time /
  # penalties are still being played; gating publish on that would blank the buzz during the ET/
  # shootout peak. FIFA's live feed drives capture through the whole match; `clear_stuck_live/1`
  # uses `:completed` only to *clear* a stuck flag, where the worst case is a benign flicker
  # (the live frames keep re-asserting `is_live`) rather than a blackout.
  defp in_window(now) do
    from_t = DateTime.add(now, -@post_min * 60)
    to_t = DateTime.add(now, @pre_min * 60)

    Repo.all(
      from f in Fixture,
        where: not is_nil(f.fifa_match_id) and f.kickoff_at <= ^to_t and f.kickoff_at >= ^from_t
    )
  end

  # Self-heal a fixture left stuck `is_live: true` with no finished frame ever published,
  # independently of the producer chain (predictex-cvx). Clear when openfootball has marked
  # the match `:completed` — authoritative, and clears within ~one ResultSync cycle even while
  # the fixture is still in-window (the predictex-d17 endpoint-stall case) — OR, as a last-resort
  # backstop for a double feed failure, once kickoff is older than the capture window. Runs on
  # every tick, including the */5 cron ticks that fire after the self-reschedule chain has stopped.
  # Reads openfootball's `status` read-only; writes only `is_live` (the two-writer rule holds).
  defp clear_stuck_live(now) do
    cutoff = DateTime.add(now, -@post_min * 60)

    Repo.all(
      from f in Fixture,
        where: f.is_live == true and (f.status == :completed or f.kickoff_at < ^cutoff)
    )
    |> Enum.each(&LiveScore.clear_live/1)
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
