defmodule Predictex.Tournament.Round do
  @moduledoc """
  One of the 8 game rounds (`docs/rules.md` §4). Knockout fixtures open per-fixture
  once both team slots are resolved and kickoff is in the future — see
  `Predictex.Scoring.Knockout.resolved_team?/1` and `Predictex.Predictions.fixture_entry_state/2`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @stages [:group, :knockout]

  schema "rounds" do
    field :name, :string
    field :stage, Ecto.Enum, values: @stages
    field :ordinal, :integer
    field :opens_at, :utc_datetime
    field :opened, :boolean, default: false

    has_many :fixtures, Predictex.Tournament.Fixture

    timestamps()
  end

  @doc false
  def changeset(round, attrs) do
    round
    |> cast(attrs, [:name, :stage, :ordinal, :opens_at, :opened])
    |> validate_required([:name, :stage, :ordinal])
    |> validate_inclusion(:ordinal, 1..8)
    |> unique_constraint(:ordinal)
  end

  def stages, do: @stages
end
