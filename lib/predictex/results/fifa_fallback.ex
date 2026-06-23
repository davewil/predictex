defmodule Predictex.Results.FifaFallback do
  @moduledoc """
  Provisionally settle a fixture from our FIFA capture when openfootball lags (predictex-iy1).

  openfootball stays the authoritative result source (the two-writer rule). This is the bounded
  exception: for an unsettled **group** fixture whose captured FIFA `/detail` shows the match
  finished (`MatchStatus` 0) with both scores, write the FIFA final score + `status: :completed`.
  openfootball reclaims authority on its next sync that carries a real result (`Ingest`'s
  no-downgrade guard keeps a no-result sync from reverting the provisional in the meantime).

  Knockouts (extra-time / penalties) are out of scope — `predictex-uyf`.
  """

  import Ecto.Query, only: [from: 2]

  alias Predictex.{Capture, Repo, Tournament}
  alias Predictex.Tournament.Fixture

  # Don't trust an early/abandoned MatchStatus 0 frame; a group match can't finish before this.
  @min_elapsed_min 100

  @doc """
  Settle every eligible candidate from its latest captured FIFA finished frame. Returns a summary
  `%{candidates: n, settled: m}` and broadcasts a fixtures-changed signal when anything settled.
  """
  @spec run() :: %{candidates: non_neg_integer(), settled: non_neg_integer()}
  def run do
    cutoff = DateTime.add(DateTime.utc_now(), -@min_elapsed_min * 60)

    candidates =
      Repo.all(
        from f in Fixture,
          where:
            not is_nil(f.fifa_match_id) and f.status != :completed and f.kickoff_at < ^cutoff,
          preload: :round
      )

    settled =
      Enum.flat_map(candidates, fn f ->
        case settle_attrs(f, body_fun().(f.fifa_match_id)) do
          {:ok, attrs} ->
            Tournament.update_fixture(f, attrs)
            [f.id]

          :skip ->
            []
        end
      end)

    if settled != [], do: Tournament.broadcast_change()

    %{candidates: length(candidates), settled: length(settled)}
  end

  defp body_fun do
    Application.get_env(:predictex, :fifa_fallback_body_fun, &Capture.latest_detail_body/1)
  end

  @doc """
  Decide whether a captured FIFA `/detail` body finalizes `fixture`. Pure.

  Returns `{:ok, %{status: :completed, home_goals: h, away_goals: a}}` only for an unsettled
  group fixture whose `body` is a finished frame with both integer scores; `:skip` otherwise.
  """
  @spec settle_attrs(map(), map() | nil) :: {:ok, map()} | :skip
  def settle_attrs(%{round: %{stage: :group}, status: status}, body)
      when status != :completed and is_map(body) do
    with 0 <- body["MatchStatus"],
         h when is_integer(h) <- get_in(body, ["HomeTeam", "Score"]),
         a when is_integer(a) <- get_in(body, ["AwayTeam", "Score"]) do
      {:ok, %{status: :completed, home_goals: h, away_goals: a}}
    else
      _ -> :skip
    end
  end

  def settle_attrs(_fixture, _body), do: :skip
end
