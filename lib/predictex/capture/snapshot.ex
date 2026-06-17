defmodule Predictex.Capture.Snapshot do
  @moduledoc "One raw FIFA v3 API response captured during a match window (predictex-rfm)."
  use Ecto.Schema
  import Ecto.Changeset

  schema "fifa_captures" do
    field :captured_at, :utc_datetime_usec
    field :endpoint, :string
    field :url, :string
    field :match_id, :string
    field :http_status, :integer
    field :body, :map
    field :error, :string
  end

  @fields [:captured_at, :endpoint, :url, :match_id, :http_status, :body, :error]

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, @fields)
    |> validate_required([:captured_at, :endpoint, :url, :match_id])
  end
end
