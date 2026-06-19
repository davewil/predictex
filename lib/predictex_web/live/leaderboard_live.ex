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
     |> assign(:whatsapp_text, whatsapp_text(standings))
     |> assign(:live_fixtures, Tournament.list_live_fixtures())}
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, :champion, List.first(assigns.standings))
      |> assign(:chasing, chasing_pack(assigns.standings))

    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-5">
        <div class="flex items-end justify-between gap-4">
          <div>
            <h1 class="text-2xl font-black tracking-tight">Leaderboard</h1>
            <p class="text-sm text-base-content/60">
              FIFA World Cup 2026 · {@completed} {ngettext("fixture", "fixtures", @completed)} scored
            </p>
          </div>
          <button
            id="copy-wa"
            phx-hook=".CopyWhatsApp"
            data-target="wa-text"
            class="btn btn-primary btn-sm gap-2 shadow-lg shadow-primary/30"
          >
            📋 Copy WhatsApp text
          </button>
        </div>

        <section :if={@live_fixtures != []} class="mb-4">
          <h2 class="font-semibold">Live now</h2>
          <ul>
            <li :for={f <- @live_fixtures}>
              <.link navigate={~p"/fixtures/#{f.id}"}>
                {f.team1} v {f.team2} — {f.live_home_goals}-{f.live_away_goals}
              </.link>
            </li>
          </ul>
        </section>

        <div :if={@standings == []} class="rounded-box bg-base-200 p-6 text-center">
          <p class="font-medium">No players yet</p>
          <p class="text-sm opacity-70">
            Standings appear once players and their predictions are added.
          </p>
        </div>

        <div :if={@champion} class="space-y-4">
          <%!-- champion spotlight — the leader gets the gold hero --%>
          <div class="animate-pdx-rise flex items-center gap-4 rounded-box border border-accent/40 bg-gradient-to-br from-accent/20 to-accent/[0.03] p-4 sm:gap-5 sm:p-5">
            <div class="text-4xl sm:text-5xl">🥇</div>
            <div class="min-w-0 flex-1">
              <div class="text-[10px] font-extrabold uppercase tracking-wider text-accent">
                👑 League leader
                <span :if={you?(@current_scope, @champion.player_id)} class="text-primary">· YOU</span>
              </div>
              <div
                class="truncate text-2xl font-black tracking-tight sm:text-3xl"
                title={@champion.name}
              >
                {@champion.name}
              </div>
              <div class="text-xs text-accent/80">
                {@champion.fixtures_total} from fixtures · {@champion.round_bonus_total} bonus
              </div>
            </div>
            <div class="shrink-0 text-right">
              <div class="font-score text-4xl font-bold leading-none text-accent sm:text-5xl">
                {@champion.total}
              </div>
            </div>
          </div>

          <%!-- the chasing pack --%>
          <div :if={@chasing != []}>
            <div class="mb-2 px-1 text-[11px] font-bold uppercase tracking-widest text-base-content/55">
              The chasing pack
            </div>
            <div class="flex flex-col gap-2">
              <.leaderboard_row
                :for={{s, rank} <- @chasing}
                rank={rank}
                name={s.name}
                fixtures={s.fixtures_total}
                bonus={s.round_bonus_total}
                total={s.total}
                you={you?(@current_scope, s.player_id)}
              />
            </div>
          </div>

          <%!-- the share moment — what lands in the group chat --%>
          <div class="rounded-box border border-base-300 bg-base-200/40 p-4">
            <p class="mb-3 text-xs text-base-content/60">
              One tap copies clean, ranked text — built for pasting straight into the group chat:
            </p>
            <div class="flex justify-end">
              <div class="max-w-xs rounded-2xl rounded-br-sm bg-[#075e54] px-3 py-2.5 text-[#e9f5ef] shadow-lg">
                <pre class="whitespace-pre-wrap font-score text-xs leading-relaxed">{@whatsapp_text}</pre>
              </div>
            </div>
          </div>

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

  # True when the standings entry belongs to the logged-in player. `current_scope` is
  # nil for logged-out visitors (Scope.for_player(nil)), so the catch-all keeps this total.
  defp you?(%{player: %{id: id}}, id), do: true
  defp you?(_scope, _player_id), do: false

  # ranks 2..N, each paired with its real rank number
  defp chasing_pack([]), do: []

  defp chasing_pack([_champion | rest]),
    do: rest |> Enum.with_index(2) |> Enum.map(fn {s, rank} -> {s, rank} end)

  defp whatsapp_text([]), do: "🏆 Predictex — World Cup 2026\nNo scores yet."

  defp whatsapp_text(standings) do
    rows =
      standings
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {s, rank} -> "#{rank}. #{s.name} — #{s.total}" end)

    "🏆 Predictex — World Cup 2026\n" <> rows
  end
end
