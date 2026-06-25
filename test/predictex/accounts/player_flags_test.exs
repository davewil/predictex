defmodule Predictex.Accounts.PlayerFlagsTest do
  @moduledoc """
  The FunWithFlags.Group resolution for Player that backs the staged native-KO rollout
  (predictex-5q6): a flag enabled `for_group: :admins` must resolve to admins only. The
  LiveView gate (my_predictions_live_test) exercises this end-to-end; this pins the
  protocol contract directly, which the LiveView tests can't cleanly isolate.

  **async: false on purpose.** The for_group describe enables `:native_ko_entry` in the
  global FunWithFlags ETS cache. `:native_ko_entry` is also toggled by MyPredictionsLiveTest
  (async). A sync module runs isolated from the async phase, so the shared-cache writes here
  can't race a concurrent read there — the global-state caveat ExUnit warns about.
  """
  use Predictex.DataCase, async: false

  import Predictex.AccountsFixtures

  describe "FunWithFlags.Group impl for Player" do
    test "an admin is in the :admins group; a regular player is not" do
      admin = admin_player_fixture()
      member = player_fixture()

      assert FunWithFlags.Group.in?(admin, :admins)
      refute FunWithFlags.Group.in?(member, :admins)

      # Group names normalize to strings inside FunWithFlags — match both forms.
      assert FunWithFlags.Group.in?(admin, "admins")
      refute FunWithFlags.Group.in?(member, "admins")

      # No spurious membership in unrelated groups.
      refute FunWithFlags.Group.in?(admin, :everyone)
    end
  end

  describe "a flag enabled for_group: :admins resolves per player" do
    setup do
      # Enable for the :admins group only; flush the ETS cache after so the enabled gate
      # can't leak into later tests (compile-env-safe isolation — see config/test.exs).
      {:ok, _} = FunWithFlags.enable(:native_ko_entry, for_group: :admins)
      on_exit(fn -> FunWithFlags.Store.Cache.flush() end)
      :ok
    end

    test "enabled? is true for an admin, false for a regular player, false globally" do
      admin = admin_player_fixture()
      member = player_fixture()

      assert FunWithFlags.enabled?(:native_ko_entry, for: admin)
      refute FunWithFlags.enabled?(:native_ko_entry, for: member)
      refute FunWithFlags.enabled?(:native_ko_entry)
    end
  end
end
