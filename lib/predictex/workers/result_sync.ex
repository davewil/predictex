defmodule Predictex.Workers.ResultSync do
  @moduledoc """
  Oban worker that pulls fresh openfootball results on a schedule (every 15 min, see the
  Cron config). Delegates to the same injectable sync source the admin "Sync from feed"
  button uses (`:result_sync_fun`, default `Results.Ingest.sync_from_url/0`), so tests run
  network-free.

  `sync_from_url/0` returns a summary map on success or `{:error, reason}` on HTTP failure;
  returning the error from `perform/1` lets Oban retry with backoff (`max_attempts: 3`).
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Predictex.Results.Ingest

  @impl Oban.Worker
  def perform(_job) do
    case sync_fun().() do
      {:error, reason} ->
        Logger.error("result sync failed: #{inspect(reason)}")
        {:error, reason}

      summary ->
        Logger.info("result sync ok: #{inspect(summary)}")
        :ok
    end
  end

  defp sync_fun do
    Application.get_env(:predictex, :result_sync_fun, &Ingest.sync_from_url/0)
  end
end
