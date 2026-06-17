defmodule Predictex.Capture.Recorder do
  @moduledoc """
  Subscriber that persists every published FIFA snapshot to `fifa_captures` — the
  replayable event source (predictex-rfm, predictex-i1s). Independent of the buzz path.
  """
  use GenServer
  require Logger
  alias Predictex.Capture

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @impl true
  def init(:ok) do
    Phoenix.PubSub.subscribe(Predictex.PubSub, "fifa:snapshots")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:snapshot, _fixture_id, body, captured_at, match_id, url}, state) do
    attrs = %{
      captured_at: captured_at,
      endpoint: "detail",
      url: url,
      match_id: match_id,
      http_status: 200,
      body: body,
      error: nil
    }

    case Capture.record_snapshot(attrs) do
      {:ok, _} -> :ok
      {:error, cs} -> Logger.error("snapshot persist failed (#{match_id}): #{inspect(cs.errors)}")
    end

    {:noreply, state}
  end
end
