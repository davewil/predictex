defmodule PredictexWeb.FixtureLive do
  @moduledoc """
  Real-time buzz drill-down for a single live fixture.

  - Flag off (`live_buzz` disabled): redirects to home immediately.
  - Pre-kickoff: shows fixture info; picks are hidden (anti-copy).
  - Post-kickoff (locked): reveals everyone's picks.
  - Live fixture: shows Buzz scenarios ("if it ends …") and viewer narratives.

  Efficiency: on PubSub `{:live_update, id}` ticks, the full projection (~7 DB
  queries: scenarios + narratives + picks) is recomputed only when something
  material changes — score change, live-state transition, or kickoff lock flip.
  Minute-only updates refresh only the fixture assign (clock advances).
  """
  use PredictexWeb, :live_view

  alias Predictex.{Tournament, Predictions, Buzz}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if FunWithFlags.enabled?(:live_buzz) do
      fixture = Tournament.get_fixture!(id)

      if connected?(socket) do
        Phoenix.PubSub.subscribe(Predictex.PubSub, "fixture:#{id}")
      end

      {:ok, load_all(socket, fixture)}
    else
      {:ok, redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_info({:live_update, _id}, socket) do
    old = socket.assigns.fixture
    new = Tournament.get_fixture!(old.id)
    now = DateTime.utc_now()
    now_locked? = Predictions.locked?(new, now)

    recompute? =
      score_changed?(old, new) or
        old.is_live != new.is_live or
        socket.assigns.picks_visible? != now_locked?

    socket = if recompute?, do: load_all(socket, new), else: assign(socket, :fixture, new)

    {:noreply, socket}
  end

  # Compute all assigns from scratch (mount + any material state change).
  defp load_all(socket, fixture) do
    now = DateTime.utc_now()
    locked? = Predictions.locked?(fixture, now)
    viewer_id = socket.assigns.current_scope.player.id
    h = fixture.live_home_goals || 0
    a = fixture.live_away_goals || 0

    socket
    |> assign(:fixture, fixture)
    |> assign(:picks_visible?, locked?)
    |> assign(:picks, if(locked?, do: Predictions.list_fixture_predictions(fixture.id), else: []))
    |> assign(:scenarios, if(fixture.is_live, do: Buzz.scenarios(fixture.id, h, a), else: []))
    |> assign(
      :narratives,
      if(fixture.is_live, do: Buzz.narratives(fixture.id, h, a, viewer_id), else: [])
    )
  end

  defp score_changed?(old, new) do
    old.live_home_goals != new.live_home_goals or old.live_away_goals != new.live_away_goals
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-2xl p-4 space-y-4">
        <h1 class="text-xl font-bold">{@fixture.team1} v {@fixture.team2}</h1>

        <p :if={@fixture.is_live} class="text-error font-bold">
          LIVE {@fixture.live_minute} · {@fixture.live_home_goals}-{@fixture.live_away_goals}
        </p>

        <section :if={@scenarios != []} class="space-y-2">
          <h2 class="font-semibold">Scenarios</h2>
          <ul class="space-y-1">
            <li :for={s <- @scenarios} class="text-sm">{s.label}</li>
          </ul>
        </section>

        <section :if={@narratives != []} class="space-y-2">
          <h2 class="font-semibold">Your buzz</h2>
          <ul class="space-y-1">
            <li :for={line <- @narratives} class="text-sm">{line}</li>
          </ul>
        </section>

        <section :if={@picks_visible?} class="space-y-2">
          <h2 class="font-semibold">Everyone's picks</h2>
          <ul class="space-y-1">
            <li :for={p <- @picks} class="text-sm">
              {p.player.display_name}: {p.home_goals}-{p.away_goals}
            </li>
          </ul>
        </section>

        <p :if={not @picks_visible?} class="text-base-content/60 text-sm">
          Picks reveal at kickoff.
        </p>
      </div>
    </Layouts.app>
    """
  end
end
