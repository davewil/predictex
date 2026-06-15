defmodule Predictex.Accounts.InviteTest do
  use ExUnit.Case, async: true
  alias Predictex.Accounts.Invite

  test "valid?/1 accepts the configured code and rejects others" do
    assert Invite.valid?("test-code")
    refute Invite.valid?("wrong")
    refute Invite.valid?(nil)
    refute Invite.valid?("")
  end
end
