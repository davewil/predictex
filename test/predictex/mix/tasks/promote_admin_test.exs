defmodule Mix.Tasks.Predictex.PromoteAdminTest do
  use Predictex.DataCase, async: true
  import Predictex.AccountsFixtures

  test "promotes a player by email" do
    player = player_fixture()
    Mix.Tasks.Predictex.PromoteAdmin.promote(player.email)
    assert Predictex.Accounts.get_player!(player.id).is_admin
  end

  test "raises for an unknown email" do
    assert_raise RuntimeError, fn ->
      Mix.Tasks.Predictex.PromoteAdmin.promote("nobody@example.com")
    end
  end
end
