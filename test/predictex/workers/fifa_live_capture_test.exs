defmodule Predictex.Workers.FifaLiveCaptureTest do
  use Predictex.DataCase, async: true
  use Oban.Testing, repo: Predictex.Repo

  alias Predictex.Spike
  alias Predictex.Workers.FifaLiveCapture, as: Capture

  defp put_fetch(fun) do
    Application.put_env(:predictex, :fifa_capture_fetch_fun, fun)
    on_exit(fn -> Application.delete_env(:predictex, :fifa_capture_fetch_fun) end)
  end

  defp iso(offset_secs),
    do: DateTime.utc_now() |> DateTime.add(offset_secs) |> DateTime.to_iso8601()

  defp args(overrides) do
    Map.merge(
      %{
        "match_id" => "400021502",
        "comp" => "17",
        "season" => "285023",
        "stage" => "289273",
        "start_at" => iso(-60),
        "end_at" => iso(3600),
        "interval" => 30
      },
      overrides
    )
  end

  describe "decide/4 (pure scheduling)" do
    @win_start ~U[2026-06-17 16:50:00Z]
    @win_end ~U[2026-06-17 19:50:00Z]

    test "stops at/after the window end" do
      assert :stop = Capture.decide(~U[2026-06-17 19:50:00Z], @win_start, @win_end, 30)
      assert :stop = Capture.decide(~U[2026-06-17 20:30:00Z], @win_start, @win_end, 30)
    end

    test "waits before the window, rescheduling at the start" do
      assert {:wait, 3000} = Capture.decide(~U[2026-06-17 16:00:00Z], @win_start, @win_end, 30)
    end

    test "captures inside the window and reschedules after the interval" do
      assert {:capture, 30} = Capture.decide(~U[2026-06-17 17:30:00Z], @win_start, @win_end, 30)
    end
  end

  describe "perform/1" do
    test "inside the window: persists both endpoints and reschedules itself" do
      put_fetch(fn url ->
        if String.ends_with?(url, "/now") do
          {:ok, 200, %{"Results" => []}}
        else
          {:ok, 200, %{"IdMatch" => "400021502", "MatchStatus" => 3, "HomeTeamScore" => 1}}
        end
      end)

      assert :ok = perform_job(Capture, args(%{}))

      caps = Spike.list_captures("400021502")
      assert length(caps) == 2
      assert caps |> Enum.map(& &1.endpoint) |> Enum.sort() == ["detail", "now"]

      detail = Enum.find(caps, &(&1.endpoint == "detail"))
      assert detail.http_status == 200
      assert detail.body["MatchStatus"] == 3
      assert detail.url =~ "/live/football/17/285023/289273/400021502"

      assert_enqueued(worker: Capture)
    end

    test "a fetch error is recorded as an error row and the chain still reschedules" do
      put_fetch(fn _url -> {:error, :timeout} end)

      assert :ok = perform_job(Capture, args(%{"match_id" => "err"}))

      caps = Spike.list_captures("err")
      assert length(caps) == 2
      assert Enum.all?(caps, &(&1.error == ":timeout"))
      assert Enum.all?(caps, &is_nil(&1.http_status))
      assert_enqueued(worker: Capture)
    end

    test "after the window: captures nothing and does not reschedule" do
      put_fetch(fn _ -> flunk("must not fetch after the window closes") end)

      assert :ok =
               perform_job(
                 Capture,
                 args(%{"match_id" => "done", "start_at" => iso(-7200), "end_at" => iso(-3600)})
               )

      assert Spike.list_captures("done") == []
      refute_enqueued(worker: Capture)
    end
  end
end
