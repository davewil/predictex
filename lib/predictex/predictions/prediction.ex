defmodule Predictex.Predictions.Prediction do
  @moduledoc """
  A player's prediction for one fixture. Carries a denormalized `round_id` (kept in
  step with the fixture's round) so the one-booster-per-round rule can be enforced by
  a partial unique index. Field names match `Predictex.Scoring.score/3`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @sides [:home, :away]

  schema "predictions" do
    field :home_goals, :integer
    field :away_goals, :integer
    field :first_scorer_side, Ecto.Enum, values: @sides
    field :first_scorer_player, :string
    field :first_scorer_fifaid, :integer
    field :booster, :boolean, default: false

    belongs_to :player, Predictex.Accounts.Player
    belongs_to :fixture, Predictex.Tournament.Fixture
    belongs_to :round, Predictex.Tournament.Round

    timestamps()
  end

  @doc false
  def changeset(prediction, attrs) do
    prediction
    |> cast(attrs, [
      :home_goals,
      :away_goals,
      :first_scorer_side,
      :first_scorer_player,
      :first_scorer_fifaid,
      :booster,
      :player_id,
      :fixture_id,
      :round_id
    ])
    |> validate_required([:home_goals, :away_goals, :player_id, :fixture_id, :round_id])
    |> validate_number(:home_goals, greater_than_or_equal_to: 0, less_than_or_equal_to: 9)
    |> validate_number(:away_goals, greater_than_or_equal_to: 0, less_than_or_equal_to: 9)
    |> assoc_constraint(:player)
    |> assoc_constraint(:fixture)
    |> assoc_constraint(:round)
    |> unique_constraint([:player_id, :fixture_id],
      name: :predictions_player_id_fixture_id_index,
      message: "already predicted this fixture"
    )
    |> unique_constraint([:player_id, :round_id],
      name: :one_booster_per_player_round,
      message: "booster already used in this round"
    )
  end
end
