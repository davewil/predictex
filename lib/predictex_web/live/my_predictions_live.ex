defmodule PredictexWeb.MyPredictionsLive do
  @moduledoc """
  A member's personal dashboard: their picks, per-fixture scoring, and league rank.

  Group-stage picks are imported via the FIFA import flow or entered by an admin.
  Native prediction entry is available here for knockout rounds when the :native_ko_entry
  flag is on for this player. Each fixture is gated individually via
  `Predictions.fixture_entry_state/2`: :editable (real teams, pre-kickoff), :locked
  (kicked off), or :pending (placeholder teams — bracket not yet resolved).
  """
  use PredictexWeb, :live_view

  alias Predictex.{Dashboard, Scoring.Knockout, Predictions, Tournament}
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
     |> assign(:next_matches, Dashboard.next_matches(dash, now))
     |> assign(:fifa_url, Application.get_env(:predictex, :fifa_predictor_url))}
  end

  @impl true
  def handle_event("select_round", %{"ordinal" => ord}, socket) do
    {:noreply, assign(socket, :active_ordinal, String.to_integer(ord))}
  end

  @impl true
  def handle_event("save_round", params, socket) do
    active = active_round(socket.assigns.dash, socket.assigns.active_ordinal)

    # Defense-in-depth guard: only proceed if the active round is a knockout round with
    # the native_ko_entry flag on. Forged save_round events targeting group rounds are
    # silently dropped before any round_id or row processing occurs.
    if native_ko_round?(active, socket.assigns.current_scope.player) do
      do_save_round(params, active, socket)
    else
      {:noreply, socket}
    end
  end

  @impl true
  # Save-as-you-go (phx-change): persist whatever is currently complete + valid on every edit, so
  # picks survive a reload without an explicit "save". Incomplete scorelines are skipped and a
  # booster-on-blank is held silently — no flash, no form re-render (the cards are phx-update=ignore
  # and re-pulling the whole dashboard per keystroke would be wasteful; a static "saves
  # automatically" indicator covers reassurance). Same write-auth/lockout guards as the explicit
  # save (save_round_predictions skips locked/pending/incomplete rows individually).
  def handle_event("autosave", params, socket) do
    active = active_round(socket.assigns.dash, socket.assigns.active_ordinal)
    player = socket.assigns.current_scope.player

    if native_ko_round?(active, player) do
      with {:ok, rows} <-
             Predictions.parse_pick_rows(params["picks"] || %{}, params["booster_fixture_id"]) do
        Predictions.save_round_predictions(
          player.id,
          active.round.id,
          rows,
          native_ko_enabled?(player)
        )
      end
    end

    {:noreply, socket}
  end

  defp do_save_round(params, active, socket) do
    player = socket.assigns.current_scope.player
    player_id = player.id
    round_id = active.round.id

    # The prediction-intake boundary (pure) parses params and owns the booster-on-blank
    # invariant; this view just routes the validated rows to persistence and renders the tag.
    case Predictions.parse_pick_rows(params["picks"] || %{}, params["booster_fixture_id"]) do
      {:ok, rows} ->
        # Resolve the flag and pass it as an independent write-path gate (defense in depth):
        # save_round_predictions/4 rejects when the flag is off for this actor, so a crafted
        # save_round event can't bypass a dark flag even if the render guard above is changed.
        case Predictions.save_round_predictions(
               player_id,
               round_id,
               rows,
               native_ko_enabled?(player)
             ) do
          {:ok, _results} ->
            {:noreply, socket |> refresh() |> put_flash(:info, "Saved")}

          {:error, :booster_locked} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Your booster is locked to a match that's already kicked off — it can't be moved this round."
             )}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not save predictions.")}
        end

      {:error, :booster_on_blank} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Can't boost a fixture with no scoreline — enter a score for the boosted fixture or pick \"No booster\". Nothing was saved."
         )}
    end
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
    |> assign(:next_matches, Dashboard.next_matches(dash, now))
  end

  defp schedule_next_tick(dash, now) do
    case Dashboard.next_tick_delay(dash, now) do
      nil -> :ok
      ms -> Process.send_after(self(), :tick, ms)
    end
  end

  embed_templates "my_predictions_live_body.html"

  @impl true
  def render(assigns) do
    active = active_round(assigns.dash, assigns.active_ordinal)
    states = fixture_states(active, assigns.now)
    native_ko = native_ko_round?(active, assigns.current_scope.player)

    assigns =
      assigns
      |> assign(:active, active)
      |> assign(:native_ko_round?, native_ko)
      |> assign(:fixture_states, states)
      |> assign(:squads, if(native_ko, do: squads_for(active, states), else: %{}))

    my_predictions_live_body(assigns)
  end

  defp active_round(dash, ordinal),
    do: Enum.find(dash.rounds, &(&1.round.ordinal == ordinal))

  # A knockout round shows the native entry view when the flag is on for this player. Individual
  # fixtures are then gated per-fixture (Predictions.fixture_entry_state/2) — predictex-80k.
  defp native_ko_round?(%{round: %{stage: :knockout}}, player), do: native_ko_enabled?(player)
  defp native_ko_round?(_, _player), do: false

  defp fixture_states(%{fixtures: fixtures}, now),
    do:
      Map.new(fixtures, fn fx ->
        {fx.fixture.id, Predictions.fixture_entry_state(fx.fixture, now)}
      end)

  defp fixture_states(_active, _now), do: %{}

  # Squads for the first-player picker — only editable KO fixtures need them. Reads the FIFA
  # squads cache (lazy-loads on first miss); a cold cache yields [] and the modal renders empty
  # (the card still saves a blank first-player, exactly as before the picker).
  defp squads_for(%{fixtures: fixtures}, states) do
    for fx <- fixtures, states[fx.fixture.id] == :editable, into: %{} do
      {fx.fixture.id,
       %{
         team1: Predictex.Fifa.Players.Cache.for_team(fx.fixture.team1),
         team2: Predictex.Fifa.Players.Cache.for_team(fx.fixture.team2)
       }}
    end
  end

  defp squads_for(_active, _states), do: %{}

  # Single source for the flag resolution — used by the render gate and the write gate so
  # the two defense-in-depth layers can't drift. The :admins group resolves off is_admin
  # (see the FunWithFlags.Group impl for Player).
  defp native_ko_enabled?(player), do: FunWithFlags.enabled?(:native_ko_entry, for: player)

  # --- native KO entry: toggle-button state (the JS hook drives these from the rendered values) ---

  # The single round-wide booster target: the id of the fixture currently boosted, or "" for none.
  defp current_booster_id(fixtures) do
    case Enum.find(fixtures, & &1.booster?) do
      nil -> ""
      fx -> fx.fixture.id
    end
  end

  defp scorer_value(%{prediction: %{first_scorer_side: :home}}), do: "home"
  defp scorer_value(%{prediction: %{first_scorer_side: :away}}), do: "away"
  defp scorer_value(_fx), do: ""

  defp scorer_pressed?(fx, side), do: scorer_value(fx) == Atom.to_string(side)

  # min-h-11 = 44px, the recommended minimum touch target.
  defp toggle_btn_class(true), do: "btn btn-sm min-h-11 btn-primary"
  defp toggle_btn_class(false), do: "btn btn-sm min-h-11 btn-ghost border border-base-content/20"

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
