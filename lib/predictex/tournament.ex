defmodule Predictex.Tournament do
  @moduledoc """
  Context for the tournament structure: rounds and fixtures.

  `round_open?/1` encodes the availability rule from `docs/rules.md` §4 — group
  rounds are open immediately; a knockout round opens once every fixture in the
  previous round is completed.
  """
  import Ecto.Query, warn: false

  alias Predictex.Repo
  alias Predictex.Tournament.{Fixture, Round}

  # --- rounds ---

  def list_rounds, do: Repo.all(from r in Round, order_by: r.ordinal)

  def get_round!(id), do: Repo.get!(Round, id)

  def get_round_by_ordinal(ordinal), do: Repo.get_by(Round, ordinal: ordinal)

  def create_round(attrs) do
    %Round{} |> Round.changeset(attrs) |> Repo.insert()
  end

  @doc "Whether a round is currently open for predictions."
  def round_open?(%Round{stage: :group}), do: true

  def round_open?(%Round{stage: :knockout, ordinal: ordinal}) do
    case get_round_by_ordinal(ordinal - 1) do
      nil -> false
      previous -> round_complete?(previous)
    end
  end

  @doc "Whether every fixture in a round has been completed (and the round has fixtures)."
  def round_complete?(%Round{id: round_id}) do
    counts =
      Repo.one(
        from f in Fixture,
          where: f.round_id == ^round_id,
          select: %{total: count(f.id), completed: count(f.id) |> filter(f.status == :completed)}
      )

    counts.total > 0 and counts.total == counts.completed
  end

  # --- fixtures ---

  def list_fixtures, do: Repo.all(Fixture)

  def count_fixtures, do: Repo.aggregate(Fixture, :count)

  def completed_fixture_count do
    Repo.aggregate(from(f in Fixture, where: f.status == :completed), :count)
  end

  def get_fixture!(id), do: Repo.get!(Fixture, id)

  def get_fixture_by_ref(external_ref), do: Repo.get_by(Fixture, external_ref: external_ref)

  def create_fixture(attrs) do
    %Fixture{} |> Fixture.changeset(attrs) |> Repo.insert()
  end

  def update_fixture(%Fixture{} = fixture, attrs) do
    fixture |> Fixture.changeset(attrs) |> Repo.update()
  end
end
