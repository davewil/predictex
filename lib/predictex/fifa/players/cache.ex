defmodule Predictex.Fifa.Players.Cache do
  @moduledoc """
  Supervised ETS cache of FIFA squads for the first-player picker (predictex-u4k).

  `for_team/1` reads the table lock-free in the caller; the first miss funnels through the
  GenServer owner (which re-checks a `:__loaded__` sentinel to guard against a thundering-herd
  double-load), fetches `players.json` + `squads.json` once, and repopulates. `refresh/0` is the
  same load forced (the cron `PlayersSync` worker calls it so `stats.goals` stays current).

  The table is `:set, :public, read_concurrency: true` — only the owner writes. The fetch source
  is injectable via `:players_source_fun` (network-free tests); boot-warm via `:warm_players_cache`.
  """
  use GenServer

  require Logger

  alias Predictex.Fifa.{Crosswalk, Players, Reference}

  @table __MODULE__
  @players_url "https://play.fifa.com/json/match_predictor/players.json"
  @squads_url "https://play.fifa.com/json/match_predictor/squads.json"
  # After a cold-load failure, suppress re-fetches for this window. This prevents a
  # fetch-storm when the FIFA feed is down on boot: every render that calls for_team/1
  # would otherwise funnel through the GenServer and re-enter the 30s Req.get.
  @retry_backoff_ms 60_000

  ## Public API

  @doc "Squad list for `team` (alias-normalised). Lazy-loads on first miss; `[]` on unknown/failed."
  @spec for_team(String.t()) :: [map()]
  def for_team(team) do
    ensure_loaded()

    case :ets.lookup(@table, Crosswalk.norm(team)) do
      [{_key, players}] -> players
      [] -> []
    end
  end

  @doc "Force a re-fetch + repopulate. `:ok | {:error, reason}`."
  @spec refresh() :: :ok | {:error, term()}
  def refresh, do: GenServer.call(__MODULE__, :load, 30_000)

  @doc "Fetch `players.json` + `squads.json`. `{:ok, %{players, squads}} | {:error, reason}`."
  def fetch do
    with {:ok, players} <- Reference.get_json(@players_url),
         {:ok, squads} <- Reference.get_json(@squads_url) do
      {:ok, %{players: players, squads: squads}}
    end
  end

  ## GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, {:read_concurrency, true}])
    if Application.get_env(:predictex, :warm_players_cache, true), do: send(self(), :warm)
    {:ok, :no_state}
  end

  @impl GenServer
  def handle_info(:warm, state) do
    _ = load()
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:load, _from, state), do: {:reply, load(), state}

  def handle_call(:ensure, _from, state) do
    unless loaded?(), do: load()
    {:reply, :ok, state}
  end

  ## Internals

  defp ensure_loaded do
    cond do
      loaded?() ->
        :ok

      failed_recently?() ->
        # Within the backoff window after a cold-load failure — short-circuit without a
        # GenServer roundtrip. for_team/1 reads from the table: stale data on a warm cache,
        # or [] on a cold one. Either is preferable to serialising every render behind a
        # 30s Req.get when the FIFA feed is down.
        :ok

      true ->
        GenServer.call(__MODULE__, :ensure, 30_000)
    end
  end

  defp loaded? do
    case :ets.lookup(@table, :__loaded__) do
      [{:__loaded__, true}] -> true
      [] -> false
    end
  end

  defp failed_recently? do
    case :ets.lookup(@table, :__failed_at__) do
      [{:__failed_at__, failed_at}] ->
        System.monotonic_time(:millisecond) - failed_at < @retry_backoff_ms

      [] ->
        false
    end
  end

  defp load do
    case source_fun().() do
      {:ok, %{players: players, squads: squads}} ->
        map = Players.parse(players, squads)
        # Overwrite each team row in-place (`:set` semantics) instead of deleting the whole
        # table first. Concurrent readers always see old-or-new squad data, never an empty
        # snapshot mid-refresh. The 48 team-keys are stable across loads so no stale key leaks.
        Enum.each(map, fn {team, list} -> :ets.insert(@table, {team, list}) end)
        :ets.delete(@table, :__failed_at__)
        :ets.insert(@table, {:__loaded__, true})
        Logger.info("players cache: #{map_size(map)} squads loaded")
        :ok

      {:error, reason} ->
        # Keep any existing (stale) cache on a failed refresh: a transient feed blip during
        # the cron refresh must NOT empty the picker for all members. A cold cache stays empty
        # (the :ok branch never ran, sentinel unset) so for_team/1 returns []; we stamp a
        # :__failed_at__ marker so subsequent ensure_loaded/0 calls short-circuit for
        # @retry_backoff_ms instead of re-entering the 30s fetch on every render.
        Logger.error("players cache load failed: #{inspect(reason)}")
        :ets.insert(@table, {:__failed_at__, System.monotonic_time(:millisecond)})
        {:error, reason}
    end
  end

  defp source_fun, do: Application.get_env(:predictex, :players_source_fun, &fetch/0)
end
