defmodule Predictex.Workers.KnockoutIds do
  @moduledoc """
  Self-arming knockout `fifa_match_id` backfill (predictex-hco WS1). FIFA publishes the knockout
  match ids in `rounds.json` only once the bracket resolves (after the group stage), and the first
  knockout kicks off the same day — too tight for a manual step. This Oban worker runs on the cron
  and assigns the moment FIFA publishes:

    * **Stop before fetch** — if no knockout fixture is missing a `fifa_match_id` *or* a
      `fifa_stage_id`, it no-ops without touching the network (so it isn't hammering the CDN for
      the rest of the tournament). The live `/detail` endpoint needs both — each KO round is a
      distinct stage — so a stage-only gap must still arm the worker.
    * Otherwise it fetches `rounds.json` and runs `Fifa.LiveIds.assign/1`, logging coverage
      (`KO fifa_match_id: N/32`) and the name/slot split so the 28 Jun window is observable.

  The rounds source is injectable (`:ko_ids_rounds_fun`) for network-free tests. The worker is
  transient — deletable from the cron once the bracket is fully assigned.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger
  import Ecto.Query

  alias Predictex.Fifa.{LiveIds, Reference}
  alias Predictex.Repo
  alias Predictex.Tournament.Fixture

  @impl Oban.Worker
  def perform(_job) do
    if ko_pending?() do
      case rounds_fun().() do
        {:ok, rounds} ->
          summary = LiveIds.assign(rounds)
          Logger.info("knockout id backfill: #{inspect(summary)} (#{coverage()})")
          :ok

        {:error, reason} ->
          Logger.error("knockout id backfill: rounds fetch failed: #{inspect(reason)}")
          {:error, reason}
      end
    else
      :ok
    end
  end

  # A knockout fixture still needs FIFA addressing when it's missing its match id OR its stage id
  # (the live `/detail` endpoint needs BOTH — each KO round is a distinct stage). The stage arm is
  # essential: the existing R32 rows already have ids, so an id-only guard would no-op and never
  # backfill their stage, leaving live capture pointed at the wrong stage.
  defp ko_pending? do
    Repo.exists?(
      from f in Fixture,
        join: r in assoc(f, :round),
        where: r.stage == :knockout and (is_nil(f.fifa_match_id) or is_nil(f.fifa_stage_id))
    )
  end

  defp coverage do
    base = from(f in Fixture, join: r in assoc(f, :round), where: r.stage == :knockout)
    total = Repo.aggregate(base, :count)
    have = Repo.aggregate(from(f in base, where: not is_nil(f.fifa_match_id)), :count)
    "KO fifa_match_id: #{have}/#{total}"
  end

  defp rounds_fun do
    Application.get_env(:predictex, :ko_ids_rounds_fun, &Reference.fetch_rounds/0)
  end
end
