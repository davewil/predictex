defmodule Predictex.AccountsTest do
  use Predictex.DataCase

  alias Predictex.Accounts

  import Predictex.AccountsFixtures
  alias Predictex.Accounts.{Player, PlayerToken}

  describe "get_player_by_email/1" do
    test "does not return the player if the email does not exist" do
      refute Accounts.get_player_by_email("unknown@example.com")
    end

    test "returns the player if the email exists" do
      %{id: id} = player = player_fixture()
      assert %Player{id: ^id} = Accounts.get_player_by_email(player.email)
    end
  end

  describe "get_player_by_email_and_password/2" do
    test "does not return the player if the email does not exist" do
      refute Accounts.get_player_by_email_and_password("unknown@example.com", "hello world!")
    end

    test "does not return the player if the password is not valid" do
      player = player_fixture() |> set_password()
      refute Accounts.get_player_by_email_and_password(player.email, "invalid")
    end

    test "returns the player if the email and password are valid" do
      %{id: id} = player = player_fixture() |> set_password()

      assert %Player{id: ^id} =
               Accounts.get_player_by_email_and_password(player.email, valid_player_password())
    end
  end

  describe "get_player!/1" do
    test "raises if id is invalid" do
      assert_raise Ecto.NoResultsError, fn ->
        Accounts.get_player!(-1)
      end
    end

    test "returns the player with the given id" do
      %{id: id} = player = player_fixture()
      assert %Player{id: ^id} = Accounts.get_player!(player.id)
    end
  end

  describe "register_player/1" do
    test "requires email to be set" do
      {:error, changeset} = Accounts.register_player(%{})

      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates email when given" do
      {:error, changeset} = Accounts.register_player(%{email: "not valid"})

      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)
    end

    test "validates maximum values for email for security" do
      too_long = String.duplicate("db", 100)
      {:error, changeset} = Accounts.register_player(%{email: too_long})
      assert "should be at most 160 character(s)" in errors_on(changeset).email
    end

    test "validates email uniqueness" do
      %{email: email} = player_fixture()
      {:error, changeset} = Accounts.register_player(%{email: email})
      assert "has already been taken" in errors_on(changeset).email

      # Now try with the uppercased email too, to check that email case is ignored.
      {:error, changeset} = Accounts.register_player(%{email: String.upcase(email)})
      assert "has already been taken" in errors_on(changeset).email
    end

    test "registers players with a password and auto-confirms them" do
      email = unique_player_email()
      attrs = valid_player_attributes(email: email)
      {:ok, player} = Accounts.register_player(attrs)
      assert player.email == email
      assert player.display_name == attrs.display_name
      # password is hashed and the virtual field is cleared
      assert is_binary(player.hashed_password)
      assert is_nil(player.password)
      # registration auto-confirms the account
      assert player.confirmed_at
    end

    test "requires a password and a display name to be set" do
      {:error, changeset} = Accounts.register_player(%{email: unique_player_email()})

      assert %{
               password: ["can't be blank"],
               display_name: ["can't be blank"]
             } = errors_on(changeset)
    end
  end

  describe "sudo_mode?/2" do
    test "validates the authenticated_at time" do
      now = DateTime.utc_now()

      assert Accounts.sudo_mode?(%Player{authenticated_at: DateTime.utc_now()})
      assert Accounts.sudo_mode?(%Player{authenticated_at: DateTime.add(now, -19, :minute)})
      refute Accounts.sudo_mode?(%Player{authenticated_at: DateTime.add(now, -21, :minute)})

      # minute override
      refute Accounts.sudo_mode?(
               %Player{authenticated_at: DateTime.add(now, -11, :minute)},
               -10
             )

      # not authenticated
      refute Accounts.sudo_mode?(%Player{})
    end
  end

  describe "change_player_email/3" do
    test "returns a player changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_player_email(%Player{})
      assert changeset.required == [:email]
    end
  end

  describe "deliver_player_update_email_instructions/3" do
    setup do
      %{player: player_fixture()}
    end

    test "sends token through notification", %{player: player} do
      token =
        extract_player_token(fn url ->
          Accounts.deliver_player_update_email_instructions(player, "current@example.com", url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert player_token = Repo.get_by(PlayerToken, token: :crypto.hash(:sha256, token))
      assert player_token.player_id == player.id
      assert player_token.sent_to == player.email
      assert player_token.context == "change:current@example.com"
    end
  end

  describe "update_player_email/2" do
    setup do
      player = unconfirmed_player_fixture()
      email = unique_player_email()

      token =
        extract_player_token(fn url ->
          Accounts.deliver_player_update_email_instructions(
            %{player | email: email},
            player.email,
            url
          )
        end)

      %{player: player, token: token, email: email}
    end

    test "updates the email with a valid token", %{player: player, token: token, email: email} do
      assert {:ok, %{email: ^email}} = Accounts.update_player_email(player, token)
      changed_player = Repo.get!(Player, player.id)
      assert changed_player.email != player.email
      assert changed_player.email == email
      refute Repo.get_by(PlayerToken, player_id: player.id)
    end

    test "does not update email with invalid token", %{player: player} do
      assert Accounts.update_player_email(player, "oops") ==
               {:error, :transaction_aborted}

      assert Repo.get!(Player, player.id).email == player.email
      assert Repo.get_by(PlayerToken, player_id: player.id)
    end

    test "does not update email if player email changed", %{player: player, token: token} do
      assert Accounts.update_player_email(%{player | email: "current@example.com"}, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(Player, player.id).email == player.email
      assert Repo.get_by(PlayerToken, player_id: player.id)
    end

    test "does not update email if token expired", %{player: player, token: token} do
      {1, nil} = Repo.update_all(PlayerToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])

      assert Accounts.update_player_email(player, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(Player, player.id).email == player.email
      assert Repo.get_by(PlayerToken, player_id: player.id)
    end
  end

  describe "change_player_password/3" do
    test "returns a player changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_player_password(%Player{})
      assert changeset.required == [:password]
    end

    test "allows fields to be set" do
      changeset =
        Accounts.change_player_password(
          %Player{},
          %{
            "password" => "new valid password"
          },
          hash_password: false
        )

      assert changeset.valid?
      assert get_change(changeset, :password) == "new valid password"
      assert is_nil(get_change(changeset, :hashed_password))
    end
  end

  describe "update_player_password/2" do
    setup do
      %{player: player_fixture()}
    end

    test "validates password", %{player: player} do
      {:error, changeset} =
        Accounts.update_player_password(player, %{
          password: "not valid",
          password_confirmation: "another"
        })

      assert %{
               password: ["should be at least 12 character(s)"],
               password_confirmation: ["does not match password"]
             } = errors_on(changeset)
    end

    test "validates maximum values for password for security", %{player: player} do
      too_long = String.duplicate("db", 100)

      {:error, changeset} =
        Accounts.update_player_password(player, %{password: too_long})

      assert "should be at most 72 character(s)" in errors_on(changeset).password
    end

    test "updates the password", %{player: player} do
      {:ok, {player, expired_tokens}} =
        Accounts.update_player_password(player, %{
          password: "new valid password"
        })

      assert expired_tokens == []
      assert is_nil(player.password)
      assert Accounts.get_player_by_email_and_password(player.email, "new valid password")
    end

    test "deletes all tokens for the given player", %{player: player} do
      _ = Accounts.generate_player_session_token(player)

      {:ok, {_, _}} =
        Accounts.update_player_password(player, %{
          password: "new valid password"
        })

      refute Repo.get_by(PlayerToken, player_id: player.id)
    end
  end

  describe "generate_player_session_token/1" do
    setup do
      %{player: player_fixture()}
    end

    test "generates a token", %{player: player} do
      token = Accounts.generate_player_session_token(player)
      assert player_token = Repo.get_by(PlayerToken, token: token)
      assert player_token.context == "session"
      assert player_token.authenticated_at != nil

      # Creating the same token for another player should fail
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%PlayerToken{
          token: player_token.token,
          player_id: player_fixture().id,
          context: "session"
        })
      end
    end

    test "duplicates the authenticated_at of given player in new token", %{player: player} do
      player = %{player | authenticated_at: DateTime.add(DateTime.utc_now(:second), -3600)}
      token = Accounts.generate_player_session_token(player)
      assert player_token = Repo.get_by(PlayerToken, token: token)
      assert player_token.authenticated_at == player.authenticated_at
      assert DateTime.compare(player_token.inserted_at, player.authenticated_at) == :gt
    end
  end

  describe "get_player_by_session_token/1" do
    setup do
      player = player_fixture()
      token = Accounts.generate_player_session_token(player)
      %{player: player, token: token}
    end

    test "returns player by token", %{player: player, token: token} do
      assert {session_player, token_inserted_at} = Accounts.get_player_by_session_token(token)
      assert session_player.id == player.id
      assert session_player.authenticated_at != nil
      assert token_inserted_at != nil
    end

    test "does not return player for invalid token" do
      refute Accounts.get_player_by_session_token("oops")
    end

    test "does not return player for expired token", %{token: token} do
      dt = ~N[2020-01-01 00:00:00]
      {1, nil} = Repo.update_all(PlayerToken, set: [inserted_at: dt, authenticated_at: dt])
      refute Accounts.get_player_by_session_token(token)
    end
  end

  describe "get_player_by_magic_link_token/1" do
    setup do
      player = player_fixture()
      {encoded_token, _hashed_token} = generate_player_magic_link_token(player)
      %{player: player, token: encoded_token}
    end

    test "returns player by token", %{player: player, token: token} do
      assert session_player = Accounts.get_player_by_magic_link_token(token)
      assert session_player.id == player.id
    end

    test "does not return player for invalid token" do
      refute Accounts.get_player_by_magic_link_token("oops")
    end

    test "does not return player for expired token", %{token: token} do
      {1, nil} = Repo.update_all(PlayerToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])
      refute Accounts.get_player_by_magic_link_token(token)
    end
  end

  describe "login_player_by_magic_link/1" do
    test "confirms player and expires tokens" do
      player = unconfirmed_player_fixture()
      refute player.confirmed_at
      {encoded_token, hashed_token} = generate_player_magic_link_token(player)

      assert {:ok, {player, [%{token: ^hashed_token}]}} =
               Accounts.login_player_by_magic_link(encoded_token)

      assert player.confirmed_at
    end

    test "returns player and (deleted) token for confirmed player" do
      player = player_fixture()
      assert player.confirmed_at
      {encoded_token, _hashed_token} = generate_player_magic_link_token(player)
      assert {:ok, {^player, []}} = Accounts.login_player_by_magic_link(encoded_token)
      # one time use only
      assert {:error, :not_found} = Accounts.login_player_by_magic_link(encoded_token)
    end

    test "raises when unconfirmed player has password set" do
      player = unconfirmed_player_fixture()
      {1, nil} = Repo.update_all(Player, set: [hashed_password: "hashed"])
      {encoded_token, _hashed_token} = generate_player_magic_link_token(player)

      assert_raise RuntimeError, ~r/magic link log in is not allowed/, fn ->
        Accounts.login_player_by_magic_link(encoded_token)
      end
    end
  end

  describe "delete_player_session_token/1" do
    test "deletes the token" do
      player = player_fixture()
      token = Accounts.generate_player_session_token(player)
      assert Accounts.delete_player_session_token(token) == :ok
      refute Accounts.get_player_by_session_token(token)
    end
  end

  describe "deliver_login_instructions/2" do
    setup do
      %{player: unconfirmed_player_fixture()}
    end

    test "sends token through notification", %{player: player} do
      token =
        extract_player_token(fn url ->
          Accounts.deliver_login_instructions(player, url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert player_token = Repo.get_by(PlayerToken, token: :crypto.hash(:sha256, token))
      assert player_token.player_id == player.id
      assert player_token.sent_to == player.email
      assert player_token.context == "login"
    end
  end

  describe "inspect/2 for the Player module" do
    test "does not include password" do
      refute inspect(%Player{password: "123456"}) =~ "password: \"123456\""
    end
  end

  describe "set_player_admin/2" do
    test "promotes and demotes by id, returning {:ok, player}" do
      player = player_fixture()
      refute player.is_admin

      assert {:ok, promoted} = Accounts.set_player_admin(player.id, true)
      assert promoted.is_admin

      assert {:ok, demoted} = Accounts.set_player_admin(player.id, false)
      refute demoted.is_admin
    end
  end
end
