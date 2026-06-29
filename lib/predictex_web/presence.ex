defmodule PredictexWeb.Presence do
  @moduledoc """
  Live viewer presence — "who's watching" — riding the existing `Predictex.PubSub`
  (see `docs/adr/0002-pubsub-live-update-architecture.md`). No new clustering or deps:
  Presence tracks connected web-tier sockets, so it is unaffected by a future
  ADR-0001 worker split.

  Two topics, deliberately distinct (mirroring the PubSub topic split):

  - `"fixture_presence:<id>"` — per-match watchers, for FixtureLive's names+count
    indicator. Keyed by player id, meta `%{name: display_name}`.
  - `"watching:live"` — the cross-match aggregate of viewers currently on a *live*
    fixture, for LeaderboardLive's count. Keyed by player id; FixtureLive joins it
    only while the persisted `fixture.is_live` is true.

  Entries are dropped automatically on socket process DOWN — no manual untrack on
  unmount, no `terminate/2`.
  """
  use Phoenix.Presence,
    otp_app: :predictex,
    pubsub_server: Predictex.PubSub

  @doc """
  Distinct watchers from a `list/1` map, as a `%{id, name}` list sorted by name.

  Multiple metas under one key (the same player in several tabs) collapse to one
  watcher — the count is players, not sockets.
  """
  def watcher_list(presence_map) do
    presence_map
    |> Enum.map(fn {id, %{metas: [meta | _]}} -> %{id: id, name: meta.name} end)
    |> Enum.sort_by(& &1.name)
  end

  @doc "Number of distinct watchers (keys) in a `list/1` map."
  def watch_count(presence_map), do: map_size(presence_map)
end
