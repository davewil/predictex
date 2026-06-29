defmodule Predictex.LiveScore.Updater do
  @moduledoc """
  Subscriber that turns published FIFA snapshots into the live buzz: decode → write
  `live_*` → broadcast `{:live_update}` (predictex-rfm). Independent of the Recorder.
  """
  use GenServer
  alias Predictex.{LiveScore, Tournament}

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @impl true
  def init(:ok) do
    Phoenix.PubSub.subscribe(Predictex.PubSub, "fifa:snapshots")
    {:ok, %{}}
  end

  # No `rescue` here, by design (predictex-bl8). Resilience to a malformed body lives in the
  # decode being total (`LiveScore.attrs_from_body` tolerates schema drift) and in the write
  # returning a typed `{:error, cs}` it logs itself — neither raises. The only raises left are a
  # genuinely-missing fixture (`get_fixture!`) or a DB outage, both of which are better surfaced
  # as a supervised crash (visible via telemetry) than a swallowed `Logger.error`: the poison
  # message is gone from the mailbox on restart, `init/1` re-subscribes, and the next ~30s
  # snapshot re-drives the state. A bare catch-all rescue would instead mask a systematic schema
  # break as a silently-dead buzz feature for the whole tournament.
  @impl true
  def handle_info({:snapshot, fixture_id, body, _captured_at, _match_id, _url}, state) do
    fixture = Tournament.get_fixture!(fixture_id)
    LiveScore.apply_to_fixture(fixture, LiveScore.attrs_from_body(body, fixture))
    {:noreply, state}
  end
end
