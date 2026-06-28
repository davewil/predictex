defmodule Predictex.Tournament.Fixture do
  @moduledoc """
  A single match. Field names mirror `Predictex.Results.Openfootball.parse/1` (the
  ingestion source) and exactly what `Predictex.Scoring.score/3` reads — the
  producer/consumer data contract is kept aligned on purpose (see `docs/rules.md` §9).

  `home_goals`/`away_goals` are the full-time (regulation) result; extra time and
  penalties are excluded upstream.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @sides [:home, :away]
  @statuses [:scheduled, :live, :completed]

  schema "fixtures" do
    field :external_ref, :string
    field :team1, :string
    field :team2, :string
    field :group, :string
    field :kickoff_at, :utc_datetime
    field :status, Ecto.Enum, values: @statuses, default: :scheduled
    field :home_goals, :integer
    field :away_goals, :integer
    field :first_scorer_side, Ecto.Enum, values: @sides
    field :first_scorer_player, :string
    field :first_goal_owngoal, :boolean, default: false
    field :cohort_home_pct, :integer
    field :cohort_draw_pct, :integer
    field :cohort_away_pct, :integer
    field :live_home_goals, :integer
    field :live_away_goals, :integer
    field :live_minute, :string
    field :is_live, :boolean, default: false
    field :fifa_match_id, :string
    # FIFA live `/detail` stage segment (per knockout round); nil → group stage at capture time.
    field :fifa_stage_id, :string
    # Stable openfootball match number (knockout only) — the identity the ingest keys on so a
    # KO fixture's teams resolve in place rather than spawning a duplicate (predictex-g8m).
    field :source_num, :integer

    embeds_many :goals, Goal, on_replace: :delete do
      field :side, Ecto.Enum, values: [:home, :away]
      field :type, Ecto.Enum, values: [:penalty, :own_goal, :regular]
      field :player, :string
      field :minute, :string
    end

    belongs_to :round, Predictex.Tournament.Round
    has_many :predictions, Predictex.Predictions.Prediction

    timestamps()
  end

  @castable [
    :external_ref,
    :source_num,
    :team1,
    :team2,
    :group,
    :kickoff_at,
    :status,
    :home_goals,
    :away_goals,
    :first_scorer_side,
    :first_scorer_player,
    :first_goal_owngoal,
    :cohort_home_pct,
    :cohort_draw_pct,
    :cohort_away_pct,
    :live_home_goals,
    :live_away_goals,
    :live_minute,
    :is_live,
    :fifa_match_id,
    :fifa_stage_id,
    :round_id
  ]

  @doc false
  def changeset(fixture, attrs) do
    fixture
    |> cast(attrs, @castable)
    |> cast_embed(:goals, with: &goal_changeset/2)
    |> validate_required([:external_ref, :team1, :team2, :status, :round_id])
    |> validate_number(:home_goals, greater_than_or_equal_to: 0)
    |> validate_number(:away_goals, greater_than_or_equal_to: 0)
    |> validate_cohort()
    |> assoc_constraint(:round)
    |> unique_constraint(:external_ref)
    |> unique_constraint(:source_num)
  end

  defp goal_changeset(goal, attrs) do
    goal
    |> cast(attrs, [:side, :type, :player, :minute])
    |> validate_required([:side, :type])
  end

  defp validate_cohort(changeset) do
    Enum.reduce([:cohort_home_pct, :cohort_draw_pct, :cohort_away_pct], changeset, fn field,
                                                                                      acc ->
      validate_number(acc, field, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    end)
  end

  def statuses, do: @statuses
  def sides, do: @sides
end
