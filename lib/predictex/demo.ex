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

  # Scoreline palette — a spread of plausible results. Each (player, fixture)
  # pair picks deterministically from this so that, on ANY single fixture, the
  # six demo players hold ~six different scorelines. That divergence is what
  # makes the live "buzz" move: when a goal goes in, different players' points
  # jump by different amounts, so ranks actually shuffle (overtakes, headlines).
  #
  # The step constants (player*7, fixture*3) are coprime-ish with the palette
  # length (10), so both axes spread well without clustering.
  @palette [
    {1, 0},
    {2, 1},
    {1, 1},
    {0, 0},
    {2, 0},
    {0, 1},
    {1, 2},
    {3, 1},
    {0, 2},
    {2, 2}
  ]

  defp scoreline(player_idx, fixture_idx) do
    {h, a} = Enum.at(@palette, rem(player_idx * 7 + fixture_idx * 3, length(@palette)))
    {h, a}
  end

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
        fixtures
        |> Enum.with_index()
        |> Enum.reduce(0, fn {fixture, fix_idx}, count ->
          {home, away} = scoreline(player_idx, fix_idx)

          case Predictions.admin_upsert_prediction(%{
                 player_id: player.id,
                 fixture_id: fixture.id,
                 home_goals: home,
                 away_goals: away,
                 booster: false
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
