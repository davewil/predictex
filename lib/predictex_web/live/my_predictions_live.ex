defmodule PredictexWeb.MyPredictionsLive do
  @moduledoc """
  A member's read-only personal dashboard: their imported FIFA picks, per-fixture scoring,
  and league rank. No prediction entry here — that lives in the admin (predictex-a02) and
  import (predictex-xox) flows.
  """
  use PredictexWeb, :live_view

  alias Predictex.Dashboard

  @impl true
  def mount(_params, _session, socket) do
    dash = Dashboard.for_player(socket.assigns.current_scope.player)
    active = Enum.find_value(dash.rounds, fn r -> r.active? && r.round.ordinal end)

    {:ok,
     socket
     |> assign(:page_title, "My Predictions")
     |> assign(:dash, dash)
     |> assign(:active_ordinal, active)
     |> assign(:fifa_url, Application.get_env(:predictex, :fifa_predictor_url))
     |> assign(:live_buzz?, FunWithFlags.enabled?(:live_buzz))}
  end

  @impl true
  def handle_event("select_round", %{"ordinal" => ord}, socket) do
    {:noreply, assign(socket, :active_ordinal, String.to_integer(ord))}
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
            live_buzz?={@live_buzz?}
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
