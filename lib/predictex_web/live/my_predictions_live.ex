defmodule PredictexWeb.MyPredictionsLive do
  @moduledoc """
  A member's read-only personal dashboard: their imported FIFA picks, per-fixture scoring,
  and league rank. No prediction entry here — that lives in the admin (predictex-a02) and
  import (predictex-xox) flows.
  """
  use PredictexWeb, :live_view

  alias Predictex.{Dashboard, Predictions, Tournament}
  alias PredictexWeb.Flags

  @impl true
  def mount(_params, _session, socket) do
    now = DateTime.utc_now()
    dash = Dashboard.for_player(socket.assigns.current_scope.player, now)
    active = Enum.find_value(dash.rounds, fn r -> r.active? && r.round.ordinal end)

    if connected?(socket) do
      # Live scores + the settle arrive over PubSub (predictex-9p0); the clock tick now only
      # handles the −30 min preview / kickoff-lock thresholds.
      Tournament.subscribe_changes()
      schedule_next_tick(dash, now)
    end

    {:ok,
     socket
     |> assign(:page_title, "My Predictions")
     |> assign(:dash, dash)
     |> assign(:active_ordinal, active)
     |> assign(:now, now)
     |> assign(:next_match, Dashboard.next_match(dash, now))
     |> assign(:fifa_url, Application.get_env(:predictex, :fifa_predictor_url))}
  end

  @impl true
  def handle_event("select_round", %{"ordinal" => ord}, socket) do
    {:noreply, assign(socket, :active_ordinal, String.to_integer(ord))}
  end

  @impl true
  # Clock-driven: re-pull, then sleep to the next preview/kickoff threshold (nil once past).
  def handle_info(:tick, socket) do
    socket = refresh(socket)
    schedule_next_tick(socket.assigns.dash, socket.assigns.now)
    {:noreply, socket}
  end

  # Event-driven (predictex-9p0): a fixture changed (live score or settle) — re-pull only.
  # No reschedule: the clock tick is a separate, self-perpetuating chain.
  def handle_info(:fixtures_changed, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    now = DateTime.utc_now()
    dash = Dashboard.for_player(socket.assigns.current_scope.player, now)

    socket
    |> assign(:now, now)
    |> assign(:dash, dash)
    |> assign(:next_match, Dashboard.next_match(dash, now))
  end

  defp schedule_next_tick(dash, now) do
    case Dashboard.next_tick_delay(dash, now) do
      nil -> :ok
      ms -> Process.send_after(self(), :tick, ms)
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :active, active_round(assigns.dash, assigns.active_ordinal))

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} max_width="max-w-6xl">
      <div :if={@dash.rounds == []} class="rounded-box bg-base-200 p-6 text-center">
        <p class="font-medium">No schedule yet</p>
        <p class="text-sm opacity-70">Fixtures appear once the tournament is seeded.</p>
      </div>

      <div :if={@dash.rounds != []} class="space-y-4">
        <%!-- next-match countdown — soonest upcoming fixture across all rounds (predictex-vg7) --%>
        <div
          :if={@next_match}
          id="next-match-banner"
          class="flex flex-col items-center gap-1 rounded-box border border-accent/30 bg-accent/10 p-3 text-center"
        >
          <span class="text-[10px] font-extrabold uppercase tracking-wider text-accent">
            Next match
          </span>
          <span class="flex items-center gap-2 text-sm font-bold">
            {@next_match.fixture.team1}
            <span class="text-base">{Flags.flag(@next_match.fixture.team1)}</span>
            <span class="text-base-content/40">v</span>
            <span class="text-base">{Flags.flag(@next_match.fixture.team2)}</span>
            {@next_match.fixture.team2}
          </span>
          <span class="text-xs font-semibold text-base-content/70">
            Kicks off
            <time
              id="next-match-countdown"
              phx-hook=".Countdown"
              data-kickoff={DateTime.to_iso8601(@next_match.fixture.kickoff_at)}
              datetime={DateTime.to_iso8601(@next_match.fixture.kickoff_at)}
              class="font-score font-bold tabular-nums text-base-content"
            >
              …
            </time>
          </span>
        </div>

        <%!-- rank hero — always pitch green, light ink, regardless of theme --%>
        <div class="relative overflow-hidden rounded-box bg-gradient-to-br from-primary to-secondary p-4 text-white shadow-lg">
          <div class="flex items-center justify-between">
            <div>
              <div class="text-[10px] font-bold uppercase tracking-wider opacity-80">Your rank</div>
              <div class="text-3xl font-black leading-none">
                {ordinal(@dash.rank)} <span class="text-sm opacity-80">of {@dash.of}</span>
              </div>
            </div>
            <div class="text-right">
              <div class="text-[10px] font-bold uppercase tracking-wider opacity-80">
                Total points
              </div>
              <div class="font-score text-3xl font-bold">{@dash.total}</div>
              <div class="text-xs opacity-80">
                {@dash.fixtures_total} from fixtures · {@dash.round_bonus_total} bonus
              </div>
            </div>
          </div>
        </div>

        <%!-- round selector chips --%>
        <div class="flex flex-wrap gap-2">
          <button
            :for={r <- @dash.rounds}
            phx-click="select_round"
            phx-value-ordinal={r.round.ordinal}
            class={[
              "rounded-full px-3 py-1 text-xs font-bold transition-colors",
              (r.round.ordinal == @active_ordinal && "bg-primary text-primary-content") ||
                "bg-base-200 text-base-content/70 hover:bg-base-300"
            ]}
          >
            {r.round.name}
          </button>
        </div>

        <div :if={@active} class="flex items-center gap-2">
          <span class="text-sm font-extrabold">{@active.round.name}</span>
          <span
            :if={@active.round.stage == :knockout}
            class="rounded-md bg-info/15 px-2 py-0.5 text-[9px] font-bold uppercase tracking-wide text-info"
          >
            Knockout
          </span>
        </div>

        <div :if={@active} class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
          <.fixture_card
            :for={fx <- @active.fixtures}
            fx={fx}
            stage={@active.round.stage}
            fifa_url={@fifa_url}
            live_cta?={Predictions.cta_window?(fx.fixture, @now)}
            live_path={~p"/fixtures/#{fx.fixture.id}"}
            tz={@tz}
          />
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

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Countdown">
        export default {
          start() {
            clearInterval(this.timer)
            this.tick()
            this.timer = setInterval(() => this.tick(), 1000)
          },
          mounted() { this.start() },
          updated() { this.start() },
          destroyed() { clearInterval(this.timer) },
          tick() {
            const target = new Date(this.el.dataset.kickoff).getTime()
            let s = Math.floor((target - Date.now()) / 1000)
            if (s <= 0) {
              this.el.textContent = "now"
              clearInterval(this.timer)
              return
            }
            const pad = (n) => String(n).padStart(2, "0")
            const d = Math.floor(s / 86400); s -= d * 86400
            const h = Math.floor(s / 3600); s -= h * 3600
            const m = Math.floor(s / 60); const sec = s - m * 60
            this.el.textContent =
              d > 0 ? `in ${d}d ${h}h`
              : h > 0 ? `in ${h}h ${pad(m)}m`
              : `in ${pad(m)}:${pad(sec)}`
          }
        }
      </script>
    </Layouts.app>
    """
  end

  defp active_round(dash, ordinal),
    do: Enum.find(dash.rounds, &(&1.round.ordinal == ordinal))

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
