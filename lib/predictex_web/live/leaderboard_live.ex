defmodule PredictexWeb.LeaderboardLive do
  @moduledoc """
  The league leaderboard — ranked standings from `Predictex.Standings`, with a
  one-tap "Copy WhatsApp text" button for sharing in the group chat.
  """
  use PredictexWeb, :live_view

  alias Predictex.{Standings, Tournament}

  @impl true
  def mount(_params, _session, socket) do
    standings = Standings.leaderboard()

    {:ok,
     socket
     |> assign(:page_title, "Leaderboard")
     |> assign(:completed, Tournament.completed_fixture_count())
     |> assign(:standings, standings)
     |> assign(:whatsapp_text, whatsapp_text(standings))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <div>
          <h1 class="text-2xl font-bold">Leaderboard</h1>
          <p class="text-sm opacity-70">
            FIFA World Cup 2026 · {@completed} {ngettext("fixture", "fixtures", @completed)} scored
          </p>
        </div>

        <div :if={@standings == []} class="rounded-box bg-base-200 p-6 text-center">
          <p class="font-medium">No players yet</p>
          <p class="text-sm opacity-70">
            Standings appear once players and their predictions are added.
          </p>
        </div>

        <div :if={@standings != []} class="space-y-4">
          <table class="table">
            <thead>
              <tr>
                <th>#</th>
                <th>Player</th>
                <th class="text-right">Fixtures</th>
                <th class="text-right">Bonus</th>
                <th class="text-right">Total</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{s, rank} <- Enum.with_index(@standings, 1)}>
                <td class="font-mono opacity-60">{rank}</td>
                <td class="font-medium">{s.name}</td>
                <td class="text-right tabular-nums">{s.fixtures_total}</td>
                <td class="text-right tabular-nums">{s.round_bonus_total}</td>
                <td class="text-right tabular-nums font-semibold">{s.total}</td>
              </tr>
            </tbody>
          </table>

          <button
            id="copy-wa"
            phx-hook=".CopyWhatsApp"
            data-target="wa-text"
            class="btn btn-sm btn-primary"
          >
            Copy WhatsApp text
          </button>
          <pre id="wa-text" class="hidden">{@whatsapp_text}</pre>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyWhatsApp">
        export default {
          mounted() {
            this.el.addEventListener("click", () => {
              const target = document.getElementById(this.el.dataset.target)
              if (!target) return
              navigator.clipboard.writeText(target.textContent).then(() => {
                const original = this.el.textContent
                this.el.textContent = "Copied!"
                setTimeout(() => { this.el.textContent = original }, 1500)
              })
            })
          }
        }
      </script>
    </Layouts.app>
    """
  end

  defp whatsapp_text([]), do: "🏆 Predictex — World Cup 2026\nNo scores yet."

  defp whatsapp_text(standings) do
    rows =
      standings
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {s, rank} -> "#{rank}. #{s.name} — #{s.total}" end)

    "🏆 Predictex — World Cup 2026\n" <> rows
  end
end
