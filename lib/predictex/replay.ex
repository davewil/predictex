defmodule Predictex.Replay do
  @moduledoc """
  Re-plays a completed fixture's captured FIFA live timeline as in-process frames (predictex-i1s).

  `frames/1` projects the ordered `/detail` snapshot bodies for a match through
  `LiveScore.attrs_from_body/2`, carrying the last known score forward when a body
  has nil scores — matching the behaviour of the live worker.
  """

  alias Predictex.{Capture, LiveScore}

  @typedoc "A single score-frame produced by replaying a captured `/detail` snapshot."
  @type frame :: %{
          is_live: boolean(),
          live_home_goals: integer() | nil,
          live_away_goals: integer() | nil,
          live_minute: String.t() | nil
        }

  @seed %{live_home_goals: 0, live_away_goals: 0}

  @doc """
  Returns ordered score-frames for `match_id`, one per captured `/detail` snapshot.

  Each frame is `%{is_live, live_home_goals, live_away_goals, live_minute}`.
  Returns `[]` when the match has no detail captures.
  """
  @spec frames(String.t()) :: [frame()]
  def frames(match_id) do
    details =
      match_id
      |> Capture.list_snapshots()
      |> Enum.filter(&(&1.endpoint == "detail" and is_map(&1.body)))

    {frames, _acc} =
      Enum.map_reduce(details, @seed, fn snapshot, prev_attrs ->
        attrs = LiveScore.attrs_from_body(snapshot.body, prev_attrs)
        {attrs, attrs}
      end)

    frames
  end
end
