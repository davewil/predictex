defmodule Mix.Tasks.Predictex.PreviewKnockout do
  @shortdoc "Resolve real team names onto the first two unresolved R32 fixtures (dev/test only)"

  @moduledoc """
  Resolve real team names onto the first two unresolved fixtures of the first knockout round
  in the LOCAL dev DB, so those fixtures show EDITABLE entry cards locally (predictex-80k).
  Writes via the genuine admin path (`Tournament.update_fixture/2`), not hand-stamped data.

      mise exec -- mix predictex.preview_knockout
      mise exec -- mix phx.server      # then log in -> /predictions -> R32 tab

  Notes:

    * Dev/test only — refuses to run under `MIX_ENV=prod` (and mix tasks aren't
      shipped in the release anyway).
    * Idempotent — fixtures already fully resolved are skipped; only the first two
      unresolved fixtures are targeted.
    * Uses sample team names ("Brazil" v "Japan", "Croatia" v "Belgium") — this
      previews form MECHANICS/layout, not real matchups/flags.
    * Reverse with `mix ecto.reset`. Seeds do a live feed fetch, so for an offline
      reset use `WORLDCUP_JSON=<path> mix ecto.reset`.
  """
  use Mix.Task

  import Ecto.Query, warn: false

  alias Predictex.Scoring.Knockout
  alias Predictex.Repo
  alias Predictex.Tournament
  alias Predictex.Tournament.{Fixture, Round}

  @impl Mix.Task
  def run(_args) do
    if Mix.env() == :prod do
      Mix.raise("predictex.preview_knockout is a dev/test-only task; refusing to run in :prod")
    end

    Mix.Task.run("app.start")

    {:ok, %{round: round, resolved_count: n}} = open_first_knockout_round()

    Mix.shell().info("""
    Resolved teams onto #{n} fixture(s) in the first knockout round.
    "#{round.name}" (ordinal #{round.ordinal}) now has EDITABLE cards for the resolved matches.
    Native entry form: http://localhost:4000/predictions  (log in, then select the R32 tab)
    Note: only fixtures with both teams resolved show the editable entry form.
    """)
  end

  @doc """
  Resolve real team names onto the first knockout round's first two unresolved fixtures, so the
  per-fixture native entry form shows EDITABLE cards locally (predictex-80k). Returns
  `{:ok, %{round: round, resolved_count: n}}`. Pure of IO / app.start so it is directly testable.
  """
  def open_first_knockout_round do
    ko =
      Repo.one(from r in Round, where: r.stage == :knockout, order_by: [asc: r.ordinal], limit: 1)

    if is_nil(ko),
      do: Mix.raise("No knockout round found — run `mix ecto.reset` to seed the full schedule")

    unresolved =
      from(f in Fixture, where: f.round_id == ^ko.id, order_by: [asc: f.source_num])
      |> Repo.all()
      |> Enum.reject(fn f ->
        Knockout.resolved_team?(f.team1) and Knockout.resolved_team?(f.team2)
      end)
      |> Enum.take(2)

    sample = [{"Brazil", "Japan"}, {"Croatia", "Belgium"}]

    Enum.zip(unresolved, sample)
    |> Enum.each(fn {f, {t1, t2}} ->
      {:ok, _} = Tournament.update_fixture(f, %{team1: t1, team2: t2})
    end)

    Tournament.broadcast_change()
    {:ok, %{round: ko, resolved_count: length(unresolved)}}
  end
end
