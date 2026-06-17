defmodule Predictex.Demo do
  @moduledoc """
  Seeded demo data for the buzz drill-down.

  Every demo player uses the `@demo.predictex.local` email domain — that domain
  is the single removal key. `purge/0` deletes by suffix; predictions cascade via
  the DB FK (`on_delete: :delete_all`). Real users never touch this domain.

  Driven on prod via:

      rpc "Predictex.Demo.seed()"
      rpc "Predictex.Demo.purge()"

  Not wired into any automatic seed or boot path.
  """

  import Ecto.Query, warn: false

  alias Predictex.{Accounts, Predictions, Repo}
  alias Predictex.Accounts.Player
  alias Predictex.Tournament.Fixture

  @demo_domain "demo.predictex.local"

  # Six demo players: first-name display names so the buzz reads well.
  # Ordered from "best predictor" to "worst" to create a natural scoring ladder
  # across completed fixtures.
  @demo_players [
    %{name: "Sav", email: "sav@#{@demo_domain}"},
    %{name: "Dave", email: "dave@#{@demo_domain}"},
    %{name: "Mia", email: "mia@#{@demo_domain}"},
    %{name: "Tom", email: "tom@#{@demo_domain}"},
    %{name: "Priya", email: "priya@#{@demo_domain}"},
    %{name: "Leo", email: "leo@#{@demo_domain}"}
  ]

  # Varied scoreline predictions per player index.
  # Index 0 (Sav) calls results exactly → highest total.
  # Each subsequent player misses one more fixture or picks a wrong outcome.
  # The "live" fixture (non-completed, last in fixture list) gets different
  # scorelines for every player so next-goal scenarios shuffle the order.
  #
  # Format: {home_goals, away_goals, booster?}
  # One booster per player (used on a different completed fixture each time).
  @scorelines_by_player_index [
    # Sav: exact on all completed fixtures, favourite on live
    [{3, 2, true}, {2, 0, false}, {4, 1, false}, {1, 0, false}],
    # Dave: exact on 2, correct outcome on 1, wrong on 1
    [{3, 2, false}, {2, 0, true}, {3, 1, false}, {0, 1, false}],
    # Mia: exact on 1, correct outcome on 2, wrong on 1
    [{3, 2, false}, {1, 0, false}, {4, 1, true}, {2, 1, false}],
    # Tom: correct outcome on 2, wrong on 2
    [{2, 1, false}, {2, 0, false}, {2, 0, false}, {1, 1, false}],
    # Priya: correct outcome on 1, wrong on 3
    [{1, 0, false}, {1, 0, false}, {2, 1, true}, {3, 1, false}],
    # Leo: wrong outcomes on most completed, different live pick
    [{0, 0, false}, {0, 1, false}, {1, 2, false}, {0, 2, true}]
  ]

  @doc """
  Seed ~6 demo players with varied predictions across existing fixtures.

  Idempotent: players that already exist by email are reused. Predictions are
  upserted so a re-run is safe.

  Returns `{players_created, predictions_created}`.
  """
  def seed do
    fixtures = Repo.all(from f in Fixture, order_by: [asc: f.inserted_at])

    {players, players_created} =
      Enum.reduce(@demo_players, {[], 0}, fn %{name: name, email: email}, {acc, count} ->
        case Accounts.get_player_by_email(email) do
          nil ->
            {:ok, player} =
              Accounts.register_player(%{
                email: email,
                password: "demo-password-#{name}!",
                display_name: name
              })

            {[player | acc], count + 1}

          existing ->
            {[existing | acc], count}
        end
      end)

    players = Enum.reverse(players)

    predictions_created =
      players
      |> Enum.with_index()
      |> Enum.reduce(0, fn {player, player_idx}, total ->
        scorelines = Enum.at(@scorelines_by_player_index, player_idx, [])

        fixtures
        |> Enum.with_index()
        |> Enum.reduce(0, fn {fixture, fix_idx}, count ->
          {home, away, booster} = Enum.at(scorelines, fix_idx, {1, 0, false})

          case Predictions.admin_upsert_prediction(%{
                 player_id: player.id,
                 fixture_id: fixture.id,
                 home_goals: home,
                 away_goals: away,
                 booster: booster
               }) do
            {:ok, _} -> count + 1
            {:error, _} -> count
          end
        end)
        |> then(&(total + &1))
      end)

    {players_created, predictions_created}
  end

  @doc """
  Delete every player whose email ends with `@demo.predictex.local`.

  Predictions are removed automatically via the DB cascade
  (`predictions.player_id` references `players` with `on_delete: :delete_all`).

  Returns the count of players removed.
  """
  def purge do
    {count, _} =
      from(p in Player, where: like(p.email, ^"%@#{@demo_domain}"))
      |> Repo.delete_all()

    count
  end

  @doc "Returns true if the player's email is in the demo domain."
  def demo?(%Player{email: email}), do: String.ends_with?(email, "@#{@demo_domain}")
end
