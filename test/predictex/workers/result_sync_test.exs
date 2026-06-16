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

  defp restore_result_sync_fun do
    Application.put_env(:predictex, :result_sync_fun, fn ->
      %{rounds: 0, fixtures_ok: 0, fixtures_error: 0, source: "stub"}
    end)
  end
end
