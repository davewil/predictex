defmodule Predictex.Dashboard do
  @moduledoc """
  Read model for the member's personal "My Predictions" dashboard.

  Gather → Decide: `for_player/2` is the I/O edge (loads rounds+fixtures, the player's
  predictions, and the player's `Predictex.Standings` entry); `build/4` is pure and
  DB-free. `Predictex.Standings` is the single scoring authority — `build/4` does NO
  scoring arithmetic, only joining, lock state, display flags, and tab selection, so the
  headline total can never disagree with the leaderboard rank.
  """
  import Ecto.Query, warn: false

  alias Predictex.{Repo, Predictions, Standings}
  alias Predictex.Tournament.{Round, Fixture}

  @doc """
  Load and assemble the dashboard for `player`. `standing` is `%{entry, rank, of}` where
  `entry` is the player's `Standings.leaderboard/0` map (or nil if absent).
  """
  def for_player(player, now \\ DateTime.utc_now()) do
    fixtures_q = from(f in Fixture, order_by: [asc: f.kickoff_at, asc: f.id])

    rounds =
      Repo.all(from r in Round, order_by: r.ordinal, preload: [fixtures: ^fixtures_q])

    predictions_by_fixture =
      player.id
      |> Predictions.list_player_predictions()
      |> Map.new(&{&1.fixture_id, &1})

    standings = Standings.leaderboard()
    index = Enum.find_index(standings, &(&1.player_id == player.id))

    standing = %{
      entry: index && Enum.at(standings, index),
      rank: (index && index + 1) || length(standings) + 1,
      of: length(standings)
    }

    build(rounds, predictions_by_fixture, standing, now)
  end

  @doc "Pure assembly of the view model. See module doc."
  def build(rounds, predictions_by_fixture, standing, now) do
    entry = standing.entry

    {points_by_fixture, bonus_by_round} =
      case entry do
        nil -> {%{}, %{}}
        e -> {Map.new(e.breakdown, &{&1.fixture_id, &1.result.fixture_total}), e.bonus_by_round}
      end

    {total, fixtures_total, round_bonus_total} =
      case entry do
        nil -> {0, 0, 0}
        e -> {e.total, e.fixtures_total, e.round_bonus_total}
      end

    round_views =
      Enum.map(rounds, fn round ->
        %{
          round: round,
          round_bonus: Map.get(bonus_by_round, round.ordinal, 0),
          complete?:
            round.fixtures != [] and Enum.all?(round.fixtures, &(&1.status == :completed)),
          fixtures:
            Enum.map(
              round.fixtures,
              &fixture_view(&1, predictions_by_fixture, points_by_fixture, now)
            )
        }
      end)

    active = active_ordinal(round_views)

    %{
      rank: standing.rank,
      of: standing.of,
      total: total,
      fixtures_total: fixtures_total,
      round_bonus_total: round_bonus_total,
      rounds: Enum.map(round_views, &Map.put(&1, :active?, &1.round.ordinal == active))
    }
  end

  defp fixture_view(fixture, predictions_by_fixture, points_by_fixture, now) do
    prediction = Map.get(predictions_by_fixture, fixture.id)

    %{
      fixture: fixture,
      prediction: prediction,
      status: fixture.status,
      locked?: Predictions.locked?(fixture, now),
      points: Map.get(points_by_fixture, fixture.id),
      booster?: prediction != nil and prediction.booster == true,
      exact?: exact?(prediction, fixture)
    }
  end

  defp exact?(nil, _fixture), do: false
  defp exact?(_prediction, %{status: status}) when status != :completed, do: false

  defp exact?(prediction, fixture),
    do:
      prediction.home_goals == fixture.home_goals and prediction.away_goals == fixture.away_goals

  # Lowest-ordinal round not fully complete; if every round is complete, the highest ordinal.
  defp active_ordinal([]), do: nil

  defp active_ordinal(round_views) do
    case Enum.find(round_views, &(not &1.complete?)) do
      nil -> round_views |> List.last() |> Map.fetch!(:round) |> Map.fetch!(:ordinal)
      rv -> rv.round.ordinal
    end
  end
end
