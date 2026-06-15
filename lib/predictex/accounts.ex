defmodule Predictex.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Predictex.Repo

  alias Predictex.Accounts.{Player, PlayerToken, PlayerNotifier}

  ## Database getters

  @doc """
  Gets a player by email.

  ## Examples

      iex> get_player_by_email("foo@example.com")
      %Player{}

      iex> get_player_by_email("unknown@example.com")
      nil

  """
  def get_player_by_email(email) when is_binary(email) do
    Repo.get_by(Player, email: email)
  end

  @doc """
  Gets a player by email and password.

  ## Examples

      iex> get_player_by_email_and_password("foo@example.com", "correct_password")
      %Player{}

      iex> get_player_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_player_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    player = Repo.get_by(Player, email: email)
    if Player.valid_password?(player, password), do: player
  end

  @doc """
  Gets a single player.

  Raises `Ecto.NoResultsError` if the Player does not exist.

  ## Examples

      iex> get_player!(123)
      %Player{}

      iex> get_player!(456)
      ** (Ecto.NoResultsError)

  """
  def get_player!(id), do: Repo.get!(Player, id)

  @doc "All players (used by the leaderboard standings)."
  def list_players, do: Repo.all(Player)

  ## Player registration

  @doc """
  Registers a player (email + password + display_name), auto-confirmed.

  Intentionally NOT invite-gated: the public self-registration path gates on the
  league invite code in `PredictexWeb.PlayerLive.Registration`; admin-initiated
  creation (acting on a member's behalf) deliberately bypasses that gate.

  ## Examples

      iex> register_player(%{field: value})
      {:ok, %Player{}}

      iex> register_player(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_player(attrs) do
    %Player{}
    |> Player.registration_changeset(attrs)
    |> Ecto.Changeset.put_change(:confirmed_at, DateTime.utc_now(:second))
    |> Repo.insert()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking player registration changes.

  Used for live form validation; password hashing and email uniqueness checks
  are disabled by default so the form can re-render on every keystroke.

  ## Examples

      iex> change_player_registration(player)
      %Ecto.Changeset{data: %Player{}}

  """
  def change_player_registration(player, attrs \\ %{}) do
    Player.registration_changeset(player, attrs, hash_password: false, validate_unique: false)
  end

  ## Settings

  @doc """
  Checks whether the player is in sudo mode.

  The player is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(player, minutes \\ -20)

  def sudo_mode?(%Player{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_player, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the player email.

  See `Predictex.Accounts.Player.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_player_email(player)
      %Ecto.Changeset{data: %Player{}}

  """
  def change_player_email(player, attrs \\ %{}, opts \\ []) do
    Player.email_changeset(player, attrs, opts)
  end

  @doc """
  Updates the player email using the given token.

  If the token matches, the player email is updated and the token is deleted.
  """
  def update_player_email(player, token) do
    context = "change:#{player.email}"

    Repo.transact(fn ->
      with {:ok, query} <- PlayerToken.verify_change_email_token_query(token, context),
           %PlayerToken{sent_to: email} <- Repo.one(query),
           {:ok, player} <- Repo.update(Player.email_changeset(player, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(PlayerToken, where: [player_id: ^player.id, context: ^context])) do
        {:ok, player}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the player password.

  See `Predictex.Accounts.Player.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_player_password(player)
      %Ecto.Changeset{data: %Player{}}

  """
  def change_player_password(player, attrs \\ %{}, opts \\ []) do
    Player.password_changeset(player, attrs, opts)
  end

  @doc """
  Updates the player password.

  Returns a tuple with the updated player, as well as a list of expired tokens.

  ## Examples

      iex> update_player_password(player, %{password: ...})
      {:ok, {%Player{}, [...]}}

      iex> update_player_password(player, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_player_password(player, attrs) do
    player
    |> Player.password_changeset(attrs)
    |> update_player_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_player_session_token(player) do
    {token, player_token} = PlayerToken.build_session_token(player)
    Repo.insert!(player_token)
    token
  end

  @doc """
  Gets the player with the given signed token.

  If the token is valid `{player, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_player_by_session_token(token) do
    {:ok, query} = PlayerToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the player with the given magic link token.
  """
  def get_player_by_magic_link_token(token) do
    with {:ok, query} <- PlayerToken.verify_magic_link_token_query(token),
         {player, _token} <- Repo.one(query) do
      player
    else
      _ -> nil
    end
  end

  @doc """
  Logs the player in by magic link.

  There are three cases to consider:

  1. The player has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The player has not confirmed their email and no password is set.
     In this case, the player gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The player has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_player_by_magic_link(token) do
    {:ok, query} = PlayerToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%Player{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%Player{confirmed_at: nil} = player, _token} ->
        player
        |> Player.confirm_changeset()
        |> update_player_and_delete_all_tokens()

      {player, token} ->
        Repo.delete!(token)
        {:ok, {player, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given player.

  ## Examples

      iex> deliver_player_update_email_instructions(player, current_email, &url(~p"/players/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_player_update_email_instructions(
        %Player{} = player,
        current_email,
        update_email_url_fun
      )
      when is_function(update_email_url_fun, 1) do
    {encoded_token, player_token} =
      PlayerToken.build_email_token(player, "change:#{current_email}")

    Repo.insert!(player_token)
    PlayerNotifier.deliver_update_email_instructions(player, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given player.
  """
  def deliver_login_instructions(%Player{} = player, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, player_token} = PlayerToken.build_email_token(player, "login")
    Repo.insert!(player_token)
    PlayerNotifier.deliver_login_instructions(player, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_player_session_token(token) do
    Repo.delete_all(from(PlayerToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_player_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, player} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(PlayerToken, player_id: player.id)

        Repo.delete_all(
          from(t in PlayerToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id))
        )

        {:ok, {player, tokens_to_expire}}
      end
    end)
  end
end
