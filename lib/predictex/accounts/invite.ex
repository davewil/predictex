defmodule Predictex.Accounts.Invite do
  @moduledoc "League registration gate: a shared invite code from config."

  @doc "Whether the supplied code matches the configured league invite code."
  def valid?(code) when is_binary(code) and code != "" do
    expected = Application.get_env(:predictex, :league_invite_code) || ""
    Plug.Crypto.secure_compare(code, expected)
  end

  def valid?(_), do: false
end
