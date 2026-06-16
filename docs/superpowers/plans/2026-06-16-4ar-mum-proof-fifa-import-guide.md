# Mum-proof FIFA Import Guide Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `/import` mum-proof and platform-aware — desktop keeps a relabelled one-tap bookmarklet; mobile gets a no-install, jargon-free, per-round copy-paste flow that survives mobile tab discards; with a screenshot→admin escape hatch.

**Architecture:** A request plug classifies `:mobile | :desktop` from the User-Agent into the session. `ImportLive` reads it and renders one flow. Desktop = the existing bookmarklet → single all-rounds preview → single confirm. Mobile = progressive per-round: paste FIFA's raw response → preview that round → confirm → **write that round to the DB immediately** → reveal the next. The pure `Fifa.Import.plan/3` core is untouched; a new pure `rows_from_envelope/2` adapts FIFA's raw envelope (which lacks the round) into `plan/3` rows by injecting the known round.

**Tech Stack:** Elixir, Phoenix LiveView, daisyUI/Tailwind, ExUnit + `Phoenix.LiveViewTest`.

**Spec:** `docs/superpowers/specs/2026-06-16-4ar-mum-proof-fifa-import-guide.md`

---

## Pre-build validation (do before Task 1, ~3 min, not code)

On the Android phone, open `https://play.fifa.com/api/en/match-predictor/prediction/show/1`
while logged in, then long-press → **Select all** → **Copy** → paste into any text field.
Confirm Chrome offers "Select all" on the raw-text page and the whole blob copies. If the
gesture is awkward even for a developer, stop and revisit how much we lean on the escape hatch
before building the illustrated mobile flow.

---

## File Structure

- **Create** `lib/predictex_web/plugs/platform_plug.ex` — request plug: UA → `:platform` in session. One responsibility: platform classification.
- **Create** `test/predictex_web/plugs/platform_plug_test.exs` — unit tests for the plug.
- **Modify** `lib/predictex_web/router.ex` — add the plug to the `:browser` pipeline.
- **Modify** `lib/predictex/fifa/import.ex` — add the pure `rows_from_envelope/2`.
- **Modify** `test/predictex/fifa/import_test.exs` — tests for `rows_from_envelope/2`.
- **Modify** `lib/predictex_web/live/import_live.ex` — platform-aware mount, desktop + mobile render branches, per-round mobile handlers, jargon purge, escape hatch, confirmation reword.
- **Modify** `test/predictex_web/live/import_live_test.exs` — rewrite for desktop (fragment) + mobile (per-round envelope) flows + remount-persistence regression.

---

## Task 1: Platform-detection plug

**Files:**
- Create: `lib/predictex_web/plugs/platform_plug.ex`
- Test: `test/predictex_web/plugs/platform_plug_test.exs`
- Modify: `lib/predictex_web/router.ex` (add to `:browser` pipeline)

- [ ] **Step 1: Write the failing test**

Create `test/predictex_web/plugs/platform_plug_test.exs`:

```elixir
defmodule PredictexWeb.PlatformPlugTest do
  use PredictexWeb.ConnCase, async: true

  alias PredictexWeb.PlatformPlug

  defp run(ua) do
    conn = Plug.Test.init_test_session(build_conn(), %{})
    conn = if ua, do: Plug.Conn.put_req_header(conn, "user-agent", ua), else: conn
    PlatformPlug.call(conn, PlatformPlug.init([]))
  end

  test "classifies an iPhone UA as :mobile" do
    conn = run("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) Safari")
    assert Plug.Conn.get_session(conn, :platform) == :mobile
  end

  test "classifies an Android UA as :mobile" do
    conn = run("Mozilla/5.0 (Linux; Android 14; Pixel 7) Chrome Mobile")
    assert Plug.Conn.get_session(conn, :platform) == :mobile
  end

  test "classifies a desktop UA as :desktop" do
    conn = run("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/120 Safari")
    assert Plug.Conn.get_session(conn, :platform) == :desktop
  end

  test "defaults to :mobile when the User-Agent is absent" do
    conn = run(nil)
    assert Plug.Conn.get_session(conn, :platform) == :mobile
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/predictex_web/plugs/platform_plug_test.exs`
Expected: FAIL — `PredictexWeb.PlatformPlug` is undefined (`module ... is not available`).

- [ ] **Step 3: Write the plug**

Create `lib/predictex_web/plugs/platform_plug.ex`:

```elixir
defmodule PredictexWeb.PlatformPlug do
  @moduledoc """
  Classifies the request as `:mobile` or `:desktop` from the User-Agent and stores it in the
  session as `:platform`, so `ImportLive` can pick the right import flow on BOTH the disconnected
  (static) and connected (websocket) mount — the session is available to both, whereas
  `connect_info` is nil on the first static render. Defaults to `:mobile` when the UA is absent:
  the harder-to-misuse path and the majority of the audience.
  """
  import Plug.Conn

  @mobile ~r/Mobi|Android|iPhone|iPad|iPod/i

  def init(opts), do: opts

  def call(conn, _opts) do
    platform =
      case get_req_header(conn, "user-agent") do
        [ua | _] -> if Regex.match?(@mobile, ua), do: :mobile, else: :desktop
        [] -> :mobile
      end

    put_session(conn, :platform, platform)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/predictex_web/plugs/platform_plug_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Wire the plug into the `:browser` pipeline**

In `lib/predictex_web/router.ex`, find the `pipeline :browser do` block and add the plug as the
last entry (after `fetch_session`, so the session is available to write):

```elixir
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PredictexWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_player
    plug PredictexWeb.PlatformPlug
  end
```

> Note: match the EXISTING plugs in your `:browser` pipeline verbatim and just append
> `plug PredictexWeb.PlatformPlug` — do not remove or reorder the existing ones. The only
> requirement is that it runs after `:fetch_session`.

- [ ] **Step 6: Run the full suite to confirm nothing else broke yet**

Run: `mix test test/predictex_web/plugs/platform_plug_test.exs && mix compile --warnings-as-errors`
Expected: plug tests PASS; compile clean.

- [ ] **Step 7: Commit**

```bash
git add lib/predictex_web/plugs/platform_plug.ex test/predictex_web/plugs/platform_plug_test.exs lib/predictex_web/router.ex
git commit -m "feat(4ar): platform-detection plug (UA -> :platform in session)"
```

---

## Task 2: `Fifa.Import.rows_from_envelope/2` (pure adapter)

**Files:**
- Modify: `lib/predictex/fifa/import.ex`
- Test: `test/predictex/fifa/import_test.exs`

- [ ] **Step 1: Write the failing tests**

Add this `describe` block to `test/predictex/fifa/import_test.exs` (inside the module, after the
`describe "decode_payload/1"` block):

```elixir
  describe "rows_from_envelope/2" do
    test "maps a FIFA envelope to plan rows, injecting the round" do
      envelope = %{
        "success" => %{
          "predictions" => [
            %{"matchId" => 1, "homeScore" => 2, "awayScore" => 0, "booster" => true},
            %{"matchId" => 2, "homeScore" => 1, "awayScore" => 1, "booster" => false}
          ]
        },
        "errors" => []
      }

      assert {:ok, rows} = Import.rows_from_envelope(envelope, 1)

      assert rows == [
               %{"round" => 1, "matchId" => 1, "homeScore" => 2, "awayScore" => 0, "booster" => true},
               %{"round" => 1, "matchId" => 2, "homeScore" => 1, "awayScore" => 1, "booster" => false}
             ]
    end

    test "accepts a bare predictions list too" do
      list = [%{"matchId" => 5, "homeScore" => 0, "awayScore" => 3, "booster" => false}]
      assert {:ok, [row]} = Import.rows_from_envelope(list, 2)
      assert row == %{"round" => 2, "matchId" => 5, "homeScore" => 0, "awayScore" => 3, "booster" => false}
    end

    test "coerces a missing/non-true booster to false" do
      envelope = %{"success" => %{"predictions" => [%{"matchId" => 1, "homeScore" => 1, "awayScore" => 0}]}}
      assert {:ok, [row]} = Import.rows_from_envelope(envelope, 1)
      assert row["booster"] == false
    end

    test "empty predictions yields an empty row list (not an error)" do
      assert {:ok, []} = Import.rows_from_envelope(%{"success" => %{"predictions" => []}}, 1)
    end

    test "rejects a shape that is neither an envelope nor a list" do
      assert {:error, :bad_envelope} = Import.rows_from_envelope(%{"oops" => true}, 1)
      assert {:error, :bad_envelope} = Import.rows_from_envelope("nope", 1)
    end

    test "ignores entries with no matchId rather than crashing" do
      envelope = %{"success" => %{"predictions" => [%{"homeScore" => 1, "awayScore" => 0}]}}
      assert {:ok, []} = Import.rows_from_envelope(envelope, 1)
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/predictex/fifa/import_test.exs`
Expected: FAIL — `function Import.rows_from_envelope/2 is undefined`.

- [ ] **Step 3: Implement the function**

In `lib/predictex/fifa/import.ex`, add this public function (place it just after `decode_payload/1`
and its private `url_decode/1`, before the `plan/3` docs):

```elixir
  @doc """
  Build `plan/3`-ready rows from a decoded FIFA prediction envelope (or a bare predictions list),
  injecting the known `round` (FIFA's response does not carry it — it is implied by which
  `/prediction/show/{round}` produced the data). Tolerates `%{"success" => %{"predictions" => [...]}}`
  and a top-level `[...]`. Entries without a `matchId` are skipped. `{:ok, rows} | {:error, :bad_envelope}`.
  """
  def rows_from_envelope(decoded, round) when is_integer(round) do
    case predictions(decoded) do
      nil ->
        {:error, :bad_envelope}

      list ->
        rows =
          for %{"matchId" => match_id} = p <- list do
            %{
              "round" => round,
              "matchId" => match_id,
              "homeScore" => p["homeScore"],
              "awayScore" => p["awayScore"],
              "booster" => p["booster"] == true
            }
          end

        {:ok, rows}
    end
  end

  defp predictions(%{"success" => %{"predictions" => p}}) when is_list(p), do: p
  defp predictions(p) when is_list(p), do: p
  defp predictions(_), do: nil
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/predictex/fifa/import_test.exs`
Expected: PASS (all existing + 6 new).

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/fifa/import.ex test/predictex/fifa/import_test.exs
git commit -m "feat(4ar): Fifa.Import.rows_from_envelope/2 — raw FIFA envelope -> plan rows"
```

---

## Task 3: `ImportLive` — platform-aware mount + render + per-round mobile handlers

This task rewrites `lib/predictex_web/live/import_live.ex`. Write the tests first (Step 1),
watch them fail (Step 2), then replace the file (Step 3).

**Files:**
- Modify: `lib/predictex_web/live/import_live.ex`
- Test: `test/predictex_web/live/import_live_test.exs` (full rewrite)

- [ ] **Step 1: Replace the test file with the new flows**

Replace the entire contents of `test/predictex_web/live/import_live_test.exs` with:

```elixir
defmodule PredictexWeb.ImportLiveTest do
  use PredictexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  alias Predictex.{Predictions, Tournament}

  @iphone "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) Safari"
  @desktop "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/120 Safari"

  defp group_round(ordinal) do
    {:ok, r} =
      Tournament.create_round(%{name: "Matchday #{ordinal}", stage: :group, ordinal: ordinal})

    r
  end

  defp fixture!(round, team1, team2, kickoff) do
    {:ok, f} =
      Tournament.create_fixture(%{
        external_ref: "ref-#{System.unique_integer([:positive])}",
        team1: team1,
        team2: team2,
        status: :scheduled,
        kickoff_at: kickoff,
        round_id: round.id
      })

    f
  end

  defp fifa_round(id, matches), do: %{"id" => id, "stage" => "group", "tournaments" => matches}

  defp fifa_match(id, home, away, date),
    do: %{"id" => id, "homeSquadName" => home, "awaySquadName" => away, "date" => date}

  defp stub_rounds(rounds) do
    prev = Application.get_env(:predictex, :fifa_reference_fun)
    Application.put_env(:predictex, :fifa_reference_fun, fn -> {:ok, rounds} end)
    on_exit(fn -> Application.put_env(:predictex, :fifa_reference_fun, prev) end)
  end

  # The raw FIFA envelope as it appears at /prediction/show/{round} (no round field).
  defp fifa_envelope(preds) do
    Jason.encode!(%{
      "success" => %{
        "predictions" =>
          Enum.map(preds, fn {match_id, hs, as, booster} ->
            %{"matchId" => match_id, "homeScore" => hs, "awayScore" => as, "booster" => booster}
          end)
      },
      "errors" => []
    })
  end

  # Base64url payload as the desktop bookmarklet emits it (round-tagged rows for all rounds).
  defp bookmarklet_payload(rows) do
    rows |> Jason.encode!() |> Base.url_encode64(padding: false)
  end

  defp ua(conn, agent), do: Plug.Conn.put_req_header(conn, "user-agent", agent)

  # Visible text only — Floki.text drops attribute values (so the bookmarklet's javascript:
  # href, which legitimately contains "json"/"JSON.stringify", is excluded) and <script> content.
  # The jargon ban is about user-facing copy, not the opaque bookmarklet code.
  defp visible_text(html), do: html |> Floki.parse_document!() |> Floki.text() |> String.downcase()

  test "redirects to login when logged out", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/players/log-in"}}} = live(ua(conn, @iphone), ~p"/import")
  end

  describe "mobile per-round import" do
    setup :register_and_log_in_player

    test "paste round 1 -> preview -> confirm writes round 1 and reveals round 2", ctx do
      %{conn: conn, player: player} = ctx
      r1 = group_round(1)
      fx = fixture!(r1, "Mexico", "South Africa", ~U[2026-06-11 19:00:00Z])
      group_round(2)

      stub_rounds([
        fifa_round(1, [fifa_match(1, "Mexico", "South Africa", "2026-06-11T20:00:00+01:00")]),
        fifa_round(2, [])
      ])

      {:ok, view, html} = live(ua(conn, @iphone), ~p"/import")
      assert html =~ "Round 1"
      refute html =~ "Round 2"

      html =
        view
        |> form("#paste-form", paste: %{json: fifa_envelope([{1, 2, 0, true}])})
        |> render_submit()

      assert html =~ "Mexico"
      assert html =~ "South Africa"

      html = render_click(view, "confirm_round", %{})

      # Round 1 is written to the DB now (not held in assigns).
      [pred] = Predictions.list_player_predictions(player.id)
      assert pred.fixture_id == fx.id
      assert pred.home_goals == 2 and pred.away_goals == 0 and pred.booster == true

      # And the flow has advanced to round 2.
      assert html =~ "Round 2"
    end

    test "tab-discard regression: a confirmed round survives a fresh mount", ctx do
      %{conn: conn, player: player} = ctx
      r1 = group_round(1)
      fixture!(r1, "Mexico", "South Africa", ~U[2026-06-11 19:00:00Z])
      group_round(2)

      stub_rounds([
        fifa_round(1, [fifa_match(1, "Mexico", "South Africa", "2026-06-11T20:00:00+01:00")]),
        fifa_round(2, [])
      ])

      {:ok, view, _} = live(ua(conn, @iphone), ~p"/import")
      view |> form("#paste-form", paste: %{json: fifa_envelope([{1, 3, 1, false}])}) |> render_submit()
      render_click(view, "confirm_round", %{})

      # Simulate the discarded tab reloading: a brand-new LiveView mount.
      {:ok, _view2, _html2} = live(ua(conn, @iphone), ~p"/import")

      # Round 1 is still saved — progress was durable, not in volatile assigns.
      [pred] = Predictions.list_player_predictions(player.id)
      assert pred.home_goals == 3 and pred.away_goals == 1
    end

    test "a round with nothing matchable can be skipped without writing", ctx do
      %{conn: conn, player: player} = ctx
      group_round(1)
      group_round(2)
      stub_rounds([fifa_round(1, []), fifa_round(2, [])])

      {:ok, view, _} = live(ua(conn, @iphone), ~p"/import")

      html =
        view
        |> form("#paste-form", paste: %{json: fifa_envelope([{99, 2, 0, false}])})
        |> render_submit()

      assert html =~ "continue" or html =~ "Continue"
      html = render_click(view, "skip_round", %{})

      assert Predictions.list_player_predictions(player.id) == []
      assert html =~ "Round 2"
    end

    test "malformed paste keeps the round with a friendly error", ctx do
      %{conn: conn} = ctx
      group_round(1)
      stub_rounds([fifa_round(1, [])])
      {:ok, view, _} = live(ua(conn, @iphone), ~p"/import")

      html = view |> form("#paste-form", paste: %{json: "not json"}) |> render_submit()
      assert html =~ "couldn"
    end

    test "no developer jargon appears on the mobile flow", ctx do
      %{conn: conn} = ctx
      group_round(1)
      stub_rounds([fifa_round(1, [])])
      {:ok, _view, html} = live(ua(conn, @iphone), ~p"/import")
      text = visible_text(html)
      refute text =~ "bookmarklet"
      refute text =~ "json"
      refute text =~ "console"
    end
  end

  describe "desktop bookmarklet import" do
    setup :register_and_log_in_player

    test "bookmarklet payload -> preview all -> confirm writes every round", ctx do
      %{conn: conn, player: player} = ctx
      r1 = group_round(1)
      r2 = group_round(2)
      fx1 = fixture!(r1, "Mexico", "South Africa", ~U[2026-06-11 19:00:00Z])
      fx2 = fixture!(r2, "Brazil", "Serbia", ~U[2026-06-18 19:00:00Z])

      stub_rounds([
        fifa_round(1, [fifa_match(1, "Mexico", "South Africa", "2026-06-11T20:00:00+01:00")]),
        fifa_round(2, [fifa_match(1, "Brazil", "Serbia", "2026-06-18T20:00:00+01:00")])
      ])

      {:ok, view, html} = live(ua(conn, @desktop), ~p"/import")
      assert html =~ "Import my picks"

      rows = [
        %{"round" => 1, "matchId" => 1, "homeScore" => 2, "awayScore" => 0, "booster" => true},
        %{"round" => 2, "matchId" => 1, "homeScore" => 1, "awayScore" => 1, "booster" => false}
      ]

      html = render_hook(view, "payload", %{"data" => bookmarklet_payload(rows)})
      assert html =~ "Mexico"
      assert html =~ "Brazil"

      render_click(view, "confirm", %{})

      preds = Map.new(Predictions.list_player_predictions(player.id), &{&1.fixture_id, &1})
      assert preds[fx1.id].home_goals == 2
      assert preds[fx2.id].home_goals == 1
    end

    test "no developer jargon and no console-fallback copy on desktop", ctx do
      %{conn: conn} = ctx
      stub_rounds([])
      {:ok, _view, html} = live(ua(conn, @desktop), ~p"/import")
      text = visible_text(html)
      refute text =~ "bookmarklet"
      refute text =~ "json"
      refute text =~ "console"
    end
  end
end
```

> If `Floki.parse_document!/1` is undefined at this point, add `{:floki, ">= 0.30.0", only: :test}`
> to `mix.exs` deps and `mix deps.get` — `Phoenix.LiveViewTest` needs it anyway, so it is normally
> already resolvable.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/predictex_web/live/import_live_test.exs`
Expected: FAIL — the mobile flow, `confirm_round`/`skip_round` events, "Round N" copy and
"Import my picks" label do not exist yet (assertion failures / unhandled events).

- [ ] **Step 3: Replace `lib/predictex_web/live/import_live.ex`**

Replace the entire file with:

```elixir
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
    imported = write_matched(socket)
    advance(socket, socket.assigns.imported_total + imported)
  end

  def handle_event("skip_round", _params, socket) do
    advance(socket, socket.assigns.imported_total)
  end

  # ---- Desktop confirm: write all matched rounds together --------------------------------

  def handle_event("confirm", _params, socket) do
    imported = write_matched(socket)
    {:noreply, assign(socket, step: :done, summary: %{imported: imported, errors: 0})}
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
    |> Enum.reduce(0, fn {round_id, rows}, acc ->
      case Predictions.admin_save_round_predictions(player_id, round_id, rows) do
        {:ok, results} -> acc + Enum.count(results, fn {_id, r} -> r == :upserted end)
        {:error, _} -> acc
      end
    end)
  end

  defp advance(socket, total) do
    if socket.assigns.current_round >= @last_group_round do
      {:noreply, assign(socket, step: :done, imported_total: total, summary: %{imported: total, errors: 0})}
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-2xl">
        <h1 class="text-2xl font-bold mb-4">Import your FIFA picks</h1>

        <p :if={@error} class="alert alert-error mb-4">{@error}</p>

        <%!-- DESKTOP: one-tap button --%>
        <div :if={@platform == "desktop" and @step == :awaiting} id="import-root" phx-hook=".FifaFragment">
          <ol class="list-decimal ml-5 mb-4 space-y-1">
            <li>
              Drag this button up to your bookmarks bar:
              <a href={bookmarklet()} class="btn btn-sm">Import my picks</a>
            </li>
            <li>Open the FIFA Match Predictor and sign in.</li>
            <li>
              Click <strong>Import my picks</strong>. It brings your picks back here so you can check them.
            </li>
          </ol>
          <.escape_hatch />
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

        <%!-- MOBILE: per-round copy-paste --%>
        <div :if={@platform == "mobile" and @step == :paste}>
          <p class="mb-2">
            Step {@current_round} of 3 — let's get your <strong>Round {@current_round}</strong> picks.
          </p>
          <ol class="list-decimal ml-5 mb-4 space-y-2">
            <li>
              <a
                href={"https://play.fifa.com/api/en/match-predictor/prediction/show/#{@current_round}"}
                target="_blank"
                rel="noopener"
                class="link link-primary font-semibold"
              >
                Tap here to open your Round {@current_round} picks
              </a>
            </li>
            <li>
              Press and hold the text, choose <strong>Select all</strong>, then <strong>Copy</strong>.
              <%!-- [screenshot: android long-press -> Select all -> Copy] --%>
            </li>
            <li>Come back here and paste it into the box below.</li>
          </ol>
          <.paste_form round={@current_round} />
          <.escape_hatch />
        </div>

        <%!-- SHARED: preview --%>
        <div :if={@step == :preview}>
          <p :if={@booster_unmatched} class="alert alert-warning mb-4">
            Your booster is on a match we couldn't find — saving this will leave you without a
            booster here. Fix it on FIFA, or carry on knowing that.
          </p>

          <p class="mb-2 font-semibold">
            <%= if @platform == "mobile", do: "Round #{@current_round}: ", else: "" %>This will save these {length(@matched)} picks:
          </p>
          <ul class="mb-4">
            <li :for={m <- @matched}>
              {m.team1} {m.home_goals}–{m.away_goals} {m.team2}{if m.booster, do: " ⚡"}
            </li>
          </ul>

          <div :if={@unmatched != []} class="mb-4">
            <p class="font-semibold">We couldn't match these:</p>
            <ul>
              <li :for={u <- @unmatched}>{reason_text(u.reason)}</li>
            </ul>
          </div>

          <button
            :if={@platform == "mobile" and @matched != []}
            class="btn btn-primary"
            phx-click="confirm_round"
          >
            Save Round {@current_round}
          </button>
          <button
            :if={@platform == "mobile" and @matched == []}
            class="btn"
            phx-click="skip_round"
          >
            Nothing to save here — continue
          </button>

          <button
            :if={@platform == "desktop"}
            class="btn btn-primary"
            phx-click="confirm"
            disabled={@matched == []}
          >
            Confirm import
          </button>
        </div>

        <%!-- SHARED: done --%>
        <div :if={@step == :done}>
          <p class="alert alert-success">
            Your picks are in ✅ {@summary.imported} saved{if @summary.errors > 0,
              do: " (#{@summary.errors} we couldn't save)"}.
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
        placeholder="Paste your Round {@round} picks here"
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
```

> ⚠️ Detail that will bite if missed: the `placeholder="Paste your Round {@round} picks here"`
> uses the `@round` assign passed to `paste_form`, so keep the `round={@current_round}` attribute
> on `<.paste_form />`. The module is complete and balanced as written — the final single `end`
> (after the `reason_text/1` clauses) closes `defmodule`; do not add or remove one.

- [ ] **Step 4: Run the import LiveView tests**

Run: `mix test test/predictex_web/live/import_live_test.exs`
Expected: PASS (all mobile + desktop tests, including the tab-discard regression).

- [ ] **Step 5: Compile clean and run the whole suite**

Run: `mix compile --warnings-as-errors && mix test`
Expected: full suite green (was 275 tests; now higher with the additions). If any OTHER test
referenced the old `/import` paste-row-array behaviour, fix it to set a UA via
`Plug.Conn.put_req_header(conn, "user-agent", "...")` and use the right flow.

- [ ] **Step 6: Commit**

```bash
git add lib/predictex_web/live/import_live.ex test/predictex_web/live/import_live_test.exs
git commit -m "feat(4ar): platform-aware /import — mobile per-round paste, desktop bookmarklet, jargon purge, escape hatch"
```

---

## Task 4: Format, final gate, and issue bookkeeping

**Files:** none (verification + tracking).

- [ ] **Step 1: Format**

Run: `mix format`

- [ ] **Step 2: Full quality gate**

Run: `mix compile --warnings-as-errors && mix format --check-formatted && mix test`
Expected: clean compile, formatted, all tests pass.

- [ ] **Step 3: Manual smoke (operator, real session)**

Start the app (`mix phx.server`), log in, visit `/import`:
- Resize the browser narrow / use device emulation with a mobile UA → confirm the **mobile**
  per-round flow renders ("Step 1 of 3", a "Tap here to open your Round 1 picks" link, a paste
  box) with no "bookmarklet/JSON/console" wording.
- Desktop UA → confirm the **"Import my picks"** button + 3 steps render, no console-fallback line.
- Optionally paste a real Round-1 envelope from your phone test and confirm the preview + save.

- [ ] **Step 4: Capture screenshots into the `[screenshot: …]` slot**

From a live FIFA session on Android, capture the long-press → Select all → Copy gesture and drop
it where the `<%!-- [screenshot: …] --%>` comment sits (static asset under `priv/static/images/`
referenced from the mobile step). This is operator work; leave the comment as the marker if not
yet captured.

- [ ] **Step 5: Update beads**

```bash
bd update predictex-4ar --notes="IMPLEMENTED group-stage mum-proof import: platform plug, mobile per-round envelope paste (DB-durable per round, survives tab discard), desktop bookmarklet relabelled, jargon purged, screenshot->admin escape hatch. Screenshots + iOS Shortcut + OCR still deferred."
bd close predictex-4ar --reason="Group-stage mum-proof import flow shipped per spec/plan 2026-06-16; iOS Shortcut, OCR, and illustrative screenshots tracked as follow-ups."
```

> Only `bd close` once the operator confirms the manual smoke and is happy — per the rule that
> the human decides production-readiness. If leaving open, run only the `bd update`.

- [ ] **Step 6: File the deferred follow-ups (if not already tracked)**

```bash
bd create --title="iOS Shortcut import path (Run JavaScript on Web Page)" --type=feature --priority=3 --description="Smoother iPhone import via a Share-Sheet Shortcut that runs the same in-session fetch. Needs an iPhone-owning group member to validate the full cold-start (enable-scripts toggle + per-domain prompt). Enhancement over the copy-paste floor."
bd create --title="OCR/vision parse of FIFA screenshot to cut admin toil" --type=feature --priority=4 --description="On the screenshot->admin escape hatch, vision-parse the screenshot into the existing preview/confirm flow to remove manual admin entry. Preview gate catches misreads."
```

---

## Self-Review (completed during authoring)

- **Spec coverage:** platform-aware flow (Task 3) ✓; desktop relabel + console-line removal (Task 3) ✓; mobile progressive per-round copy-paste (Task 3) ✓; per-round DB write / tab-discard survival (Task 3 impl + regression test) ✓; raw-envelope paste via `rows_from_envelope/2` (Task 2) ✓; jargon purge with assertions both UAs (Task 3 tests) ✓; escape hatch (Task 3 `escape_hatch/1`) ✓; confirmation reword (Task 3 `:done`) ✓; UA disconnected-mount gotcha handled via session plug (Task 1) ✓; group-stage only / knockout deferred (`@last_group_round 3`, `out_of_scope` copy) ✓; pre-build gesture check (top of plan) ✓; deferrals filed (Task 4) ✓.
- **Open spec questions resolved in the plan:** default platform = `:mobile` (Task 1); escape-hatch routing = plain "send it to the group admin" copy, no live contact link in v1 (Task 3) — the WhatsApp deep link is an optional later polish, not built here.
- **Type/name consistency:** `rows_from_envelope/2`, `confirm_round`, `skip_round`, `advance/2`, `write_matched/1`, `paste_form` `round` attr, `escape_hatch/1`, `@last_group_round` — all defined and referenced consistently across tasks.
- **Placeholder scan:** no TBD/TODO; the only intentional marker is the `[screenshot: …]` HEEx comment, explicitly an operator capture step (Task 4 Step 4).
