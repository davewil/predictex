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

  alias Predictex.{Tournament, Predictions, Buzz, MatchRecap, Capture, Replay, Standings}
  alias PredictexWeb.Flags

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    fixture = Tournament.get_fixture!(id, :round)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Predictex.PubSub, "fixture:#{id}")
    end

    {:ok, load_all(socket, fixture)}
  end

  # A replay owns the view; a stray live-update (a producer never writes a completed
  # fixture, but be defensive) must not disturb the playback.
  @impl true
  def handle_info({:live_update, _id}, %{assigns: %{replay: replay}} = socket)
      when not is_nil(replay) do
    {:noreply, socket}
  end

  def handle_info({:live_update, _id}, socket) do
    old = socket.assigns.fixture
    new = Tournament.get_fixture!(old.id, :round)
    now = DateTime.utc_now()
    now_locked? = Predictions.locked?(new, now)

    recompute? =
      score_changed?(old, new) or
        old.is_live != new.is_live or
        socket.assigns.picks_visible? != now_locked?

    socket =
      if recompute? do
        load_all(socket, new)
      else
        # Minute-only branch: keep @view_fixture in step with @fixture (normal mode
        # they are the same struct, and the header reads the clock from @view_fixture).
        socket |> assign(:fixture, new) |> assign(:view_fixture, new)
      end

    {:noreply, socket}
  end

  # Replay tick: advance to the next frame (no-op if replay was stopped meanwhile).
  def handle_info(:replay_tick, socket) do
    {:noreply, advance(socket)}
  end

  @impl true
  def handle_event("start_replay", _params, socket) do
    frames = Replay.Cache.frames(socket.assigns.fixture.fifa_match_id)

    replay = %{
      frames: frames,
      index: 0,
      h: nil,
      a: nil,
      timer: nil
    }

    {:noreply, advance(assign(socket, :replay, replay))}
  end

  def handle_event("stop_replay", _params, socket) do
    {:noreply, stop_replay(socket)}
  end

  def handle_event("restart_replay", _params, socket) do
    socket = stop_replay(socket)
    frames = Replay.Cache.frames(socket.assigns.fixture.fifa_match_id)

    replay = %{
      frames: frames,
      index: 0,
      h: nil,
      a: nil,
      timer: nil
    }

    {:noreply, advance(assign(socket, :replay, replay))}
  end

  # Apply the frame at the cursor, then schedule the next tick — except at the terminal
  # frame, where we stop scheduling but stay displayed (timer: nil, @replay non-nil).
  # No-op for a stray tick after Stop.
  defp advance(%{assigns: %{replay: nil}} = socket), do: socket

  defp advance(%{assigns: %{replay: replay}} = socket) do
    frame = Enum.at(replay.frames, replay.index)
    # Decide the dwell before applying the frame, while replay.h/a still hold the prior score.
    scored? = score_changed_from_last?(replay, frame)
    socket = apply_frame(socket, frame)
    last_index = length(replay.frames) - 1

    if replay.index >= last_index do
      # Terminal frame: stay displayed, stop scheduling.
      update(socket, :replay, fn r -> %{r | timer: nil} end)
    else
      timer = Process.send_after(self(), :replay_tick, Replay.tick_delay_ms(scored?))
      update(socket, :replay, fn r -> %{r | index: r.index + 1, timer: timer} end)
    end
  end

  # Build the in-memory live shadow, force the recap off (Gap A), and recompute the
  # buzz only when the score changed (Gap B#1). Never persists @view_fixture.
  defp apply_frame(socket, frame) do
    fixture = socket.assigns.fixture
    replay = socket.assigns.replay
    viewer_id = socket.assigns.viewer_id

    view_fixture =
      struct(fixture, %{
        is_live: true,
        live_home_goals: frame.live_home_goals,
        live_away_goals: frame.live_away_goals,
        live_minute: frame.live_minute
      })

    socket =
      socket
      |> assign(:view_fixture, view_fixture)
      # Gap A: the fixture is :completed, so recap is gated on status; force it off so
      # the final score / Goals / per-pick +points don't spoil the replay.
      |> assign(:recap?, false)
      |> assign(:goals, [])
      |> assign(:points, %{})

    if score_changed_from_last?(replay, frame) do
      h = frame.live_home_goals
      a = frame.live_away_goals
      snapshot = Standings.snapshot()

      socket
      |> assign(:scenarios, Buzz.scenarios_with_deltas(snapshot, fixture.id, h, a))
      |> assign(:headlines, Buzz.headlines(snapshot, fixture.id, h, a, viewer_id))
      |> assign(:replay, %{replay | h: h, a: a})
    else
      # Minute-only frame (Gap B#1): no re-rank, just the refreshed shadow.
      socket
    end
  end

  defp score_changed_from_last?(replay, frame) do
    replay.h != frame.live_home_goals or replay.a != frame.live_away_goals
  end

  # Cancel any pending tick and restore the real (recap/static) view.
  defp stop_replay(socket) do
    if replay = socket.assigns.replay do
      if replay.timer, do: Process.cancel_timer(replay.timer)
    end

    load_all(socket, socket.assigns.fixture)
  end

  # Compute all assigns from scratch (mount + any material state change).
  defp load_all(socket, fixture) do
    now = DateTime.utc_now()
    locked? = Predictions.locked?(fixture, now)
    viewer_id = socket.assigns.current_scope.player.id
    h = fixture.live_home_goals || 0
    a = fixture.live_away_goals || 0
    recap? = fixture.status == :completed and fixture.round.stage == :group
    knockout? = fixture.round.stage != :group
    picks = if(locked?, do: Predictions.list_fixture_predictions(fixture.id), else: [])

    # One ranking snapshot per event, shared by every projection (pick projection + scenarios +
    # headlines). Loaded only when a projection could be shown — a settled fixture needs none.
    snapshot = ranking_snapshot(fixture)

    socket
    |> assign(:fixture, fixture)
    |> assign(:view_fixture, fixture)
    |> assign(:replay, nil)
    |> assign(:replay_available?, replay_available?(fixture))
    |> assign(:viewer_id, viewer_id)
    |> assign(:pick_projection, pick_projection(snapshot, fixture, viewer_id))
    |> assign(:picks_visible?, locked?)
    |> assign(:picks, picks)
    |> assign(:recap?, recap?)
    |> assign(:knockout?, knockout?)
    |> assign(:points, if(recap?, do: MatchRecap.points(fixture, picks), else: %{}))
    |> assign(:goals, if(recap?, do: recap_goals(fixture), else: []))
    |> put_live_buzz(snapshot, fixture, h, a, viewer_id)
  end

  # A ranking snapshot is needed only when a projection could be shown: a live fixture, or an
  # open (not-yet-settled) fixture the viewer may have a pick on. A settled fixture needs none.
  defp ranking_snapshot(%{is_live: true}), do: Standings.snapshot()
  defp ranking_snapshot(%{status: :completed}), do: nil
  defp ranking_snapshot(_fixture), do: Standings.snapshot()

  # Live-only buzz assigns, over the shared snapshot; empty for a non-live fixture.
  defp put_live_buzz(socket, snapshot, %{is_live: true} = fixture, h, a, viewer_id) do
    socket
    |> assign(:scenarios, Buzz.scenarios_with_deltas(snapshot, fixture.id, h, a))
    |> assign(:headlines, Buzz.headlines(snapshot, fixture.id, h, a, viewer_id))
  end

  defp put_live_buzz(socket, _snapshot, _fixture, _h, _a, _viewer_id) do
    socket |> assign(:scenarios, []) |> assign(:headlines, [])
  end

  # Replay is offered only for a completed fixture with a captured timeline, and only
  # when the flag is on. The `and` chain short-circuits, so the cache is touched ONLY
  # when the flag is enabled — keeping unrelated tests off the (test-gated-out) cache path.
  defp replay_available?(fixture) do
    FunWithFlags.enabled?(:match_replay) and fixture.status == :completed and
      not is_nil(fixture.fifa_match_id) and Replay.Cache.frames(fixture.fifa_match_id) != []
  end

  # "If your pick lands" (kcx): project the leaderboard on the viewer's OWN scoreline pick,
  # shown pre-kickoff and during play but never once the fixture is settled (so it cannot
  # collide with replay, which only runs on completed fixtures). The getter fetches only the
  # viewer's own pick — the anti-copy input boundary; the render withholds the per-player board
  # until kickoff (the output boundary).
  defp pick_projection(snapshot, fixture, viewer_id) do
    with true <- fixture.status != :completed,
         pick when not is_nil(pick) <-
           Predictions.get_player_fixture_prediction(viewer_id, fixture.id) do
      snapshot
      |> Buzz.pick_projection(fixture.id, pick.home_goals, pick.away_goals, viewer_id)
      |> Map.merge(%{home: pick.home_goals, away: pick.away_goals})
    else
      _ -> nil
    end
  end

  defp recap_goals(fixture) do
    body = fixture.fifa_match_id && Capture.latest_detail_body(fixture.fifa_match_id)
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
              :if={@view_fixture.is_live or @recap?}
              class="font-score text-4xl font-extrabold tabular-nums sm:text-5xl"
            >
              {if @view_fixture.is_live,
                do: @view_fixture.live_home_goals,
                else: @view_fixture.home_goals}<span class="px-1 text-base-content/30">–</span>{if @view_fixture.is_live,
                do: @view_fixture.live_away_goals,
                else: @view_fixture.away_goals}
            </span>
            <span
              :if={not @view_fixture.is_live and not @recap?}
              class="px-2 text-base-content/40"
            >
              v
            </span>

            <span class="flex-1 truncate text-left" title={@fixture.team2}>
              <span class="text-xl">{Flags.flag(@fixture.team2)}</span> {@fixture.team2}
            </span>
          </div>

          <span
            :if={@view_fixture.is_live}
            class="inline-flex items-center gap-1.5 rounded-selector bg-error/15 px-3 py-1 text-xs font-extrabold uppercase tracking-wider text-error animate-pdx-glow"
          >
            <span class="size-1.5 rounded-full bg-error"></span>
            LIVE{if @view_fixture.live_minute, do: " #{@view_fixture.live_minute}"}
          </span>
          <p
            :if={not @view_fixture.is_live}
            class="text-xs font-semibold uppercase tracking-wider text-base-content/50"
          >
            <.local_time at={@fixture.kickoff_at} id={"kickoff-#{@fixture.id}"} tz={@tz} />
          </p>

          <%!-- Replay controls (predictex-i1s) — read-only in-process playback --%>
          <div :if={@replay_available?} class="pt-1">
            <button
              :if={@replay == nil}
              type="button"
              phx-click="start_replay"
              class="btn btn-sm btn-outline btn-accent"
            >
              ▶ Replay this match
            </button>
            <div :if={@replay != nil} class="flex items-center justify-center gap-2">
              <button type="button" phx-click="restart_replay" class="btn btn-sm btn-ghost">
                ↻ Restart
              </button>
              <button type="button" phx-click="stop_replay" class="btn btn-sm btn-outline btn-error">
                ■ Stop
              </button>
            </div>
          </div>
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

        <%!-- "If your pick lands" — projects the board on the viewer's own pick (kcx).
             Pre-kickoff: headline only (your rank is an aggregate → no per-player leak).
             After kickoff: the full board (picks are public by then). --%>
        <section :if={@pick_projection} id="pick-projection" class="space-y-3">
          <h2 class="px-1 text-sm font-extrabold uppercase tracking-wider text-primary">
            If your pick lands
          </h2>
          <div class="space-y-2 rounded-box bg-base-100 p-4 shadow">
            <p class="text-sm font-bold text-base-content/90">
              <span class="text-lg">{Flags.flag(@fixture.team1)}</span>
              {@fixture.team1}
              <span class="font-score tabular-nums">
                {@pick_projection.home}–{@pick_projection.away}
              </span>
              <span :if={@pick_projection.viewer} class="text-primary">
                → you'd be #{@pick_projection.viewer.rank} {movement(@pick_projection.viewer.delta)}
              </span>
            </p>

            <ul :if={@picks_visible?} class="space-y-1">
              <li
                :for={row <- Enum.take(@pick_projection.rows, 8)}
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

            <p :if={@knockout?} class="text-xs italic text-base-content/50">
              Scoreline only — excludes the first-scorer bonus.
            </p>
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
                "py-2.5",
                p.player_id == @viewer_id && "font-bold text-primary"
              ]}
            >
              <div class="flex items-center justify-between">
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
              <div :if={@knockout?} class="mt-0.5 text-xs font-normal text-base-content/60">
                First to score: {first_team(p.first_scorer_side, @fixture)} · {p.first_scorer_player ||
                  "—"}
              </div>
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

  # First-team-to-score pick → team name. Explicit clauses: first_scorer_side is
  # independently nullable, so a `(side == :home && team1) || team2` idiom would
  # wrongly render team2 for a blank pick.
  defp first_team(:home, fixture), do: fixture.team1
  defp first_team(:away, fixture), do: fixture.team2
  defp first_team(nil, _fixture), do: "—"
end
