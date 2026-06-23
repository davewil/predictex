defmodule Predictex.Workers.ResultSyncTest do
  use Predictex.DataCase, async: true
  use Oban.Testing, repo: Predictex.Repo

  alias Predictex.Workers.ResultSync

  test "perform returns :ok when the sync source returns a summary" do
    # config/test.exs sets :result_sync_fun to a stub summary map
    assert :ok = perform_job(ResultSync, %{})
  end

  test "perform returns {:error, reason} when the sync source fails (so Oban retries)" do
    Application.put_env(:predictex, :result_sync_fun, fn -> {:error, :boom} end)
    on_exit(fn -> restore_result_sync_fun() end)

    assert {:error, :boom} = perform_job(ResultSync, %{})
  end

  test "perform runs the FIFA fallback after the openfootball sync" do
    test_pid = self()

    Application.put_env(:predictex, :fifa_fallback_fun, fn ->
      send(test_pid, :fallback_ran)
      %{candidates: 0, settled: 0}
    end)

    on_exit(fn ->
      Application.put_env(:predictex, :fifa_fallback_fun, fn -> %{candidates: 0, settled: 0} end)
    end)

    assert :ok = perform_job(ResultSync, %{})
    assert_received :fallback_ran
  end

  test "the FIFA fallback still runs when the openfootball sync fails" do
    test_pid = self()
    Application.put_env(:predictex, :result_sync_fun, fn -> {:error, :boom} end)

    Application.put_env(:predictex, :fifa_fallback_fun, fn ->
      send(test_pid, :fallback_ran)
      %{candidates: 0, settled: 0}
    end)

    on_exit(fn ->
      restore_result_sync_fun()
      Application.put_env(:predictex, :fifa_fallback_fun, fn -> %{candidates: 0, settled: 0} end)
    end)

    assert {:error, :boom} = perform_job(ResultSync, %{})
    assert_received :fallback_ran
  end

  defp restore_result_sync_fun do
    Application.put_env(:predictex, :result_sync_fun, fn ->
      %{rounds: 0, fixtures_ok: 0, fixtures_error: 0, source: "stub"}
    end)
  end
end
