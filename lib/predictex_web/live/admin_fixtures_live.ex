defmodule PredictexWeb.AdminFixturesLive do
  @moduledoc """
  Admin fixtures: trigger a results sync, override a result by hand, and enter per-fixture
  FIFA cohort percentages (which drive the risky bonus). Unset cohort is shown explicitly.
  The sync source is injectable (`:admin_sync_fun`) so tests can avoid the network.
  """
  use PredictexWeb, :live_view

  alias Predictex.Results.Ingest
  alias Predictex.Tournament

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
    sync_fun = Application.get_env(:predictex, :admin_sync_fun, &Ingest.sync_from_url/0)

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

    case Tournament.update_fixture(fixture, attrs) do
      {:ok, _} -> {:noreply, socket |> load_fixtures() |> put_flash(:info, ok_msg)}
      {:error, _cs} -> {:noreply, put_flash(socket, :error, "Could not save fixture.")}
    end
  end

  defp cohort_set?(f), do: f.cohort_home_pct && f.cohort_draw_pct && f.cohort_away_pct

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <PredictexWeb.AdminComponents.admin_nav active={:fixtures} />

      <button phx-click="sync" class="btn btn-secondary mb-4" disabled={@syncing}>
        {if @syncing, do: "Syncing…", else: "Sync from feed"}
      </button>

      <div :for={f <- @fixtures} class="card bg-base-200 p-4 mb-3">
        <div class="font-medium mb-2">{f.team1} v {f.team2}</div>

        <form
          id={"fixture-#{f.id}-result"}
          phx-submit="save_result"
          class="flex flex-wrap gap-2 items-end mb-2"
        >
          <input type="hidden" name="fixture_id" value={f.id} />
          <label class="text-xs">
            H<input
              type="number"
              min="0"
              name="fixture[home_goals]"
              value={f.home_goals}
              class="input input-bordered input-sm w-16"
            />
          </label>
          <label class="text-xs">
            A<input
              type="number"
              min="0"
              name="fixture[away_goals]"
              value={f.away_goals}
              class="input input-bordered input-sm w-16"
            />
          </label>
          <label class="text-xs">
            Status
            <select name="fixture[status]" class="select select-bordered select-sm">
              <option value="scheduled" selected={f.status == :scheduled}>scheduled</option>
              <option value="completed" selected={f.status == :completed}>completed</option>
            </select>
          </label>
          <button type="submit" class="btn btn-sm btn-primary">Save result</button>
        </form>

        <form
          id={"fixture-#{f.id}-cohort"}
          phx-submit="save_cohort"
          class="flex flex-wrap gap-2 items-end"
        >
          <input type="hidden" name="fixture_id" value={f.id} />
          <label class="text-xs">
            Home%<input
              type="number"
              min="0"
              max="100"
              name="fixture[cohort_home_pct]"
              value={f.cohort_home_pct}
              class="input input-bordered input-sm w-16"
            />
          </label>
          <label class="text-xs">
            Draw%<input
              type="number"
              min="0"
              max="100"
              name="fixture[cohort_draw_pct]"
              value={f.cohort_draw_pct}
              class="input input-bordered input-sm w-16"
            />
          </label>
          <label class="text-xs">
            Away%<input
              type="number"
              min="0"
              max="100"
              name="fixture[cohort_away_pct]"
              value={f.cohort_away_pct}
              class="input input-bordered input-sm w-16"
            />
          </label>
          <button type="submit" class="btn btn-sm">Save cohort</button>
          <span :if={!cohort_set?(f)} class="badge badge-warning">cohort not set — risky bonus off</span>
        </form>
      </div>
    </Layouts.app>
    """
  end
end
