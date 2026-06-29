defmodule Predictex.LiveScore.Updater do
  @moduledoc """
  Subscriber that turns published FIFA snapshots into the live buzz: decode → write
  `live_*` → broadcast `{:live_update}` (predictex-rfm). Independent of the Recorder.
  """
  use GenServer
  require Logger
  alias Predictex.{LiveScore, Tournament}

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @impl true
  def init(:ok) do
    Phoenix.PubSub.subscribe(Predictex.PubSub, "fifa:snapshots")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:snapshot, fixture_id, body, _captured_at, _match_id, _url}, state) do
    fixture = Tournament.get_fixture!(fixture_id)
    LiveScore.apply_to_fixture(fixture, LiveScore.attrs_from_body(body, fixture))
    {:noreply, state}
  rescue
    e ->
      Logger.error(
        "live updater crashed for fixture #{inspect(fixture_id)}: #{Exception.message(e)}"
      )

      {:noreply, state}
  end
end
