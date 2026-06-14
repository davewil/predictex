defmodule Predictex.Tournament.Round do
  @moduledoc """
  One of the 8 game rounds (`docs/rules.md` §4). Group rounds open for predictions
  immediately; a knockout round opens once every fixture in the previous round is
  completed — see `Predictex.Tournament.round_open?/1`.
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
