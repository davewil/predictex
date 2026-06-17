defmodule Predictex.Spike do
  @moduledoc """
  SPIKE (predictex-70h) — throwaway helpers for the FIFA live-feed capture.

  `record_capture/1` persists one raw API response; `list_captures/1` reads a match's
  capture timeline back for analysis (e.g. via `bin/predictex rpc`). Remove once
  LiveScoreSync ships and the `fifa_captures` table is dropped.
  """
  import Ecto.Query, only: [from: 2]

  alias Predictex.Repo
  alias Predictex.Spike.FifaCapture

  def record_capture(attrs) do
    %FifaCapture{}
    |> FifaCapture.changeset(attrs)
    |> Repo.insert()
  end

  def list_captures(match_id) do
    Repo.all(
      from c in FifaCapture,
        where: c.match_id == ^match_id,
        order_by: [asc: c.captured_at]
    )
  end
end
