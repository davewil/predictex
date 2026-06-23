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
