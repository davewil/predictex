defmodule Predictex.Workers.PlayersSync do
  @moduledoc """
  Oban worker (cron, every 30 min) that refreshes the FIFA squads cache so the first-player
  picker's `stats.goals` track played matches (predictex-u4k). The roster itself is static;
  this is purely a freshness tick. A failed fetch is logged inside `Cache.refresh/0` and the
  stale cache is kept — so `perform/1` always returns `:ok` (no queue crash-loop for a flaky feed).
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Predictex.Fifa.Players.Cache

  @impl Oban.Worker
  def perform(_job) do
    _ = Cache.refresh()
    :ok
  end
end
