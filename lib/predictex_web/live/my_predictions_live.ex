defmodule PredictexWeb.MyPredictionsLive do
  @moduledoc """
  A member's read-only personal dashboard: their imported FIFA picks, per-fixture scoring,
  and league rank. No prediction entry here — that lives in the admin (predictex-a02) and
  import (predictex-xox) flows.
  """
  use PredictexWeb, :live_view

  alias Predictex.Dashboard
  alias PredictexWeb.Flags

  @impl true
  def mount(_params, _session, socket) do
    dash = Dashboard.for_player(socket.assigns.current_scope.player)
    active = Enum.find_value(dash.rounds, fn r -> r.active? && r.round.ordinal end)

    {:ok,
     socket
     |> assign(:page_title, "My Predictions")
     |> assign(:dash, dash)
     |> assign(:active_ordinal, active)
     |> assign(:fifa_url, Application.get_env(:predictex, :fifa_predictor_url))}
  end

  @impl true
  def handle_event("select_round", %{"ordinal" => ord}, socket) do
    {:noreply, assign(socket, :active_ordinal, String.to_integer(ord))}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :active, active_round(assigns.dash, assigns.active_ordinal))

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div :if={@dash.rounds == []} class="rounded-box bg-base-200 p-6 text-center">
        <p class="font-medium">No schedule yet</p>
        <p class="text-sm opacity-70">Fixtures appear once the tournament is seeded.</p>
      </div>

      <div :if={@dash.rounds != []} class="space-y-4">
        <div
          class="rounded-2xl p-4 text-white shadow-lg"
          style="background:linear-gradient(135deg,#0a7d3c,#0f9d4f)"
        >
          <div class="flex items-center justify-between">
            <div>
              <div class="text-xs uppercase tracking-wide opacity-80">Your rank</div>
              <div class="text-3xl font-black leading-none">
                {ordinal(@dash.rank)} <span class="text-sm opacity-80">of {@dash.of}</span>
              </div>
            </div>
            <div class="text-right">
              <div class="text-xs uppercase tracking-wide opacity-80">Total points</div>
              <div class="text-3xl font-black">{@dash.total}</div>
              <div class="text-xs opacity-80">
                {@dash.fixtures_total} fixtures · {@dash.round_bonus_total} bonus
              </div>
            </div>
          </div>

          <div class="mt-3 flex flex-wrap gap-2">
            <button
              :for={r <- @dash.rounds}
              phx-click="select_round"
              phx-value-ordinal={r.round.ordinal}
              class={[
                "rounded-full px-3 py-1 text-xs font-bold",
                (r.round.ordinal == @active_ordinal && "bg-white text-[#0a7d3c]") ||
                  "bg-white/20 text-white"
              ]}
            >
              {r.round.name}
            </button>
          </div>
        </div>

        <div :if={@active} class="space-y-3">
          <div
            :for={fx <- @active.fixtures}
            class={[
              "rounded-xl bg-base-100 p-3 shadow",
              fx.prediction == nil && "border border-dashed border-error/40"
            ]}
          >
            <div class="flex items-center justify-between text-[11px] uppercase tracking-wide opacity-60">
              <span>{kickoff(fx.fixture.kickoff_at)}</span>
              <span>{status_label(fx)}</span>
            </div>

            <div class="mt-1 flex items-center justify-center gap-2 font-semibold">
              <span>{Flags.flag(fx.fixture.team1)} {fx.fixture.team1}</span>
              <span class="rounded-lg bg-base-200 px-3 py-1 text-lg font-black">{scoreline(
                fx.prediction
              )}</span>
              <span>{fx.fixture.team2} {Flags.flag(fx.fixture.team2)}</span>
            </div>

            <div
              :if={@active.round.stage == :knockout and fx.prediction}
              class="mt-1 text-center text-xs opacity-70"
            >
              First team: {side_label(fx.prediction.first_scorer_side, fx.fixture)} ·
              First scorer: {fx.prediction.first_scorer_player || "—"}
            </div>

            <div class="mt-2 text-center text-xs">
              <span :if={fx.prediction == nil} class="font-semibold text-error">⚠ No pick imported yet</span>
              <span :if={fx.prediction && fx.status == :completed}>
                Actual <strong>{fx.fixture.home_goals}–{fx.fixture.away_goals}</strong>
                <span :if={fx.exact?} class="font-bold text-success">· exact ✓✓</span>
                <span class="ml-1 rounded-full bg-warning px-2 py-0.5 font-bold text-warning-content">+{fx.points}</span>
                <span :if={fx.booster?} class="ml-1 font-bold text-amber-600">⚡ boosted</span>
              </span>
              <span
                :if={fx.prediction && fx.status != :completed && fx.locked?}
                class="italic opacity-60"
              >
                Locked — awaiting result {if fx.booster?, do: "· ⚡ boosted", else: ""}
              </span>
              <span
                :if={fx.prediction && fx.status != :completed && not fx.locked?}
                class="opacity-60"
              >
                Open {if fx.booster?, do: "· ⚡ boosted", else: ""}
              </span>
            </div>
          </div>
        </div>

        <div :if={@fifa_url} class="text-center">
          <a
            href={@fifa_url}
            target="_blank"
            rel="noopener"
            class="btn btn-neutral btn-sm rounded-full"
          >
            🌐 Make / update picks on FIFA →
          </a>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp active_round(dash, ordinal),
    do: Enum.find(dash.rounds, &(&1.round.ordinal == ordinal))

  defp scoreline(nil), do: "– – –"
  defp scoreline(p), do: "#{p.home_goals} – #{p.away_goals}"

  defp status_label(%{status: :completed}), do: "Full time"
  defp status_label(%{locked?: true}), do: "🔒 Locked"
  defp status_label(_), do: "Open"

  defp side_label(:home, fixture), do: fixture.team1
  defp side_label(:away, fixture), do: fixture.team2
  defp side_label(_, _), do: "—"

  defp kickoff(nil), do: "TBC"
  defp kickoff(%DateTime{} = dt), do: Calendar.strftime(dt, "%a %d %b · %H:%M")

  defp ordinal(nil), do: "—"
  defp ordinal(n) when n in [11, 12, 13], do: "#{n}th"

  defp ordinal(n) do
    case rem(n, 10) do
      1 -> "#{n}st"
      2 -> "#{n}nd"
      3 -> "#{n}rd"
      _ -> "#{n}th"
    end
  end
end
