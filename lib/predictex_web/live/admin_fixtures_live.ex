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

      <div class="mb-4 flex items-center justify-between gap-3">
        <PredictexWeb.AdminComponents.admin_stat label="fixtures" value={length(@fixtures)} />
        <button phx-click="sync" class="btn btn-info btn-soft btn-sm gap-2" disabled={@syncing}>
          {if @syncing, do: "Syncing…", else: "⟳ Sync from feed"}
        </button>
      </div>

      <div
        :for={f <- @fixtures}
        class="mb-3 rounded-box border border-base-300 bg-base-100 p-4"
      >
        <div class="mb-3 flex items-center justify-between gap-2">
          <div class="font-bold">
            {Flags.flag(f.team1)} {f.team1} <span class="text-base-content/40">v</span> {f.team2} {Flags.flag(f.team2)}
          </div>
          <span class={[
            "rounded-md px-2 py-0.5 text-[10px] font-bold uppercase tracking-wider",
            (f.status == :completed && "bg-success/15 text-success") || "bg-base-200 text-base-content/55"
          ]}>
            {f.status}
          </span>
        </div>

        <form
          id={"fixture-#{f.id}-result"}
          phx-submit="save_result"
          class="mb-3 flex flex-wrap items-end gap-2"
        >
          <input type="hidden" name="fixture_id" value={f.id} />
          <label class="text-xs text-base-content/60">
            H<input
              type="number"
              min="0"
              name="fixture[home_goals]"
              value={f.home_goals}
              class="input input-bordered input-sm font-score ml-1 w-16"
            />
          </label>
          <label class="text-xs text-base-content/60">
            A<input
              type="number"
              min="0"
              name="fixture[away_goals]"
              value={f.away_goals}
              class="input input-bordered input-sm font-score ml-1 w-16"
            />
          </label>
          <label class="text-xs text-base-content/60">
            Status
            <select name="fixture[status]" class="select select-bordered select-sm ml-1">
              <option value="scheduled" selected={f.status == :scheduled}>scheduled</option>
              <option value="completed" selected={f.status == :completed}>completed</option>
            </select>
          </label>
          <button type="submit" class="btn btn-sm btn-primary">Save result</button>
        </form>

        <form
          id={"fixture-#{f.id}-cohort"}
          phx-submit="save_cohort"
          class="flex flex-wrap items-end gap-2 border-t border-base-200 pt-3"
        >
          <input type="hidden" name="fixture_id" value={f.id} />
          <label class="text-xs text-base-content/60">
            Home%<input
              type="number"
              min="0"
              max="100"
              name="fixture[cohort_home_pct]"
              value={f.cohort_home_pct}
              class="input input-bordered input-sm font-score ml-1 w-16"
            />
          </label>
          <label class="text-xs text-base-content/60">
            Draw%<input
              type="number"
              min="0"
              max="100"
              name="fixture[cohort_draw_pct]"
              value={f.cohort_draw_pct}
              class="input input-bordered input-sm font-score ml-1 w-16"
            />
          </label>
          <label class="text-xs text-base-content/60">
            Away%<input
              type="number"
              min="0"
              max="100"
              name="fixture[cohort_away_pct]"
              value={f.cohort_away_pct}
              class="input input-bordered input-sm font-score ml-1 w-16"
            />
          </label>
          <button type="submit" class="btn btn-sm btn-soft">Save cohort</button>
          <span
            :if={!cohort_set?(f)}
            class="rounded-md bg-warning/15 px-2 py-1 text-[11px] font-semibold text-warning"
          >
            cohort not set — risky bonus off
          </span>
        </form>
      </div>
    </Layouts.app>
    """
  end
end
