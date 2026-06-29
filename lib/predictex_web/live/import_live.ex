defmodule PredictexWeb.ImportLive do
  @moduledoc """
  Member self-import of FIFA group-stage picks, platform-aware.

  Desktop: a relabelled bookmarklet hands a base64 payload (all rounds) via the URL fragment;
  one preview, one confirm, all rounds written together.

  Mobile: no install. The member opens FIFA's prediction page per round, copies what they see,
  and pastes it here. Each round is previewed and **written on its own** so progress survives a
  mobile tab discard (the flow navigates away to FIFA and back per round). FIFA's raw response
  carries no round number, so `Fifa.Import.rows_from_envelope/2` injects the round we are on.

  Dumb view: the pure core (`Fifa.Import.plan/3`) validates and orients; the view renders and,
  on confirm, writes via `Predictions.admin_save_round_predictions/3` for the current member.
  """
  use PredictexWeb, :live_view

  alias Predictex.Fifa.Import
  alias Predictex.{Predictions, Tournament}

  @last_group_round 3

  @impl true
  def mount(_params, session, socket) do
    platform = Map.get(session, "platform", "mobile")

    {:ok,
     assign(socket,
       platform: platform,
       step: if(platform == "mobile", do: :paste, else: :awaiting),
       current_round: 1,
       imported_total: 0,
       matched: [],
       unmatched: [],
       error: nil,
       summary: nil,
       booster_unmatched: false
     )}
  end

  # ---- Mobile: per-round paste of FIFA's raw envelope ------------------------------------

  @impl true
  def handle_event("paste", %{"paste" => %{"json" => raw}}, socket) do
    round = socket.assigns.current_round

    with {:ok, decoded} <- Jason.decode(raw),
         {:ok, rows} <- Import.rows_from_envelope(decoded, round) do
      preview(socket, rows)
    else
      _ ->
        {:noreply,
         assign(socket, error: "We couldn't read that — paste exactly what FIFA showed you.")}
    end
  end

  # ---- Desktop: base64 payload from the bookmarklet fragment ------------------------------

  def handle_event("payload", %{"data" => b64}, socket) do
    case Import.decode_payload(b64) do
      {:ok, rows} ->
        preview(socket, rows)

      {:error, _} ->
        {:noreply, assign(socket, error: "We couldn't read your picks. Please try again.")}
    end
  end

  # ---- Mobile confirm: write THIS round now, then advance ---------------------------------

  def handle_event("confirm_round", _params, socket) do
    case write_matched(socket) do
      %{errors: 0, imported: imported} ->
        advance(socket, socket.assigns.imported_total + imported)

      _ ->
        {:noreply,
         assign(socket,
           error:
             "Some of your Round #{socket.assigns.current_round} picks didn't save — please try again."
         )}
    end
  end

  def handle_event("skip_round", _params, socket) do
    advance(socket, socket.assigns.imported_total)
  end

  # ---- Desktop confirm: write all matched rounds together --------------------------------

  def handle_event("confirm", _params, socket) do
    {:noreply, assign(socket, step: :done, summary: write_matched(socket))}
  end

  # ---- internals -------------------------------------------------------------------------

  defp preview(socket, rows) do
    case reference_fun().() do
      {:ok, rounds} ->
        %{matched: matched, unmatched: unmatched} =
          Import.plan(rows, rounds, Tournament.list_fixtures())

        {:noreply,
         assign(socket,
           step: :preview,
           matched: matched,
           unmatched: unmatched,
           error: nil,
           booster_unmatched: Enum.any?(unmatched, & &1.booster)
         )}

      {:error, _} ->
        {:noreply,
         assign(socket, error: "We couldn't reach FIFA just now. Please try again in a moment.")}
    end
  end

  defp write_matched(socket) do
    player_id = socket.assigns.current_scope.player.id

    socket.assigns.matched
    |> Import.to_write_rows()
    |> Enum.reduce(%{imported: 0, errors: 0}, &save_import_round(player_id, &1, &2))
  end

  # Import is the third producer of pick rows: it crosses the same shared invariant owner
  # (`Predictions.validate_pick_rows/1`) before persisting.
  defp save_import_round(player_id, {round_id, rows}, acc) do
    with {:ok, rows} <- Predictions.validate_pick_rows(rows),
         {:ok, results} <- Predictions.admin_save_round_predictions(player_id, round_id, rows) do
      imported = Enum.count(results, fn {_id, r} -> r == :upserted end)

      %{
        acc
        | imported: acc.imported + imported,
          errors: acc.errors + (Enum.count(results) - imported)
      }
    else
      {:error, _} -> %{acc | errors: acc.errors + length(rows)}
    end
  end

  defp advance(socket, total) do
    if socket.assigns.current_round >= @last_group_round do
      {:noreply,
       assign(socket, step: :done, imported_total: total, summary: %{imported: total, errors: 0})}
    else
      {:noreply,
       assign(socket,
         step: :paste,
         current_round: socket.assigns.current_round + 1,
         matched: [],
         unmatched: [],
         error: nil,
         booster_unmatched: false,
         imported_total: total
       )}
    end
  end

  defp reference_fun,
    do:
      Application.get_env(
        :predictex,
        :fifa_reference_fun,
        &Predictex.Fifa.Reference.fetch_rounds/0
      )

  defp paste_form(assigns) do
    ~H"""
    <form id="paste-form" phx-submit="paste">
      <textarea
        name="paste[json]"
        rows="6"
        class="textarea textarea-bordered w-full"
        placeholder={"Paste your Round #{@round} picks here"}
      ></textarea>
      <button type="submit" class="btn btn-primary mt-2">Check my picks</button>
    </form>
    """
  end

  defp escape_hatch(assigns) do
    ~H"""
    <p class="mt-6 text-sm opacity-70">
      Stuck? Take a screenshot of your FIFA picks and send it to the group admin — they'll add
      them for you.
    </p>
    """
  end

  defp bookmarklet do
    js = """
    (async () => {
      const base = 'https://play.fifa.com/api/en/match-predictor/prediction/show/';
      let rows = [];
      for (let r = 1; r <= 3; r++) {
        try {
          const res = await fetch(base + r, {credentials: 'include'});
          const json = await res.json();
          const preds = (json && json.success && json.success.predictions) || [];
          for (const p of preds) {
            rows.push({round: r, matchId: p.matchId, homeScore: p.homeScore, awayScore: p.awayScore, booster: !!p.booster});
          }
        } catch (e) {}
      }
      const b64 = btoa(JSON.stringify(rows)).replace(/\\+/g, '-').replace(/\\//g, '_').replace(/=+$/, '');
      window.open('#{PredictexWeb.Endpoint.url()}/import#' + b64, '_blank');
    })();
    """

    "javascript:" <> URI.encode(js, &URI.char_unreserved?/1)
  end

  defp reason_text(:unknown_match_id), do: "one match we couldn't recognise"
  defp reason_text(:no_fixture), do: "a match we couldn't line up with our fixtures"
  defp reason_text(:out_of_scope), do: "knockout rounds (not imported yet)"
  defp reason_text(:invalid), do: "a pick with a missing score"
end
