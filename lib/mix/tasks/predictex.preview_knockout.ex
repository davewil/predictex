defmodule Mix.Tasks.Predictex.PreviewKnockout do
  @shortdoc "Open the first knockout round locally so the native R32 entry form can be eyeballed (dev/test only)"

  @moduledoc """
  Settle the predecessor (last group) round in the LOCAL dev DB so the first
  knockout round's prediction gate opens, letting you click through the real
  native R32 entry form (scoreline + first-team + booster) before the live
  cutover. Settles via the genuine admin write path (`Tournament.update_fixture/2`),
  not a hand-stamped status.

      mise exec -- mix predictex.preview_knockout
      mise exec -- mix phx.server      # then log in -> /predictions -> R32 tab

  Notes:

    * Dev/test only — refuses to run under `MIX_ENV=prod` (and mix tasks aren't
      shipped in the release anyway).
    * Idempotent — already-completed predecessor fixtures are skipped.
    * R32 fixtures show openfootball PLACEHOLDER team names ("Winner Group A" v
      "Runner-up Group B") until the bracket resolves, so this previews form
      MECHANICS/layout, not real matchups/flags.
    * Reverse with `mix ecto.reset`. Seeds do a live feed fetch, so for an offline
      reset use `WORLDCUP_JSON=<path> mix ecto.reset`. There is no per-fixture un-settle.
  """
  use Mix.Task

  import Ecto.Query, warn: false

  alias Predictex.Repo
  alias Predictex.Tournament
  alias Predictex.Tournament.{Fixture, Round}

  @impl Mix.Task
  def run(_args) do
    if Mix.env() == :prod do
      Mix.raise("predictex.preview_knockout is a dev/test-only task; refusing to run in :prod")
    end

    Mix.Task.run("app.start")

    {:ok, %{round: round, settled_count: n}} = open_first_knockout_round()

    Mix.shell().info("""
    Settled #{n} fixture(s) in the predecessor (group) round.
    "#{round.name}" (ordinal #{round.ordinal}) is now OPEN for predictions.
    Native entry form: http://localhost:4000/predictions  (log in, then select the R32 tab)
    Note: R32 fixtures show placeholder team names until the bracket resolves — this previews form mechanics, not real matchups.
    """)
  end

  @doc """
  Settle the first knockout round's predecessor so the round opens. Returns
  `{:ok, %{round: round, settled_count: n, already_complete: bool}}`. Pure of IO
  and `app.start` so it is directly testable.
  """
  def open_first_knockout_round do
    ko =
      Repo.one(from r in Round, where: r.stage == :knockout, order_by: [asc: r.ordinal], limit: 1)

    if is_nil(ko),
      do: Mix.raise("No knockout round found — run `mix ecto.reset` to seed the full schedule")

    predecessor = Tournament.get_round_by_ordinal(ko.ordinal - 1)

    if is_nil(predecessor),
      do:
        Mix.raise(
          "Predecessor round (ordinal #{ko.ordinal - 1}) not found — run `mix ecto.reset` to seed the full schedule"
        )

    incomplete =
      Repo.all(from f in Fixture, where: f.round_id == ^predecessor.id and f.status != :completed)

    Enum.each(incomplete, fn f ->
      {:ok, _} = Tournament.update_fixture(f, %{status: :completed, home_goals: 1, away_goals: 0})
    end)

    Tournament.broadcast_change()

    {:ok, %{round: ko, settled_count: length(incomplete), already_complete: incomplete == []}}
  end
end
