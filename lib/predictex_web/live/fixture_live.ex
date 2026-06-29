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

  alias Predictex.{
    Tournament,
    Predictions,
    LiveScore.Buzz,
    MatchRecap,
    Capture,
    Replay,
    Scoring.Standings
  }

  alias PredictexWeb.{Flags, Presence}

  # Cross-match aggregate of viewers currently on a *live* fixture, observed by the
  # leaderboard (predictex-x16). FixtureLive joins it only while fixture.is_live.
  @watching_live_topic "watching:live"

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    fixture = Tournament.get_fixture!(id, :round)

    socket =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Predictex.PubSub, "fixture:#{id}")
        track_fixture_presence(socket, fixture)
      else
        socket
      end

    {:ok, socket |> assign_watchers(fixture) |> load_all(fixture)}
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

  # A viewer opened/closed this fixture page — recompute the "who's watching" indicator.
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, assign_watchers(socket, socket.assigns.fixture)}
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
    |> sync_live_presence(fixture)
  end

  # --- Live viewer presence (predictex-x16) ---

  defp fixture_presence_topic(id), do: "fixture_presence:#{id}"

  # Join this fixture's presence topic and announce the viewer (by display name).
  # Only ever called on the connected mount; the entry is dropped automatically on
  # socket process DOWN (no manual untrack).
  defp track_fixture_presence(socket, fixture) do
    viewer = socket.assigns.current_scope.player
    topic = fixture_presence_topic(fixture.id)
    Phoenix.PubSub.subscribe(Predictex.PubSub, topic)

    {:ok, _ref} =
      Presence.track(self(), topic, to_string(viewer.id), %{name: viewer.display_name})

    socket
  end

  # Recompute the watcher list from the tracker. On the dead render (no track) the
  # list is empty, so @watchers is always assigned for the template.
  defp assign_watchers(socket, fixture) do
    watchers =
      fixture.id |> fixture_presence_topic() |> Presence.list() |> Presence.watcher_list()

    assign(socket, :watchers, watchers)
  end

  # Mirror the viewer's presence on the cross-match "watching:live" topic to exactly
  # `fixture.is_live` — gated on the *persisted* fixture, never @view_fixture (replay
  # forces that live on a completed match, which must not count as watching live).
  # load_all runs on mount and on every material transition, so this one path covers
  # kickoff, settle, and replay start/stop.
  defp sync_live_presence(socket, fixture) do
    if connected?(socket) do
      viewer_id = to_string(socket.assigns.viewer_id)
      tracking? = Map.get(socket.assigns, :watching_live?, false)

      cond do
        fixture.is_live and not tracking? ->
          {:ok, _ref} = Presence.track(self(), @watching_live_topic, viewer_id, %{})
          assign(socket, :watching_live?, true)

        not fixture.is_live and tracking? ->
          Presence.untrack(self(), @watching_live_topic, viewer_id)
          assign(socket, :watching_live?, false)

        true ->
          socket
      end
    else
      socket
    end
  end

  # The watcher names for display: the viewer themselves shows as "you".
  defp watchers_label(watchers, viewer_id) do
    vid = to_string(viewer_id)

    Enum.map_join(watchers, ", ", fn w -> if(w.id == vid, do: "you", else: w.name) end)
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
      |> Buzz.pick_projection(fixture.id, pick.home_goals, pick.away_goals, viewer_id, %{
        side: pick.first_scorer_side,
        player: pick.first_scorer_player
      })
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
