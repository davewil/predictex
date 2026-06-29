defmodule PredictexWeb.AdminFixturesLive do
  @moduledoc """
  Admin fixtures: trigger a results sync, override a result by hand, and enter per-fixture
  FIFA cohort percentages (which drive the risky bonus). Unset cohort is shown explicitly.
  The sync source is injectable (`:result_sync_fun`, shared with the ResultSync cron worker)
  so tests can avoid the network.
  """
  use PredictexWeb, :live_view

  alias Predictex.Results.Ingest
  alias Predictex.Tournament
  alias PredictexWeb.AdminWriteResult
  alias PredictexWeb.Flags

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Fixtures")
     |> assign(:syncing, false)
     |> load_fixtures()}
  end

  defp load_fixtures(socket) do
    assign(socket, :fixtures, Tournament.list_fixtures() |> Enum.sort_by(& &1.id))
  end

  @impl true
  def handle_event("sync", _params, socket) do
    sync_fun = Application.get_env(:predictex, :result_sync_fun, &Ingest.sync_from_url/0)

    {:noreply,
     socket
     |> assign(:syncing, true)
     |> start_async(:sync, sync_fun)}
  end

  def handle_event("save_result", %{"fixture_id" => id, "fixture" => attrs}, socket) do
    update_fixture(socket, id, attrs, "Result saved.")
  end

  def handle_event("save_cohort", %{"fixture_id" => id, "fixture" => attrs}, socket) do
    update_fixture(socket, id, attrs, "Cohort saved.")
  end

  @impl true
  def handle_async(:sync, {:ok, summary}, socket) do
    {:noreply,
     socket
     |> assign(:syncing, false)
     |> load_fixtures()
     |> put_flash(:info, "Sync complete: #{inspect(summary)}")}
  end

  def handle_async(:sync, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:syncing, false)
     |> put_flash(:error, "Sync failed: #{inspect(reason)}")}
  end

  defp update_fixture(socket, id, attrs, ok_msg) do
    fixture = Tournament.get_fixture!(id)

    AdminWriteResult.handle(
      socket,
      Tournament.update_fixture(fixture, attrs),
      &load_fixtures/1,
      ok_msg,
      "Could not save fixture."
    )
  end

  defp cohort_set?(f), do: f.cohort_home_pct && f.cohort_draw_pct && f.cohort_away_pct
end
