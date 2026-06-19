defmodule PredictexWeb.FixtureLive do
  @moduledoc """
  Real-time buzz drill-down for a single live fixture.

  - Pre-kickoff: shows fixture info; picks are hidden (anti-copy).
  - Post-kickoff (locked): reveals everyone's picks.
  - Live fixture: shows the "what-if" projected standings (with rank movement)
    and shareable buzz headlines.

  Efficiency: on PubSub `{:live_update, id}` ticks, the full projection (~7 DB
  queries: scenarios + headlines + picks) is recomputed only when something
  material changes — score change, live-state transition, or kickoff lock flip.
  Minute-only updates refresh only the fixture assign (clock advances).
  """
  use PredictexWeb, :live_view

  alias Predictex.{Tournament, Predictions, Buzz, MatchRecap, Capture}
  alias PredictexWeb.Flags

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    fixture = Tournament.get_fixture!(id, :round)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Predictex.PubSub, "fixture:#{id}")
    end

    {:ok, load_all(socket, fixture)}
  end

  @impl true
  def handle_info({:live_update, _id}, socket) do
    old = socket.assigns.fixture
    new = Tournament.get_fixture!(old.id, :round)
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
    recap? = fixture.status == :completed and fixture.round.stage == :group
    picks = if(locked?, do: Predictions.list_fixture_predictions(fixture.id), else: [])

    socket
    |> assign(:fixture, fixture)
    |> assign(:viewer_id, viewer_id)
    |> assign(:picks_visible?, locked?)
    |> assign(:picks, picks)
    |> assign(:recap?, recap?)
    |> assign(:points, if(recap?, do: MatchRecap.points(fixture, picks), else: %{}))
    |> assign(:goals, if(recap?, do: recap_goals(fixture), else: []))
    |> assign(
      :scenarios,
      if(fixture.is_live, do: Buzz.scenarios_with_deltas(fixture.id, h, a), else: [])
    )
    |> assign(
      :headlines,
      if(fixture.is_live, do: Buzz.headlines(fixture.id, h, a, viewer_id), else: [])
    )
  end

  defp recap_goals(fixture) do
    body =
      if fixture.fifa_match_id do
        fixture.fifa_match_id
        |> Capture.list_snapshots()
        |> Enum.filter(&(&1.endpoint == "detail" and is_map(&1.body)))
        |> List.last()
        |> case do
          nil -> nil
          snap -> snap.body
        end
      end

    MatchRecap.goals(fixture, body)
  end

  defp goal_label(:penalty), do: " (pen)"
  defp goal_label(:own_goal), do: " (OG)"
  defp goal_label(:regular), do: ""

  defp score_changed?(old, new) do
    old.live_home_goals != new.live_home_goals or old.live_away_goals != new.live_away_goals
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-2xl space-y-5 p-4">
        <.link
          navigate={~p"/"}
          class="inline-flex items-center gap-1 text-xs font-semibold text-base-content/60 hover:text-base-content"
        >
          ← Leaderboard
        </.link>

        <%!-- Match header: teams, flags, big live score, LIVE pulse --%>
        <div class="space-y-3 rounded-box bg-base-100 p-5 text-center shadow">
          <div class="flex items-center justify-center gap-3 text-base font-bold sm:text-lg">
            <span class="flex-1 truncate text-right" title={@fixture.team1}>
              {@fixture.team1} <span class="text-xl">{Flags.flag(@fixture.team1)}</span>
            </span>

            <span
              :if={@fixture.is_live or @recap?}
              class="font-score text-4xl font-extrabold tabular-nums sm:text-5xl"
            >
              {if @fixture.is_live, do: @fixture.live_home_goals, else: @fixture.home_goals}<span class="px-1 text-base-content/30">–</span>{if @fixture.is_live,
                do: @fixture.live_away_goals,
                else: @fixture.away_goals}
            </span>
            <span :if={not @fixture.is_live and not @recap?} class="px-2 text-base-content/40">v</span>

            <span class="flex-1 truncate text-left" title={@fixture.team2}>
              <span class="text-xl">{Flags.flag(@fixture.team2)}</span> {@fixture.team2}
            </span>
          </div>

          <span
            :if={@fixture.is_live}
            class="inline-flex items-center gap-1.5 rounded-selector bg-error/15 px-3 py-1 text-xs font-extrabold uppercase tracking-wider text-error animate-pdx-glow"
          >
            <span class="size-1.5 rounded-full bg-error"></span>
            LIVE{if @fixture.live_minute, do: " #{@fixture.live_minute}"}
          </span>
          <p
            :if={not @fixture.is_live}
            class="text-xs font-semibold uppercase tracking-wider text-base-content/50"
          >
            <.local_time at={@fixture.kickoff_at} id={"kickoff-#{@fixture.id}"} tz={@tz} />
          </p>
        </div>

        <%!-- The buzz: shareable movement headlines --%>
        <section :if={@headlines != []} class="space-y-2">
          <h2 class="px-1 text-sm font-extrabold uppercase tracking-wider text-accent">⚡ The buzz</h2>
          <ul class="space-y-2">
            <li
              :for={line <- @headlines}
              class="rounded-box border border-accent/30 bg-accent/10 px-4 py-2.5 text-sm font-semibold animate-pdx-rise"
            >
              {line}
            </li>
          </ul>
        </section>

        <%!-- What-if projected standings, with rank movement vs current --%>
        <section :if={@scenarios != []} class="space-y-3">
          <h2 class="px-1 text-sm font-extrabold uppercase tracking-wider text-base-content/60">
            What if…
          </h2>
          <div :for={s <- @scenarios} class="space-y-2 rounded-box bg-base-100 p-4 shadow">
            <h3 class="text-sm font-bold capitalize text-base-content/90">{s.label}</h3>
            <ul class="space-y-1">
              <li
                :for={row <- Enum.take(s.rows, 8)}
                class={[
                  "flex items-center gap-2.5 rounded-field px-2.5 py-1.5",
                  row.player_id == @viewer_id && "bg-primary/10"
                ]}
              >
                <span class="w-5 shrink-0 text-center font-score text-xs text-base-content/50">
                  {row.rank}
                </span>
                <span class="w-8 shrink-0 text-center text-xs font-bold">{movement(row.delta)}</span>
                <span class={[
                  "min-w-0 flex-1 truncate text-sm",
                  (row.player_id == @viewer_id && "font-bold text-primary") || "text-base-content/90"
                ]}>
                  {row.name}<span :if={row.player_id == @viewer_id} class="text-primary/70"> (you)</span>
                </span>
                <span class="shrink-0 font-score text-sm font-bold tabular-nums">{row.total}</span>
              </li>
            </ul>
          </div>
        </section>

        <%!-- Everyone's picks — only after kickoff (anti-copy) --%>
        <section :if={@picks_visible?} class="space-y-2">
          <h2 class="px-1 text-sm font-extrabold uppercase tracking-wider text-base-content/60">
            Everyone's picks
          </h2>
          <div
            :if={@picks == []}
            class="rounded-box bg-base-100 p-4 text-sm text-base-content/50 shadow"
          >
            No predictions on this fixture.
          </div>
          <div :if={@picks != []} class="divide-y divide-base-200 rounded-box bg-base-100 px-3 shadow">
            <div
              :for={p <- @picks}
              class={[
                "flex items-center justify-between py-2.5",
                p.player_id == @viewer_id && "font-bold text-primary"
              ]}
            >
              <span class="truncate text-sm">{p.player.display_name}</span>
              <span class="flex items-center gap-1.5 font-score text-sm font-bold tabular-nums">
                {p.home_goals}–{p.away_goals}
                <span
                  :if={p.booster}
                  class="rounded bg-accent px-1 py-0.5 text-[9px] text-accent-content"
                >
                  ⚡2×
                </span>
                <span
                  :if={@recap?}
                  class="rounded bg-success/15 px-1.5 py-0.5 text-[10px] font-bold text-success"
                >
                  +{Map.get(@points, p.player_id, 0)}
                </span>
              </span>
            </div>
          </div>
        </section>

        <section :if={@recap?} class="space-y-2">
          <h2 class="px-1 text-sm font-extrabold uppercase tracking-wider text-base-content/60">
            Goals
          </h2>
          <div
            :if={@goals == []}
            class="rounded-box bg-base-100 p-4 text-sm text-base-content/50 shadow"
          >
            No goals.
          </div>
          <ul :if={@goals != []} class="divide-y divide-base-200 rounded-box bg-base-100 px-3 shadow">
            <li :for={g <- @goals} class="flex items-center justify-between py-2 text-sm">
              <span class="truncate">
                <span class="font-score text-base-content/50">{g.minute}'</span>
                {g.player}{goal_label(g.type)}
              </span>
              <span class="text-xs text-base-content/50">
                {(g.side == :home && @fixture.team1) || @fixture.team2}
              </span>
            </li>
          </ul>
        </section>

        <div
          :if={not @picks_visible?}
          class="rounded-box border border-dashed border-base-300 bg-base-100/50 p-4 text-center text-sm text-base-content/60"
        >
          🔒 Everyone's picks reveal at kickoff.
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Rank-movement indicator vs the current standings.
  defp movement(delta) when is_integer(delta) and delta > 0,
    do: Phoenix.HTML.raw(~s(<span class="text-success">▲#{delta}</span>))

  defp movement(delta) when is_integer(delta) and delta < 0,
    do: Phoenix.HTML.raw(~s(<span class="text-error">▼#{abs(delta)}</span>))

  defp movement(_), do: Phoenix.HTML.raw(~s(<span class="text-base-content/25">–</span>))
end
