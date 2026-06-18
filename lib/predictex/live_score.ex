defmodule Predictex.LiveScore do
  @moduledoc """
  Shared decode + apply contract for FIFA live `/detail` snapshots (predictex-rfm).

  Used by `Workers.LiveScoreSync` (the producer's LiveUpdater path) and the replay
  engine (predictex-i1s) so the body→`live_*`→broadcast logic lives in exactly one place.
  Writes ONLY the additive `live_*`/`is_live` columns — never openfootball's result columns.
  """
  require Logger
  alias Predictex.Tournament

  @doc "Decode a FIFA `/detail` body into `live_*` attrs. `fixture` supplies the nil-score fallback."
  def attrs_from_body(body, fixture) when is_map(body) do
    %{
      is_live: body["MatchStatus"] not in [0, 1],
      live_home_goals: get_in(body, ["HomeTeam", "Score"]) || fixture.live_home_goals,
      live_away_goals: get_in(body, ["AwayTeam", "Score"]) || fixture.live_away_goals,
      live_minute: body["MatchTime"]
    }
  end

  @doc "Write the `live_*` attrs to `fixture` and broadcast `{:live_update, id}` when a live value changed."
  def apply_to_fixture(fixture, attrs) do
    changed? =
      fixture.is_live != attrs.is_live or
        fixture.live_home_goals != attrs.live_home_goals or
        fixture.live_away_goals != attrs.live_away_goals or
        fixture.live_minute != attrs.live_minute

    case Tournament.update_fixture(fixture, attrs) do
      {:ok, _} ->
        if changed?,
          do:
            Phoenix.PubSub.broadcast(
              Predictex.PubSub,
              "fixture:#{fixture.id}",
              {:live_update, fixture.id}
            )

        :ok

      {:error, cs} = err ->
        Logger.warning("live score update failed for #{fixture.id}: #{inspect(cs.errors)}")
        err
    end
  end

  @doc """
  Clear `is_live` (retaining the last captured `live_*` score) and broadcast.

  Self-heals a fixture left stuck `is_live: true` when the finished frame that would
  have cleared it never arrived — e.g. a knockout ran past the producer window, or the
  FIFA detail endpoint stopped returning 200 post-match (predictex-cvx / predictex-d17).
  """
  def clear_live(fixture) do
    apply_to_fixture(fixture, %{
      is_live: false,
      live_home_goals: fixture.live_home_goals,
      live_away_goals: fixture.live_away_goals,
      live_minute: fixture.live_minute
    })
  end
end
