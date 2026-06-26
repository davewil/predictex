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

  # --- fixture-change pub/sub (predictex-9p0) ---
  #
  # One coarse "a fixture changed, re-pull" signal, broadcast AFTER the DB write by both
  # producers of fixture state: `LiveScore.apply_to_fixture/2` (live scores, FIFA) and
  # `Results.Ingest.commit/1` (settle + results, openfootball). `MyPredictionsLive` subscribes
  # once and re-pulls its dashboard. The drill-down `FixtureLive` keeps its per-fixture
  # `"fixture:#{id}"` topic — this is the dashboard's "anything changed" feed.
  @changes_topic "fixtures:changed"

  @doc "Subscribe the calling process to coarse fixture-change notifications."
  def subscribe_changes, do: Phoenix.PubSub.subscribe(Predictex.PubSub, @changes_topic)

  @doc "Broadcast a coarse `:fixtures_changed` to all subscribers (call after a DB write)."
  def broadcast_change,
    do: Phoenix.PubSub.broadcast(Predictex.PubSub, @changes_topic, :fixtures_changed)

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

  def list_live_fixtures, do: Repo.all(from f in Fixture, where: f.is_live == true)

  def count_fixtures, do: Repo.aggregate(Fixture, :count)

  def completed_fixture_count do
    Repo.aggregate(from(f in Fixture, where: f.status == :completed), :count)
  end

  def get_fixture!(id, preloads \\ []), do: Repo.get!(Fixture, id) |> Repo.preload(preloads)

  def get_fixture_by_ref(external_ref), do: Repo.get_by(Fixture, external_ref: external_ref)

  @doc "Look up a fixture by its stable openfootball match number (knockout only; predictex-g8m)."
  def get_fixture_by_source_num(num), do: Repo.get_by(Fixture, source_num: num)

  @doc "All group-stage fixtures (round `stage: :group`)."
  def group_stage_fixtures do
    Repo.all(
      from f in Fixture,
        join: r in Round,
        on: f.round_id == r.id,
        where: r.stage == :group
    )
  end

  @doc """
  Fixtures of the Round of 32 — the lowest-`ordinal` `:knockout` round — ordered by
  `source_num`. Returns `[]` when no knockout round exists yet.
  """
  def r32_fixtures do
    r32_id =
      Repo.one(
        from r in Round,
          where: r.stage == :knockout,
          order_by: [asc: r.ordinal],
          limit: 1,
          select: r.id
      )

    case r32_id do
      nil -> []
      id -> Repo.all(from f in Fixture, where: f.round_id == ^id, order_by: [asc: f.source_num])
    end
  end

  def create_fixture(attrs) do
    %Fixture{} |> Fixture.changeset(attrs) |> Repo.insert()
  end

  def update_fixture(%Fixture{} = fixture, attrs) do
    fixture |> Fixture.changeset(attrs) |> Repo.update()
  end
end
