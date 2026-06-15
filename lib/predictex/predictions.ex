defmodule Predictex.Predictions do
  @moduledoc """
  Context for player predictions.

  `create_prediction/2` follows Gather → Decide → Act: it gathers the fixture (for
  its round and kickoff time), decides whether the fixture has locked at kickoff,
  then acts by inserting. The denormalized `round_id` is always set from the fixture,
  so it cannot drift.
  """
  import Ecto.Query, warn: false

  alias Predictex.Repo
  alias Predictex.Predictions.Prediction
  alias Predictex.Tournament.Fixture

  def list_predictions, do: Repo.all(Prediction)

  @doc "All of one player's predictions (any round, any fixture state)."
  def list_player_predictions(player_id) do
    Repo.all(from p in Prediction, where: p.player_id == ^player_id)
  end

  def change_prediction(%Prediction{} = prediction \\ %Prediction{}, attrs \\ %{}) do
    Prediction.changeset(prediction, attrs)
  end

  @doc """
  Create a prediction for a fixture.

  Returns `{:ok, prediction}`, `{:error, changeset}` on validation/constraint
  failure, `{:error, :locked}` if the fixture has kicked off, or
  `{:error, :fixture_not_found}` for an unknown fixture.
  """
  def create_prediction(attrs, now \\ DateTime.utc_now()) do
    with {:ok, fixture} <- fetch_fixture(attrs),
         :ok <- ensure_open(fixture, now) do
      attrs
      |> Map.put(:round_id, fixture.round_id)
      |> Map.put(:fixture_id, fixture.id)
      |> then(&Prediction.changeset(%Prediction{}, &1))
      |> Repo.insert()
    end
  end

  @doc "A fixture is locked for predictions once kickoff has passed."
  def locked?(%Fixture{kickoff_at: nil}, _now), do: false
  def locked?(%Fixture{kickoff_at: kickoff}, now), do: DateTime.compare(now, kickoff) != :lt

  # --- internals ---

  defp fetch_fixture(attrs) do
    case attrs[:fixture_id] || attrs["fixture_id"] do
      nil ->
        {:error, :fixture_not_found}

      id ->
        case Repo.get(Fixture, id) do
          nil -> {:error, :fixture_not_found}
          fixture -> {:ok, fixture}
        end
    end
  end

  defp ensure_open(fixture, now) do
    if locked?(fixture, now), do: {:error, :locked}, else: :ok
  end
end
