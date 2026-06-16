defmodule PredictexWeb.ImportLive do
  @moduledoc """
  Member self-import of FIFA group-stage picks. A thin bookmarklet (added later) hands a base64
  payload via the URL fragment; this LiveView also accepts a pasted JSON array as a fallback.
  Both feed the pure `Fifa.Import.plan/3`. Dumb view: the pure core validates; the view renders
  and, on confirm, writes via `Predictions.admin_save_round_predictions/3` for the current member.
  """
  use PredictexWeb, :live_view

  alias Predictex.Fifa.Import
  alias Predictex.{Predictions, Tournament}

  @import_url "https://wc-predict.davewil.dev/import"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       step: :awaiting,
       matched: [],
       unmatched: [],
       error: nil,
       summary: nil,
       booster_unmatched: false
     )}
  end

  @impl true
  def handle_event("paste", %{"paste" => %{"json" => raw}}, socket) do
    case Jason.decode(raw) do
      {:ok, rows} when is_list(rows) ->
        preview(socket, rows)

      _ ->
        {:noreply,
         assign(socket,
           error: "We could not read that — paste the JSON the bookmarklet produced."
         )}
    end
  end

  def handle_event("payload", %{"data" => b64}, socket) do
    case Import.decode_payload(b64) do
      {:ok, rows} ->
        preview(socket, rows)

      {:error, _} ->
        {:noreply,
         assign(socket, error: "We could not read the import payload. Try the paste box below.")}
    end
  end

  def handle_event("confirm", _params, socket) do
    player_id = socket.assigns.current_scope.player.id

    summary =
      socket.assigns.matched
      |> Import.to_write_rows()
      |> Enum.reduce(%{imported: 0, errors: 0}, fn {round_id, rows}, acc ->
        case Predictions.admin_save_round_predictions(player_id, round_id, rows) do
          {:ok, results} ->
            imported = Enum.count(results, fn {_id, r} -> r == :upserted end)
            %{acc | imported: acc.imported + imported}

          {:error, _} ->
            %{acc | errors: acc.errors + 1}
        end
      end)

    {:noreply, assign(socket, step: :done, summary: summary)}
  end

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
         assign(socket,
           error: "Couldn't reach FIFA reference data. Try again, or use the paste box."
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-2xl">
        <h1 class="text-2xl font-bold mb-4">Import your FIFA picks</h1>

        <p :if={@error} class="alert alert-error mb-4">{@error}</p>

        <div :if={@step == :awaiting} id="import-root" phx-hook=".FifaFragment">
          <ol class="list-decimal ml-5 mb-4 space-y-1">
            <li>Log in to predictex (you already are) and to the FIFA Match Predictor.</li>
            <li>
              Drag this button to your bookmarks bar:
              <a href={bookmarklet()} class="btn btn-sm">Import FIFA picks</a>
            </li>
            <li>
              Open the FIFA Match Predictor, then click the bookmark. It opens this page with your picks ready to preview.
            </li>
          </ol>
          <p class="mb-2 text-sm opacity-70">
            If the bookmarklet is blocked, run it in the browser console and paste the JSON it prints here:
          </p>
          <.paste_form />
        </div>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".FifaFragment">
          export default {
            mounted() {
              const hash = window.location.hash.slice(1)
              if (hash) {
                this.pushEvent("payload", {data: hash})
                history.replaceState(null, "", window.location.pathname)
              }
            }
          }
        </script>

        <div :if={@step == :preview}>
          <p :if={assigns[:booster_unmatched]} class="alert alert-warning mb-4">
            Your booster is on a match we couldn't import — saving this round will leave you
            without a booster. Fix the unmatched row on FIFA, or proceed knowingly.
          </p>

          <p class="mb-2 font-semibold">
            This will overwrite your existing picks for these {length(@matched)} matches:
          </p>
          <ul class="mb-4">
            <li :for={m <- @matched}>
              {m.team1} {m.home_goals}–{m.away_goals} {m.team2}{if m.booster, do: " ⚡"}
            </li>
          </ul>

          <div :if={@unmatched != []} class="mb-4">
            <p class="font-semibold">We couldn't match these rows:</p>
            <ul>
              <li :for={u <- @unmatched}>
                round {u.round}, match {u.matchId} — {reason_text(u.reason)}
              </li>
            </ul>
          </div>

          <button class="btn btn-primary" phx-click="confirm" disabled={@matched == []}>
            Confirm import
          </button>
        </div>

        <div :if={@step == :done}>
          <p class="alert alert-success">
            Imported {@summary.imported} picks{if @summary.errors > 0,
              do: " (#{@summary.errors} errors)"}.
          </p>
          <.link navigate={~p"/predictions"} class="btn">See my predictions</.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp paste_form(assigns) do
    ~H"""
    <form id="paste-form" phx-submit="paste">
      <textarea
        name="paste[json]"
        rows="6"
        class="textarea textarea-bordered w-full"
        placeholder="[{&quot;round&quot;:1,&quot;matchId&quot;:1,&quot;homeScore&quot;:2,&quot;awayScore&quot;:0,&quot;booster&quot;:true}]"
      ></textarea>
      <button type="submit" class="btn btn-primary mt-2">Preview</button>
    </form>
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
        } catch (e) { console.warn('FIFA import: round ' + r + ' failed', e); }
      }
      const b64 = btoa(JSON.stringify(rows)).replace(/\\+/g, '-').replace(/\\//g, '_').replace(/=+$/, '');
      window.open('#{@import_url}#' + b64, '_blank');
    })();
    """

    # Encode aggressively: a bare '#' or space in a javascript: href would break it, and
    # URI.encode/1 leaves reserved chars (incl. '#') alone. char_unreserved? escapes them.
    "javascript:" <> URI.encode(js, &URI.char_unreserved?/1)
  end

  defp reason_text(:unknown_match_id), do: "couldn't match this FIFA match"
  defp reason_text(:no_fixture), do: "couldn't match the teams/date to a fixture"
  defp reason_text(:out_of_scope), do: "knockout rounds aren't imported yet"
  defp reason_text(:invalid), do: "the scoreline was incomplete"
end
