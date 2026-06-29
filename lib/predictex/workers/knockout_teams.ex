defmodule Predictex.Workers.KnockoutTeams do
  @moduledoc """
  Self-arming knockout team-name backfill (predictex-e5o). FIFA's `rounds.json` resolves a
  bracket slot (incl. third-placed: `3B/E/F/I/J` → `Bosnia & Herzegovina`) ahead of openfootball;
  this worker fills the placeholder side from FIFA so the native R32 card flips `:editable` sooner.

    * **Stop before fetch** — if no knockout fixture still holds a placeholder side, it no-ops
      without touching the network.
    * Otherwise it fetches `rounds.json` and runs `Fifa.KnockoutTeams.assign/1` (placeholders only;
      openfootball stays authoritative — the no-downgrade guard).

  The rounds source is injectable (`:ko_teams_rounds_fun`) for network-free tests. Transient —
  deletable from the cron once the bracket teams are fully resolved.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger
  import Ecto.Query

  alias Predictex.Fifa.{KnockoutTeams, Reference}
  alias Predictex.{Scoring.Knockout, Repo}
  alias Predictex.Tournament.Fixture

  @impl Oban.Worker
  def perform(_job) do
    if ko_teams_pending?() do
      case rounds_fun().() do
        {:ok, rounds} ->
          summary = KnockoutTeams.assign(rounds)
          Logger.info("knockout team backfill: #{inspect(summary)} (#{coverage()})")
          :ok

        {:error, reason} ->
          Logger.error("knockout team backfill: rounds fetch failed: #{inspect(reason)}")
          {:error, reason}
      end
    else
      :ok
    end
  end

  defp ko_teams_pending? do
    from(f in Fixture,
      join: r in assoc(f, :round),
      where: r.stage == :knockout,
      select: {f.team1, f.team2}
    )
    |> Repo.all()
    |> Enum.any?(fn {t1, t2} ->
      not (Knockout.resolved_team?(t1) and Knockout.resolved_team?(t2))
    end)
  end

  defp coverage do
    rows =
      from(f in Fixture,
        join: r in assoc(f, :round),
        where: r.stage == :knockout,
        select: {f.team1, f.team2}
      )
      |> Repo.all()

    resolved =
      Enum.count(rows, fn {t1, t2} ->
        Knockout.resolved_team?(t1) and Knockout.resolved_team?(t2)
      end)

    "KO teams resolved: #{resolved}/#{length(rows)}"
  end

  defp rounds_fun do
    Application.get_env(:predictex, :ko_teams_rounds_fun, &Reference.fetch_rounds/0)
  end
end
