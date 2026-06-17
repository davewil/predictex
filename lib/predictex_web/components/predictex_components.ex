defmodule PredictexWeb.PredictexComponents do
  @moduledoc """
  Predictex domain UI atoms — the reusable building blocks from the
  `Predictex.dc.html` design handoff (claude.ai/design).

  The two atoms the brief asked for (`fixture_card/1` and `leaderboard_row/1`)
  are reused across every screen, so they live here as DRY function components
  rather than being duplicated per screen. Everything is expressed in daisyUI
  tokens + Tailwind utilities so it re-themes with `app.css`:

    * `primary`  — pitch green: identity & actions, "you"
    * `accent`   — champagne gold: winners, boosters, bonus moments (rationed)
    * `warning`  — points amber: per-fixture points chips
    * `error`    — no-pick red: missing / unimported picks
    * `info`     — pitch blue: knockout first-team / first-scorer
    * `success`  — bright green: correct picks
  """
  use Phoenix.Component

  alias PredictexWeb.Flags

  @doc """
  The Predictex mark — pitch-green tile with a gold ring (a ball on the pitch).

  ## Examples

      <.brand_logo size="36" />
  """
  attr :size, :string, default: "32"
  attr :class, :string, default: nil

  def brand_logo(assigns) do
    ~H"""
    <svg width={@size} height={@size} viewBox="0 0 36 36" class={@class} aria-hidden="true">
      <rect width="36" height="36" rx="10" class="fill-primary" />
      <circle
        cx="18"
        cy="18"
        r="10"
        fill="none"
        stroke="currentColor"
        stroke-width="2.6"
        class="text-accent"
      />
      <circle cx="18" cy="18" r="4.4" class="fill-accent" />
    </svg>
    """
  end

  @doc """
  A single leaderboard standing — used for the "chasing pack" below the champion
  spotlight. Mobile-first: rank, name and total always show; the fixtures/bonus
  columns reveal from `sm:` upward.

  Rank 2/3 get a subtle silver/bronze left-accent; the current player gets a
  pitch-green highlight and a YOU badge.

  ## Examples

      <.leaderboard_row rank={2} name="Sav" fixtures={236} bonus={60} total={296} />
      <.leaderboard_row rank={6} name="Dave" fixtures={150} bonus={40} total={210} you />
  """
  attr :rank, :integer, required: true
  attr :name, :string, required: true
  attr :fixtures, :integer, required: true
  attr :bonus, :integer, required: true
  attr :total, :integer, required: true
  attr :you, :boolean, default: false

  def leaderboard_row(assigns) do
    ~H"""
    <div class={[
      "flex items-center gap-3 rounded-box border px-3 py-3 sm:px-4",
      row_accent(@rank, @you)
    ]}>
      <div class={["w-7 shrink-0 text-center", (@you && "text-primary") || "text-base-content/50"]}>
        <span :if={medal(@rank)} class="text-xl">{medal(@rank)}</span>
        <span :if={!medal(@rank)} class="font-score text-sm">{@rank}</span>
      </div>

      <div class="flex min-w-0 flex-1 items-center gap-2">
        <span class={["truncate font-bold", @you && "text-primary"]} title={@name}>{@name}</span>
        <span
          :if={@you}
          class="rounded bg-primary px-1.5 py-0.5 text-[9px] font-extrabold tracking-wider text-primary-content"
        >
          YOU
        </span>
      </div>

      <div
        class="hidden w-20 shrink-0 text-right font-score text-sm text-base-content/60 sm:block"
        title="Points from fixtures (regular scoring)"
      >
        {@fixtures}
      </div>
      <div
        class="hidden w-16 shrink-0 text-right font-score text-sm text-base-content/60 sm:block"
        title="Bonus points"
      >
        {@bonus}
      </div>
      <div class={[
        "w-12 shrink-0 text-right font-score text-2xl font-bold tabular-nums",
        (@you && "text-primary") || "text-base-content"
      ]}>
        {@total}
      </div>
    </div>
    """
  end

  @doc """
  The reused FixtureCard — one player's pick for one fixture, in every state:
  result-in (with EXACT + points), booster 2×, locked, open (edit on FIFA),
  no-pick-imported, and knockout (first-team / first-scorer).

  Binds to a `Predictex.Dashboard` fixture entry, so it speaks the real data
  shape (`fixture`, `prediction`, `status`, `locked?`, `points`, `booster?`,
  `exact?`). `stage` is the round stage so knockout extras only render in KO
  rounds.

  ## Examples

      <.fixture_card fx={fx} stage={@active.round.stage} fifa_url={@fifa_url} />
      <.fixture_card fx={fx} stage={@active.round.stage} fifa_url={@fifa_url} live_buzz?={@live_buzz?} />

  `live_buzz?` defaults to `false` and can be omitted when the feature flag is off.
  """
  attr :fx, :map, required: true
  attr :stage, :atom, required: true
  attr :fifa_url, :string, default: nil
  attr :live_buzz?, :boolean, default: false

  def fixture_card(assigns) do
    assigns =
      assigns
      |> assign(:pred, assigns.fx.prediction)
      |> assign(:done?, assigns.fx.status == :completed)
      |> assign(:no_pick?, assigns.fx.prediction == nil)

    ~H"""
    <div class={[
      "relative overflow-hidden rounded-box bg-base-100 p-3.5 shadow",
      card_border(@fx, @no_pick?)
    ]}>
      <%!-- booster 2× corner ribbon — gold, rationed to boosted fixtures --%>
      <div
        :if={@fx.booster?}
        class="absolute right-0 top-0 rounded-bl-xl bg-accent px-2.5 py-1 text-[10px] font-extrabold tracking-wide text-accent-content"
      >
        ⚡ 2×
      </div>

      <%!-- header: kickoff + status --%>
      <div class="flex justify-between pr-12 text-[10px] font-semibold uppercase tracking-wider text-base-content/55">
        <span>{kickoff(@fx.fixture.kickoff_at)}</span>
        <span class={status_color(@fx)}>{status_label(@fx)}</span>
      </div>

      <%!-- live score badge — only when :live_buzz feature flag is on and fixture is in play --%>
      <span :if={@live_buzz? and @fx.fixture.is_live} class="font-bold text-error">
        LIVE {@fx.fixture.live_minute} · {@fx.fixture.live_home_goals}-{@fx.fixture.live_away_goals}
      </span>

      <%!-- teams + the player's predicted scoreline --%>
      <div class="mt-3 flex items-center justify-center gap-2.5">
        <div class="flex-1 truncate text-right text-sm font-bold" title={@fx.fixture.team1}>
          {@fx.fixture.team1} <span class="text-lg">{Flags.flag(@fx.fixture.team1)}</span>
        </div>
        <div class={[
          "font-score rounded-lg border px-3 py-1 text-xl font-bold tabular-nums",
          score_box(@fx, @no_pick?)
        ]}>
          {home_score(@pred)} – {away_score(@pred)}
        </div>
        <div class="flex-1 truncate text-left text-sm font-bold" title={@fx.fixture.team2}>
          <span class="text-lg">{Flags.flag(@fx.fixture.team2)}</span> {@fx.fixture.team2}
        </div>
      </div>

      <%!-- knockout extras: first team + first scorer --%>
      <div :if={@stage == :knockout and @pred} class="mt-2.5 flex flex-col gap-1.5 text-[11px]">
        <div class="flex justify-between rounded-lg bg-info/10 px-2.5 py-1.5">
          <span class="text-base-content/60">First team</span>
          <span class="font-bold">{side_label(@pred.first_scorer_side, @fx.fixture)}</span>
        </div>
        <div class="flex justify-between rounded-lg bg-info/10 px-2.5 py-1.5">
          <span class="text-base-content/60">First scorer</span>
          <span class="font-bold">{@pred.first_scorer_player || "—"}</span>
        </div>
      </div>

      <%!-- result in --%>
      <div :if={@pred && @done?} class="mt-3 flex flex-wrap items-center justify-center gap-2">
        <span class="text-[11px] text-base-content/60">
          Actual
          <strong class="font-score text-base-content">{@fx.fixture.home_goals}–{@fx.fixture.away_goals}</strong>
        </span>
        <span
          :if={@fx.exact?}
          class="rounded-md bg-accent/20 px-2 py-0.5 text-[10px] font-bold tracking-wide text-accent"
        >
          EXACT ✓✓
        </span>
        <span class={[
          "font-score rounded-md px-2.5 py-0.5 text-xs font-extrabold",
          (@fx.booster? && "bg-accent text-accent-content") || "bg-warning text-warning-content"
        ]}>
          +{@fx.points}
        </span>
      </div>

      <%!-- no pick imported --%>
      <div :if={@no_pick?} class="mt-3 text-center text-xs font-bold text-error">
        ⚠ No pick imported yet
      </div>

      <%!-- locked, awaiting result --%>
      <div
        :if={@pred && not @done? && @fx.locked?}
        class="mt-2.5 text-center text-[11px] italic text-base-content/55"
      >
        Locked at kick-off — awaiting result
      </div>

      <%!-- open, still editable on FIFA --%>
      <div :if={@pred && not @done? && not @fx.locked? && @fifa_url} class="mt-3 flex justify-center">
        <a
          href={@fifa_url}
          target="_blank"
          rel="noopener"
          class="rounded-full border border-primary/30 bg-primary/10 px-3 py-1 text-[11px] font-semibold text-primary"
        >
          🌐 Edit on FIFA →
        </a>
      </div>
    </div>
    """
  end

  @doc """
  The auth shell — the design's split-screen front gate. A pitch-green brand
  panel (desktop only) beside the form panel. The form itself is passed as the
  inner block, so the real `<.form>`, inputs and bindings stay untouched.

  ## Examples

      <.auth_card heading="Welcome back" sub="Let's see where you stand.">
        <.form ...>...</.form>
      </.auth_card>
  """
  attr :heading, :string, required: true
  attr :sub, :string, default: nil
  slot :inner_block, required: true

  def auth_card(assigns) do
    ~H"""
    <div class="mx-auto max-w-4xl overflow-hidden rounded-box border border-base-300 bg-base-100 shadow-xl lg:grid lg:grid-cols-2">
      <%!-- brand panel — desktop only --%>
      <div class="relative hidden overflow-hidden bg-gradient-to-br from-primary to-secondary p-8 text-white lg:flex lg:flex-col lg:justify-between">
        <div class="pointer-events-none absolute -right-12 -top-10 size-52 rounded-full border-2 border-accent/25">
        </div>
        <div class="pointer-events-none absolute right-2 top-5 size-32 rounded-full border-2 border-white/10">
        </div>
        <div class="relative flex items-center gap-2.5">
          <.brand_logo size="30" />
          <span class="text-lg font-black tracking-tight">Predictex</span>
        </div>
        <div class="relative">
          <div class="text-3xl font-black leading-tight tracking-tight text-balance">
            Predict the scores.<br />Win the group chat.
          </div>
          <p class="mt-3 max-w-xs text-sm leading-relaxed text-white/80">
            A private World Cup 2026 prediction league for you and the group. Call the scorelines,
            bank the bonuses, climb the table.
          </p>
        </div>
        <div class="relative flex flex-wrap gap-2">
          <span class="rounded-full bg-white/15 px-3 py-1.5 text-[11px] font-bold">🏆 Private league</span>
          <span class="rounded-full bg-accent px-3 py-1.5 text-[11px] font-bold text-accent-content">⚡ 2× boosters</span>
        </div>
      </div>

      <%!-- form panel --%>
      <div class="p-6 sm:p-8">
        <.brand_logo size="40" class="mb-4 lg:hidden" />
        <h1 class="text-2xl font-black tracking-tight">{@heading}</h1>
        <p :if={@sub} class="mb-5 mt-1 text-sm text-base-content/60">{@sub}</p>
        <div class="mt-4">{render_slot(@inner_block)}</div>
      </div>
    </div>
    """
  end

  @doc """
  The scoring legend from the design's Foundations section — surfaces how a
  fixture earns points so players can read their totals at a glance.
  """
  def scoring_legend(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300 bg-base-100 p-4">
      <div class="mb-3 text-xs font-semibold text-base-content/55">
        How a fixture earns points
      </div>
      <div class="mb-2 text-[10px] font-bold uppercase tracking-wider text-base-content/45">
        Per fixture
      </div>
      <div class="mb-4 flex flex-wrap gap-1.5">
        <.legend_chip tone="success" label="Correct outcome" pts="+10" />
        <.legend_chip tone="success" label="Home goals" pts="+5" />
        <.legend_chip tone="success" label="Away goals" pts="+5" />
        <.legend_chip tone="success" label="Goal diff" pts="+5" />
        <.legend_chip tone="accent" label="Exact score" pts="+5" />
      </div>
      <div class="mb-2 text-[10px] font-bold uppercase tracking-wider text-base-content/45">
        Bonuses &amp; knockout
      </div>
      <div class="flex flex-wrap gap-1.5">
        <.legend_chip tone="accent" label="⚡ Risky pick" pts="+10" />
        <.legend_chip tone="accent" label="All-correct round" pts="+20" />
        <.legend_chip tone="info" label="First team" pts="+5" />
        <.legend_chip tone="info" label="First scorer" pts="+10" />
      </div>
      <p class="mt-3 text-[11px] leading-relaxed text-base-content/55">
        Risky = a right call when <strong class="text-base-content/80">&lt;20%</strong>
        of players agreed. A booster <strong class="text-accent">2×</strong>
        doubles one fixture per round.
      </p>
    </div>
    """
  end

  attr :tone, :string, required: true
  attr :label, :string, required: true
  attr :pts, :string, required: true

  defp legend_chip(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 rounded-lg px-2.5 py-1 text-xs font-semibold",
      chip_tone(@tone)
    ]}>
      {@label} <b class="font-score">{@pts}</b>
    </span>
    """
  end

  # ── styling helpers ──────────────────────────────────────────────────────

  defp medal(1), do: "🥇"
  defp medal(2), do: "🥈"
  defp medal(3), do: "🥉"
  defp medal(_), do: nil

  defp row_accent(_rank, true),
    do: "border-primary/50 border-l-[3px] border-l-primary bg-primary/10"

  defp row_accent(1, _you), do: "border-accent/40 border-l-[3px] border-l-accent bg-accent/10"

  defp row_accent(2, _you),
    do: "border-base-content/20 border-l-[3px] border-l-base-content/40 bg-base-content/5"

  defp row_accent(3, _you),
    do: "border-warning/25 border-l-[3px] border-l-warning/60 bg-warning/5"

  defp row_accent(_rank, _you), do: "border-base-300 bg-base-100"

  defp card_border(%{exact?: true, status: :completed}, _no_pick),
    do: "border border-accent/45 ring-1 ring-accent/15"

  defp card_border(_fx, true), do: "border border-dashed border-error/50"
  defp card_border(_fx, _no_pick), do: "border border-base-300"

  defp score_box(%{exact?: true, status: :completed}, _no_pick),
    do: "border-accent/40 bg-base-300 text-accent"

  defp score_box(_fx, true), do: "border-base-content/10 bg-base-300 text-base-content/40"
  defp score_box(_fx, _no_pick), do: "border-base-content/10 bg-base-300 text-base-content"

  defp status_color(%{status: :completed}), do: "text-base-content/55"
  defp status_color(%{locked?: true}), do: "text-base-content/55"
  defp status_color(_), do: "text-success"

  defp status_label(%{status: :completed}), do: "Full time"
  defp status_label(%{locked?: true}), do: "🔒 Locked"
  defp status_label(_), do: "● Open"

  defp home_score(nil), do: "–"
  defp home_score(p), do: p.home_goals
  defp away_score(nil), do: "–"
  defp away_score(p), do: p.away_goals

  defp side_label(:home, fixture), do: "#{Flags.flag(fixture.team1)} #{fixture.team1}"
  defp side_label(:away, fixture), do: "#{Flags.flag(fixture.team2)} #{fixture.team2}"
  defp side_label(_, _), do: "—"

  defp kickoff(nil), do: "TBC"
  defp kickoff(%DateTime{} = dt), do: Calendar.strftime(dt, "%a %d %b · %H:%M")

  defp chip_tone("success"), do: "bg-success/15 text-success"
  defp chip_tone("accent"), do: "bg-accent/15 text-accent"
  defp chip_tone("info"), do: "bg-info/15 text-info"
  defp chip_tone(_), do: "bg-base-200 text-base-content"
end
