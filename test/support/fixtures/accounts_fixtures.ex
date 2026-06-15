defmodule Predictex.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Predictex.Accounts` context.
  """

  import Ecto.Query

  alias Predictex.Accounts
  alias Predictex.Accounts.Scope

  def unique_player_email, do: "player#{System.unique_integer()}@example.com"
  def valid_player_password, do: "hello world!"

  def valid_player_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_player_email(),
      password: valid_player_password(),
      display_name: "Player #{System.unique_integer([:positive])}"
    })
  end

  @doc """
  Builds an unconfirmed player without a password.

  Registration now auto-confirms and requires a password, so `register_player/1`
  can no longer create an unconfirmed account. We insert directly via a minimal
  changeset that casts only `email`/`display_name`, leaving `confirmed_at` and
  `hashed_password` nil — the state the magic-link/confirmation tests rely on.
  """
  def unconfirmed_player_fixture(attrs \\ %{}) do
    attrs = valid_player_attributes(attrs)

    %Predictex.Accounts.Player{}
    |> Ecto.Changeset.cast(attrs, [:email, :display_name])
    |> Ecto.Changeset.validate_required([:email, :display_name])
    |> Predictex.Repo.insert!()
  end

  def player_fixture(attrs \\ %{}) do
    {:ok, player} =
      attrs
      |> valid_player_attributes()
      |> Accounts.register_player()

    player
  end

  def player_scope_fixture do
    player = player_fixture()
    player_scope_fixture(player)
  end

  def player_scope_fixture(player) do
    Scope.for_player(player)
  end

  def set_password(player) do
    {:ok, {player, _expired_tokens}} =
      Accounts.update_player_password(player, %{password: valid_player_password()})

    player
  end

  def extract_player_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    Predictex.Repo.update_all(
      from(t in Accounts.PlayerToken,
        where: t.token == ^token
      ),
      set: [authenticated_at: authenticated_at]
    )
  end

  def generate_player_magic_link_token(player) do
    {encoded_token, player_token} = Accounts.PlayerToken.build_email_token(player, "login")
    Predictex.Repo.insert!(player_token)
    {encoded_token, player_token.token}
  end

  def offset_player_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    Predictex.Repo.update_all(
      from(ut in Accounts.PlayerToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end
end
