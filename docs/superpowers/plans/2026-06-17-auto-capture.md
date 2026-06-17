# Auto-Start Unified Live Capture — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One scheduled producer worker polls each live match, publishing every FIFA snapshot to PubSub; independent subscribers record it (event source) and drive the buzz — auto-started from the fixture schedule so no match is ever missed.

**Architecture:** Producer/subscriber over `Phoenix.PubSub`. A self-rescheduling Oban worker (the producer), triggered by Oban Cron ~5–10 min before each kickoff, fetches one `/detail` snapshot per in-window fixture and broadcasts `{:snapshot, fixture_id, body, captured_at}` on the `"fifa:snapshots"` topic. Two supervised GenServer subscribers consume it: **Recorder** persists the raw body to `fifa_captures` (the replayable event source), **LiveUpdater** decodes → `live_*` → `{:live_update}` (the buzz). A shared `Predictex.LiveScore` decoder is the single source of the decode/broadcast contract (also consumed by the replay engine, predictex-i1s).

**Tech Stack:** Elixir/Phoenix, Oban 2.19 (+ Cron plugin, unique jobs), Phoenix.PubSub, Ecto/Postgres, Req.

> **Architecture note (PubSub vs inline):** we use real PubSub subscribers per the agreed
> design (predictex-rfm) — it decouples the producer from consumers and lets future
> observers (flourishes predictex-3oo, analytics, a live replay-tee) just subscribe.
> The accepted trade-off (predictex-4ya): PubSub is in-memory/at-most-once, so a downed
> subscriber can drop one snapshot — a negligible gap at 30s cadence that self-corrects.
> The leaner alternative (producer calls the two handlers inline) was rejected for
> extensibility; revisit only via predictex-4ya.

## Global Constraints

- **Two-writer rule:** only `LiveUpdater` writes fixture columns, and ONLY `is_live` +
  `live_home_goals`/`live_away_goals`/`live_minute`. Never `status`/`home_goals`/`away_goals`/
  `first_scorer_*` (openfootball/`ResultSync` owns those).
- **Each commit stays deployable** — the live buzz (live on prod) must keep working at every
  task boundary. The producer keeps writing `live_*` directly until the cutover task (Task 5)
  moves that to `LiveUpdater`.
- **Capture is ungated**; only the buzz UI is gated on `FunWithFlags.enabled?(:live_buzz)`
  (unchanged — gating lives in the LiveViews, not here).
- Keep the existing table name `fifa_captures` (no migration).
- "Live" detection = FIFA `MatchStatus` **not in `[0, 1]`** (confirmed `3` = in-play).
- Injectable fetch via `Application.get_env(:predictex, :live_score_fetch_fun, &fetch/1)`
  (existing pattern); Oban tests via `Oban.Testing` + `perform_job/2`; `use Predictex.DataCase`.
- Gate before deploy: `mix format --check-formatted && mix compile --warnings-as-errors && mix test`.

## File Structure

- `lib/predictex/live_score.ex` — NEW. Shared decoder: `attrs_from_body/1`, `apply_to_fixture/2`.
- `lib/predictex/workers/live_score_sync.ex` — MODIFY → becomes the publishing producer.
- `lib/predictex/capture.ex` + `lib/predictex/capture/snapshot.ex` — rename of `Predictex.Spike`
  / `Predictex.Spike.FifaCapture` to a permanent home (same table).
- `lib/predictex/capture/recorder.ex` — NEW. Subscriber GenServer: persists snapshots.
- `lib/predictex/live/updater.ex` — NEW. Subscriber GenServer: drives `live_*` + buzz broadcast.
- `lib/predictex/application.ex` — MODIFY. Supervise the two subscribers.
- `config/config.exs` — MODIFY. Add the Cron entry for the producer.
- `lib/predictex/workers/fifa_live_capture.ex` — DELETE (retired; folded into producer + Recorder).
- Tests alongside each under `test/predictex/**`.

---

### Task 1: Shared decoder `Predictex.LiveScore`

**Files:**
- Create: `lib/predictex/live_score.ex`
- Modify: `lib/predictex/workers/live_score_sync.ex`
- Test: `test/predictex/live_score_test.exs`

**Interfaces:**
- Produces:
  - `LiveScore.attrs_from_body(body, fixture) :: %{is_live, live_home_goals, live_away_goals, live_minute}`
    — pure decode of a FIFA `/detail` body; `fixture` supplies the nil-score fallback.
  - `LiveScore.apply_to_fixture(fixture, attrs) :: :ok | {:error, Ecto.Changeset.t()}`
    — writes via `Tournament.update_fixture/2` (only the four `live_*`/`is_live` keys) and
    broadcasts `{:live_update, fixture.id}` on `"fixture:#{id}"` when a live value changed.

- [ ] **Step 1: Write the failing test**

```elixir
# test/predictex/live_score_test.exs
defmodule Predictex.LiveScoreTest do
  use Predictex.DataCase, async: true

  alias Predictex.LiveScore
  alias Predictex.Tournament
  alias Predictex.Tournament.Fixture

  defp fixture(attrs \\ %{}) do
    {:ok, r} = Tournament.create_round(%{name: "R1", stage: :group, ordinal: 1})

    {:ok, f} =
      Tournament.create_fixture(
        Map.merge(
          %{external_ref: "x", team1: "A", team2: "B", round_id: r.id, kickoff_at: ~U[2026-06-17 17:00:00Z]},
          attrs
        )
      )

    f
  end

  test "attrs_from_body/2 decodes a live body (MatchStatus 3, nested score)" do
    f = fixture()
    body = %{"MatchStatus" => 3, "MatchTime" => "23'", "HomeTeam" => %{"Score" => 1}, "AwayTeam" => %{"Score" => 0}}
    assert %{is_live: true, live_home_goals: 1, live_away_goals: 0, live_minute: "23'"} = LiveScore.attrs_from_body(body, f)
  end

  test "attrs_from_body/2 marks finished (0) / upcoming (1) as not live" do
    f = fixture()
    assert %{is_live: false} = LiveScore.attrs_from_body(%{"MatchStatus" => 0}, f)
    assert %{is_live: false} = LiveScore.attrs_from_body(%{"MatchStatus" => 1}, f)
  end

  test "attrs_from_body/2 keeps the existing score when the body omits it" do
    f = fixture(%{live_home_goals: 2, live_away_goals: 1})
    body = %{"MatchStatus" => 3, "MatchTime" => "70'"}
    assert %{live_home_goals: 2, live_away_goals: 1} = LiveScore.attrs_from_body(body, f)
  end

  test "apply_to_fixture/2 writes only live_* and broadcasts on change" do
    f = fixture(%{status: :scheduled})
    Phoenix.PubSub.subscribe(Predictex.PubSub, "fixture:#{f.id}")
    attrs = %{is_live: true, live_home_goals: 1, live_away_goals: 0, live_minute: "10'"}

    assert :ok = LiveScore.apply_to_fixture(f, attrs)
    assert_received {:live_update, _id}

    reloaded = Tournament.get_fixture!(f.id)
    assert %Fixture{is_live: true, live_home_goals: 1, status: :scheduled} = reloaded
  end

  test "apply_to_fixture/2 does not broadcast when nothing changed" do
    f = fixture(%{is_live: true, live_home_goals: 1, live_away_goals: 0, live_minute: "10'"})
    Phoenix.PubSub.subscribe(Predictex.PubSub, "fixture:#{f.id}")
    attrs = %{is_live: true, live_home_goals: 1, live_away_goals: 0, live_minute: "10'"}

    assert :ok = LiveScore.apply_to_fixture(f, attrs)
    refute_received {:live_update, _id}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/predictex/live_score_test.exs`
Expected: FAIL (module/functions missing).

- [ ] **Step 3: Implement the shared decoder**

```elixir
# lib/predictex/live_score.ex
defmodule Predictex.LiveScore do
  @moduledoc """
  Shared decode + apply contract for FIFA live `/detail` snapshots (predictex-rfm).

  Used by `Workers.LiveScoreSync` (the producer's LiveUpdater path) and the replay
  engine (predictex-i1s) so the body→`live_*`→broadcast logic lives in exactly one place.
  Writes ONLY the additive `live_*`/`is_live` columns — never openfootball's result columns.
  """
  require Logger
  alias Predictex.Tournament

  @doc "Decode a FIFA `/detail` body into `live_*` attrs. `fixture` supplies the nil-score fallback."
  def attrs_from_body(body, fixture) when is_map(body) do
    %{
      is_live: body["MatchStatus"] not in [0, 1],
      live_home_goals: get_in(body, ["HomeTeam", "Score"]) || fixture.live_home_goals,
      live_away_goals: get_in(body, ["AwayTeam", "Score"]) || fixture.live_away_goals,
      live_minute: body["MatchTime"]
    }
  end

  @doc "Write the `live_*` attrs to `fixture` and broadcast `{:live_update, id}` when a live value changed."
  def apply_to_fixture(fixture, attrs) do
    changed? =
      fixture.is_live != attrs.is_live or
        fixture.live_home_goals != attrs.live_home_goals or
        fixture.live_away_goals != attrs.live_away_goals or
        fixture.live_minute != attrs.live_minute

    case Tournament.update_fixture(fixture, attrs) do
      {:ok, _} ->
        if changed?,
          do:
            Phoenix.PubSub.broadcast(
              Predictex.PubSub,
              "fixture:#{fixture.id}",
              {:live_update, fixture.id}
            )

        :ok

      {:error, cs} = err ->
        Logger.warning("live score update failed for #{fixture.id}: #{inspect(cs.errors)}")
        err
    end
  end
end
```

- [ ] **Step 4: Refactor `LiveScoreSync` to use the shared decoder**

In `lib/predictex/workers/live_score_sync.ex`, replace the private `apply_update/2` body so it
delegates (keep `sync_one/1` calling it):

```elixir
  defp apply_update(f, body) do
    Predictex.LiveScore.apply_to_fixture(f, Predictex.LiveScore.attrs_from_body(body, f))
  end
```

Remove the now-unused `get_in`/change-detection code from the worker (it moved into `LiveScore`).

- [ ] **Step 5: Run both test files**

Run: `mix test test/predictex/live_score_test.exs test/predictex/workers/live_score_sync_test.exs`
Expected: PASS (new decoder tests + existing worker tests still green). Then `mix format`.

- [ ] **Step 6: Commit**

```bash
git add lib/predictex/live_score.ex lib/predictex/workers/live_score_sync.ex test/predictex/live_score_test.exs
git commit -m "refactor(live): extract shared LiveScore decoder (predictex-rfm)"
```

---

### Task 2: Promote the capture store `Predictex.Spike` → `Predictex.Capture`

**Files:**
- Create: `lib/predictex/capture.ex`, `lib/predictex/capture/snapshot.ex`
- Delete: `lib/predictex/spike.ex`, `lib/predictex/spike/fifa_capture.ex`
- Modify: `lib/predictex/workers/fifa_live_capture.ex` (alias swap — still alive until Task 7),
  and any test referencing `Predictex.Spike`.
- Test: `test/predictex/capture_test.exs` (move/rename from any existing spike test)

**Interfaces:**
- Produces: `Capture.record_snapshot(attrs) :: {:ok, Snapshot.t()} | {:error, cs}`,
  `Capture.list_snapshots(match_id) :: [Snapshot.t()]`, `Capture.summary(match_id)`.
  Schema `Predictex.Capture.Snapshot` maps the SAME table `"fifa_captures"` (no migration).

- [ ] **Step 1: Write the failing test**

```elixir
# test/predictex/capture_test.exs
defmodule Predictex.CaptureTest do
  use Predictex.DataCase, async: true
  alias Predictex.Capture

  test "record_snapshot/1 persists and list_snapshots/1 reads back in time order" do
    {:ok, _} =
      Capture.record_snapshot(%{
        captured_at: ~U[2026-06-17 17:00:00Z], endpoint: "detail",
        url: "u", match_id: "m1", http_status: 200, body: %{"MatchStatus" => 3}
      })

    assert [%{match_id: "m1", endpoint: "detail"}] = Capture.list_snapshots("m1")
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/predictex/capture_test.exs`
Expected: FAIL (module missing).

- [ ] **Step 3: Create `Capture.Snapshot` (copy the schema, new module name, same table)**

```elixir
# lib/predictex/capture/snapshot.ex
defmodule Predictex.Capture.Snapshot do
  @moduledoc "One raw FIFA v3 API response captured during a match window (predictex-rfm)."
  use Ecto.Schema
  import Ecto.Changeset

  schema "fifa_captures" do
    field :captured_at, :utc_datetime_usec
    field :endpoint, :string
    field :url, :string
    field :match_id, :string
    field :http_status, :integer
    field :body, :map
    field :error, :string
  end

  @fields [:captured_at, :endpoint, :url, :match_id, :http_status, :body, :error]

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, @fields)
    |> validate_required([:captured_at, :endpoint, :url, :match_id])
  end
end
```

- [ ] **Step 4: Create `Predictex.Capture`** — move `record_capture`→`record_snapshot`,
`list_captures`→`list_snapshots`, and `summary/1` + `analyze/1` + `format/1` verbatim from the old
`Predictex.Spike` module, swapping the alias to `Predictex.Capture.Snapshot`. (Read `lib/predictex/spike.ex`
in full and carry over the analysis helpers unchanged except for the alias and the two renamed function names.)

- [ ] **Step 5: Update the one live caller, then delete the spike modules**

In `lib/predictex/workers/fifa_live_capture.ex` swap `alias Predictex.Spike` →
`alias Predictex.Capture` and `Spike.record_capture(` → `Capture.record_snapshot(`. Update any test
that referenced `Predictex.Spike`. Then:

```bash
git rm lib/predictex/spike.ex lib/predictex/spike/fifa_capture.ex
```

- [ ] **Step 6: Run + commit**

Run: `mix test test/predictex/capture_test.exs test/predictex/workers/fifa_live_capture_test.exs && mix compile --warnings-as-errors`
Expected: PASS, clean. Then `mix format`.

```bash
git add lib/predictex/capture.ex lib/predictex/capture/snapshot.ex lib/predictex/workers/fifa_live_capture.ex test/predictex/capture_test.exs
git commit -m "refactor(capture): promote Spike capture store to permanent Predictex.Capture (predictex-rfm)"
```

---

### Task 3: `Capture.Recorder` subscriber

**Files:**
- Create: `lib/predictex/capture/recorder.ex`
- Modify: `lib/predictex/application.ex`
- Test: `test/predictex/capture/recorder_test.exs`

**Interfaces:**
- Consumes: PubSub topic `"fifa:snapshots"`, messages `{:snapshot, fixture_id, body, captured_at, match_id, url}`.
- Produces: rows in `fifa_captures` via `Capture.record_snapshot/1`.

- [ ] **Step 1: Write the failing test**

```elixir
# test/predictex/capture/recorder_test.exs
defmodule Predictex.Capture.RecorderTest do
  use Predictex.DataCase, async: false
  alias Predictex.{Capture, Capture.Recorder}

  test "records a broadcast snapshot to fifa_captures" do
    start_supervised!(Recorder)
    msg = {:snapshot, 1, %{"MatchStatus" => 3}, ~U[2026-06-17 17:00:00Z], "m1", "http://u"}
    Phoenix.PubSub.broadcast(Predictex.PubSub, "fifa:snapshots", msg)

    # the GenServer handles async; wait for the row
    Process.sleep(50)
    assert [%{match_id: "m1", endpoint: "detail", http_status: 200}] = Capture.list_snapshots("m1")
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/predictex/capture/recorder_test.exs`
Expected: FAIL (module missing).

- [ ] **Step 3: Implement the subscriber**

```elixir
# lib/predictex/capture/recorder.ex
defmodule Predictex.Capture.Recorder do
  @moduledoc """
  Subscriber that persists every published FIFA snapshot to `fifa_captures` — the
  replayable event source (predictex-rfm, predictex-i1s). Independent of the buzz path.
  """
  use GenServer
  require Logger
  alias Predictex.Capture

  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @impl true
  def init(:ok) do
    Phoenix.PubSub.subscribe(Predictex.PubSub, "fifa:snapshots")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:snapshot, _fixture_id, body, captured_at, match_id, url}, state) do
    attrs = %{
      captured_at: captured_at,
      endpoint: "detail",
      url: url,
      match_id: match_id,
      http_status: 200,
      body: body,
      error: nil
    }

    case Capture.record_snapshot(attrs) do
      {:ok, _} -> :ok
      {:error, cs} -> Logger.error("snapshot persist failed (#{match_id}): #{inspect(cs.errors)}")
    end

    {:noreply, state}
  end
end
```

- [ ] **Step 4: Supervise it (config-gated so it does NOT run in test)**

The subscribers must NOT auto-start in the test env: an always-on instance would collide on the
registered name with the tests' own `start_supervised!` and would react to broadcasts from unrelated
tests. Gate them.

In `lib/predictex/application.ex`, append a gated helper to the children list (the subscribers go
*after* `{Phoenix.PubSub, name: Predictex.PubSub}` so PubSub is up first):

```elixir
# in start/2: children = [ ...existing... ] ++ capture_subscribers()

defp capture_subscribers do
  if Application.get_env(:predictex, :start_capture_subscribers, true) do
    [Predictex.Capture.Recorder]
  else
    []
  end
end
```

In `config/test.exs` add: `config :predictex, start_capture_subscribers: false`

(The Recorder/Updater tests are `async: false`, so `Predictex.DataCase`'s sandbox runs in shared
mode and the supervised GenServer can use the test's DB connection.)

- [ ] **Step 5: Run + commit**

Run: `mix test test/predictex/capture/recorder_test.exs`
Expected: PASS. Then `mix format`.

```bash
git add lib/predictex/capture/recorder.ex lib/predictex/application.ex test/predictex/capture/recorder_test.exs
git commit -m "feat(capture): Recorder subscriber persists snapshots to the event source (predictex-rfm)"
```

---

### Task 4: `Live.Updater` subscriber

**Files:**
- Create: `lib/predictex/live/updater.ex`
- Modify: `lib/predictex/application.ex`
- Test: `test/predictex/live/updater_test.exs`

**Interfaces:**
- Consumes: PubSub `"fifa:snapshots"` `{:snapshot, fixture_id, body, ...}`; `LiveScore.attrs_from_body/2`
  + `LiveScore.apply_to_fixture/2`; `Tournament.get_fixture!/1`.
- Produces: `live_*` writes + `{:live_update, id}` broadcasts (the buzz).

- [ ] **Step 1: Write the failing test**

```elixir
# test/predictex/live/updater_test.exs
defmodule Predictex.Live.UpdaterTest do
  use Predictex.DataCase, async: false
  alias Predictex.{Tournament, Live.Updater}

  test "applies a broadcast snapshot to the fixture's live_* and broadcasts" do
    {:ok, r} = Tournament.create_round(%{name: "R1", stage: :group, ordinal: 1})
    {:ok, f} = Tournament.create_fixture(%{external_ref: "x", team1: "A", team2: "B", round_id: r.id, kickoff_at: ~U[2026-06-17 17:00:00Z]})

    start_supervised!(Updater)
    Phoenix.PubSub.subscribe(Predictex.PubSub, "fixture:#{f.id}")

    body = %{"MatchStatus" => 3, "MatchTime" => "12'", "HomeTeam" => %{"Score" => 1}, "AwayTeam" => %{"Score" => 0}}
    Phoenix.PubSub.broadcast(Predictex.PubSub, "fifa:snapshots", {:snapshot, f.id, body, ~U[2026-06-17 17:12:00Z], "m1", "u"})

    assert_receive {:live_update, _id}, 500
    assert %{is_live: true, live_home_goals: 1} = Tournament.get_fixture!(f.id)
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/predictex/live/updater_test.exs`
Expected: FAIL.

- [ ] **Step 3: Implement the subscriber**

```elixir
# lib/predictex/live/updater.ex
defmodule Predictex.Live.Updater do
  @moduledoc """
  Subscriber that turns published FIFA snapshots into the live buzz: decode → write
  `live_*` → broadcast `{:live_update}` (predictex-rfm). Independent of the Recorder.
  """
  use GenServer
  require Logger
  alias Predictex.{LiveScore, Tournament}

  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @impl true
  def init(:ok) do
    Phoenix.PubSub.subscribe(Predictex.PubSub, "fifa:snapshots")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:snapshot, fixture_id, body, _captured_at, _match_id, _url}, state) do
    fixture = Tournament.get_fixture!(fixture_id)
    LiveScore.apply_to_fixture(fixture, LiveScore.attrs_from_body(body, fixture))
    {:noreply, state}
  rescue
    e ->
      Logger.error("live updater crashed for fixture #{inspect(fixture_id)}: #{Exception.message(e)}")
      {:noreply, state}
  end
end
```

- [ ] **Step 4: Supervise it** — add `Predictex.Live.Updater` to the `capture_subscribers/0` list
created in Task 3, so both subscribers share the same env gate:

```elixir
defp capture_subscribers do
  if Application.get_env(:predictex, :start_capture_subscribers, true) do
    [Predictex.Capture.Recorder, Predictex.Live.Updater]
  else
    []
  end
end
```

- [ ] **Step 5: Run + commit**

Run: `mix test test/predictex/live/updater_test.exs`
Expected: PASS. Then `mix format`.

```bash
git add lib/predictex/live/updater.ex lib/predictex/application.ex test/predictex/live/updater_test.exs
git commit -m "feat(live): Updater subscriber drives the buzz from published snapshots (predictex-rfm)"
```

---

### Task 5: Cut the producer over to publishing (pre-kickoff window)

**Files:**
- Modify: `lib/predictex/workers/live_score_sync.ex`
- Test: `test/predictex/workers/live_score_sync_test.exs` (rewrite assertions to the publish path)

**Interfaces:**
- Produces: per in-window fixture, `Phoenix.PubSub.broadcast(Predictex.PubSub, "fifa:snapshots",
  {:snapshot, fixture.id, body, captured_at, fixture.fifa_match_id, url})`. The worker no longer
  writes `live_*` directly (LiveUpdater does, via the subscription).

**This is the cutover** — after this commit the buzz is driven by the subscriber path. The Recorder
and Updater (Tasks 3–4) must already be supervised.

- [ ] **Step 1: Rewrite the worker test for the publish path**

```elixir
# test/predictex/workers/live_score_sync_test.exs — replace the body-asserting tests with:
defmodule Predictex.Workers.LiveScoreSyncTest do
  use Predictex.DataCase, async: true
  use Oban.Testing, repo: Predictex.Repo
  alias Predictex.Tournament
  alias Predictex.Workers.LiveScoreSync, as: Live

  defp put_fetch(fun) do
    Application.put_env(:predictex, :live_score_fetch_fun, fun)
    on_exit(fn -> Application.delete_env(:predictex, :live_score_fetch_fun) end)
  end

  defp window_fixture do
    {:ok, r} = Tournament.create_round(%{name: "R1", stage: :group, ordinal: 1})
    # kickoff 1 min ago: inside [kickoff-10min, kickoff+150min]
    {:ok, f} =
      Tournament.create_fixture(%{
        external_ref: "x", team1: "A", team2: "B", round_id: r.id,
        kickoff_at: DateTime.add(DateTime.utc_now(), -60), fifa_match_id: "400021502"
      })
    f
  end

  test "publishes a snapshot per in-window fixture and reschedules" do
    f = window_fixture()
    Phoenix.PubSub.subscribe(Predictex.PubSub, "fifa:snapshots")
    put_fetch(fn _url -> {:ok, 200, %{"MatchStatus" => 3, "HomeTeam" => %{"Score" => 1}, "AwayTeam" => %{"Score" => 0}, "MatchTime" => "5'"}} end)

    assert :ok = perform_job(Live, %{})
    assert_received {:snapshot, fixture_id, %{"MatchStatus" => 3}, _at, "400021502", _url}
    assert fixture_id == f.id
    assert_enqueued(worker: Live)
  end

  test "captures the pre-kickoff window (kickoff in 5 min)" do
    {:ok, r} = Tournament.create_round(%{name: "R1", stage: :group, ordinal: 1})
    {:ok, f} = Tournament.create_fixture(%{external_ref: "y", team1: "A", team2: "B", round_id: r.id, kickoff_at: DateTime.add(DateTime.utc_now(), 300), fifa_match_id: "999"})
    Phoenix.PubSub.subscribe(Predictex.PubSub, "fifa:snapshots")
    put_fetch(fn _url -> {:ok, 200, %{"MatchStatus" => 1}} end)

    assert :ok = perform_job(Live, %{})
    assert_received {:snapshot, fixture_id, _body, _at, "999", _url}
    assert fixture_id == f.id
  end

  test "no in-window fixtures → no broadcast, no reschedule" do
    {:ok, r} = Tournament.create_round(%{name: "R1", stage: :group, ordinal: 1})
    {:ok, _} = Tournament.create_fixture(%{external_ref: "z", team1: "A", team2: "B", round_id: r.id, kickoff_at: DateTime.add(DateTime.utc_now(), 3600), fifa_match_id: "111"})

    assert :ok = perform_job(Live, %{})
    refute_enqueued(worker: Live)
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/predictex/workers/live_score_sync_test.exs`
Expected: FAIL (worker still writes/doesn't publish).

- [ ] **Step 3: Rewrite the worker to publish, with a pre-kickoff window**

Replace the body of `lib/predictex/workers/live_score_sync.ex` from `perform/1` down with:

```elixir
  @pre_min 10
  @post_min 150
  @interval 30

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()
    fixtures = in_window(now)
    Enum.each(fixtures, &publish(&1, now))
    if fixtures != [], do: reschedule()
    :ok
  end

  defp in_window(now) do
    from_t = DateTime.add(now, -@post_min * 60)
    to_t = DateTime.add(now, @pre_min * 60)

    Repo.all(
      from f in Fixture,
        where: not is_nil(f.fifa_match_id) and f.kickoff_at <= ^to_t and f.kickoff_at >= ^from_t
    )
  end

  defp publish(f, now) do
    url = "#{@detail_base}/#{f.fifa_match_id}"

    case fetch_fun().(url) do
      {:ok, 200, body} when is_map(body) ->
        Phoenix.PubSub.broadcast(
          Predictex.PubSub,
          "fifa:snapshots",
          {:snapshot, f.id, body, now, f.fifa_match_id, url}
        )

      other ->
        Logger.warning("live snapshot fetch #{f.fifa_match_id}: #{inspect(other)}")
    end
  end

  defp reschedule, do: %{} |> new(schedule_in: @interval) |> Oban.insert()
```

Delete the old `sync_one/1`, `apply_update/2`, the `window_min`/`interval` arg handling, and the
`start/1` override-merge (replace `start/1` with `def start, do: %{} |> new() |> Oban.insert()`).
Keep `@detail_base`, `fetch_fun/0`, `fetch/1`. Update the moduledoc to describe the producer role.

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/predictex/workers/live_score_sync_test.exs test/predictex/live_score_test.exs`
Expected: PASS. Then `mix format`.

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/workers/live_score_sync.ex test/predictex/workers/live_score_sync_test.exs
git commit -m "feat(capture): producer publishes snapshots; pre-kickoff window (predictex-rfm)"
```

---

### Task 6: Auto-start via Oban Cron + uniqueness

**Files:**
- Modify: `config/config.exs` (Cron entry), `lib/predictex/workers/live_score_sync.ex` (unique opt)
- Test: `test/predictex/workers/live_score_sync_test.exs` (add a uniqueness assertion)

**Interfaces:**
- Produces: a Cron entry `{"*/5 * * * *", Predictex.Workers.LiveScoreSync}` and
  `unique: [period: 40, states: [:available, :scheduled, :executing]]` on the worker so the
  every-5-min Cron tick is a no-op while the 30s self-reschedule chain is active.

- [ ] **Step 1: Add the uniqueness test**

```elixir
# add to test/predictex/workers/live_score_sync_test.exs
  test "is unique so the cron trigger can't stack with the self-reschedule chain" do
    f = window_fixture()
    put_fetch(fn _url -> {:ok, 200, %{"MatchStatus" => 3}} end)
    assert {:ok, _} = Oban.insert(Live.new(%{}))
    # a second identical insert within the unique window is deduped
    assert {:ok, job2} = Oban.insert(Live.new(%{}))
    assert job2.conflict?
    _ = f
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/predictex/workers/live_score_sync_test.exs -k "unique"`
Expected: FAIL (`conflict?` false — no uniqueness yet).

- [ ] **Step 3: Add uniqueness to the worker**

Change the `use Oban.Worker` line in `lib/predictex/workers/live_score_sync.ex` to:

```elixir
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 40, states: [:available, :scheduled, :executing]]
```

- [ ] **Step 4: Add the Cron entry**

In `config/config.exs`, add to the `Oban.Plugins.Cron` `crontab` list:

```elixir
       {"*/5 * * * *", Predictex.Workers.LiveScoreSync},
```

(so the list is ResultSync `*/15`, CohortSync hourly, LiveScoreSync `*/5`).

- [ ] **Step 5: Run to verify it passes**

Run: `mix test test/predictex/workers/live_score_sync_test.exs && mix compile --warnings-as-errors`
Expected: PASS, clean. Then `mix format`.

- [ ] **Step 6: Commit**

```bash
git add config/config.exs lib/predictex/workers/live_score_sync.ex test/predictex/workers/live_score_sync_test.exs
git commit -m "feat(capture): auto-start the producer via Oban Cron, unique to avoid stacking (predictex-rfm)"
```

---

### Task 7: Retire `FifaLiveCapture`

**Files:**
- Delete: `lib/predictex/workers/fifa_live_capture.ex`, `test/predictex/workers/fifa_live_capture_test.exs`
- Modify: any reference (grep first), `config/test.exs` if it stubs `:fifa_capture_fetch_fun`.

**Interfaces:** none produced; this removes the now-redundant spike worker (its job = producer + Recorder).

- [ ] **Step 1: Confirm nothing depends on it**

Run: `grep -rn "FifaLiveCapture\|fifa_capture_fetch_fun" lib config test`
Expected: only the worker, its test, and (maybe) a `config/test.exs` stub.

- [ ] **Step 2: Remove it**

```bash
git rm lib/predictex/workers/fifa_live_capture.ex test/predictex/workers/fifa_live_capture_test.exs
```

Remove any `:fifa_capture_fetch_fun` line from `config/test.exs`.

- [ ] **Step 3: Full gate**

Run: `mix format --check-formatted && mix compile --warnings-as-errors && mix test`
Expected: all pass, no warnings, no references to the deleted module.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore(capture): retire FifaLiveCapture; producer + Recorder replace it (predictex-rfm)"
```

---

## Deploy & verify

1. Tag a `vX.Y.Z` release; CI migrates (none here — additive only) + recreates prod.
2. The Cron arms the producer automatically ~5–10 min before each kickoff; confirm on the next
   fixture that `fifa_captures` gains rows and `/fixtures/:id` goes live with no manual `rpc`.
3. Removes the manual-arm step that lost England v Croatia. Closes the is_live-stuck edge
   (predictex-d17): the window now bounds polling and the chain stops post-window.

## Self-review notes

- Spec coverage: unified capture (Tasks 1–5), event-source persistence (Tasks 2–3), buzz unchanged
  (Tasks 1,4,5), auto-start (Task 6), retire spike (Task 7). Producer/subscriber + PubSub fan-out as
  designed (predictex-rfm); persist-in-producer remains deferred (predictex-4ya).
- Each commit deployable: producer keeps working through Tasks 1–4 (subscribers idle until Task 5
  wires publishing); Task 5 is the atomic cutover after the subscribers are supervised.
- The `match_id` in the snapshot message is `fixture.fifa_match_id` (the FIFA id the captures key on),
  while `fixture_id` is our local id (used by LiveUpdater to load + write). Both travel in the message.
