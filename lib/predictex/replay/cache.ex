defmodule Predictex.Replay.Cache do
  @moduledoc """
  Shared immutable ETS cache for completed-match frame timelines (predictex-i1s).

  `frames/1` returns the same projected list as `Predictex.Replay.frames/1`, but
  on a hit it reads directly from ETS in the calling process (lock-free, parallel).
  A miss is funnelled through the GenServer owner, which re-checks the table to guard
  against thundering-herd double-loads, then calls `Replay.frames/1` once, inserts,
  and returns the result.

  The table is `:set, :public, read_concurrency: true` — safe because only the owner
  writes and capture timelines for completed fixtures never change.
  """

  use GenServer

  alias Predictex.Replay

  @table __MODULE__

  ## Public API

  @doc "Returns ordered score-frames for `match_id`, loading from `Replay.frames/1` on a miss."
  @spec frames(String.t()) :: [Replay.frame()]
  def frames(match_id) do
    case :ets.lookup(@table, match_id) do
      [{^match_id, cached}] -> cached
      [] -> GenServer.call(__MODULE__, {:load, match_id})
    end
  end

  ## GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, {:read_concurrency, true}])
    {:ok, :no_state}
  end

  @impl GenServer
  def handle_call({:load, match_id}, _from, state) do
    # Re-check: another caller may have loaded the entry while this call was queued.
    frames =
      case :ets.lookup(@table, match_id) do
        [{^match_id, cached}] ->
          cached

        [] ->
          result = Replay.frames(match_id)
          :ets.insert(@table, {match_id, result})
          result
      end

    {:reply, frames, state}
  end
end
