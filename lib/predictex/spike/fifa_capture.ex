defmodule Predictex.Spike.FifaCapture do
  @moduledoc """
  SPIKE (predictex-70h) — one raw FIFA v3 API response captured during a match window.

  Throwaway analysis table: `body` is the decoded JSON as-is, `error` is set instead
  when the fetch failed. Drop the table + this module once LiveScoreSync is built.
  """
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

  def changeset(capture, attrs) do
    capture
    |> cast(attrs, @fields)
    |> validate_required([:captured_at, :endpoint, :url, :match_id])
  end
end
