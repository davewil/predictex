defmodule Predictex.Accounts.Player do
  use Ecto.Schema
  import Ecto.Changeset

  schema "players" do
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :confirmed_at, :utc_datetime
    field :authenticated_at, :utc_datetime, virtual: true
    field :display_name, :string
    field :is_admin, :boolean, default: false

    has_many :predictions, Predictex.Predictions.Prediction

    timestamps(type: :utc_datetime)
  end

  @doc """
  A player changeset for registering or changing the email.

  It requires the email to change otherwise an error is added.

  ## Options

    * `:validate_unique` - Set to false if you don't want to validate the
      uniqueness of the email, useful when displaying live validations.
      Defaults to `true`.
  """
  def email_changeset(player, attrs, opts \\ []) do
    player
    |> cast(attrs, [:email])
    |> validate_email(opts)
  end

  defp validate_email(changeset, opts) do
    changeset =
      changeset
      |> validate_required([:email])
      |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
        message: "must have the @ sign and no spaces"
      )
      |> validate_length(:email, max: 160)

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:email, Predictex.Repo)
      |> unique_constraint(:email)
      |> validate_email_changed()
    else
      changeset
    end
  end

  defp validate_email_changed(changeset) do
    if get_field(changeset, :email) && get_change(changeset, :email) == nil do
      add_error(changeset, :email, "did not change")
    else
      changeset
    end
  end

  @doc """
  A player changeset for registering with email, password, and display name.

  Casts email, password and display_name, requires the display name, and reuses
  the email and password validations (so the password is hashed by default).

  ## Options

  Accepts the same options as `email_changeset/3` and `password_changeset/3`,
  i.e. `:validate_unique` and `:hash_password`.
  """
  def registration_changeset(player, attrs, opts \\ []) do
    player
    |> cast(attrs, [:email, :password, :display_name])
    |> validate_required([:display_name])
    |> validate_email(opts)
    |> validate_password(opts)
  end

  @doc """
  A player changeset for changing the password.

  It is important to validate the length of the password, as long passwords may
  be very expensive to hash for certain algorithms.

  ## Options

    * `:hash_password` - Hashes the password so it can be stored securely
      in the database and ensures the password field is cleared to prevent
      leaks in the logs. If password hashing is not needed and clearing the
      password field is not desired (like when using this changeset for
      validations on a LiveView form), this option can be set to `false`.
      Defaults to `true`.
  """
  def password_changeset(player, attrs, opts \\ []) do
    player
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password(opts)
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 12, max: 72)
    # Examples of additional password validation:
    # |> validate_format(:password, ~r/[a-z]/, message: "at least one lower case character")
    # |> validate_format(:password, ~r/[A-Z]/, message: "at least one upper case character")
    # |> validate_format(:password, ~r/[!?@#$%^&*_0-9]/, message: "at least one digit or punctuation character")
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      # If using Bcrypt, then further validate it is at most 72 bytes long
      |> validate_length(:password, max: 72, count: :bytes)
      # Hashing could be done with `Ecto.Changeset.prepare_changes/2`, but that
      # would keep the database transaction open longer and hurt performance.
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc """
  Confirms the account by setting `confirmed_at`.
  """
  def confirm_changeset(player) do
    now = DateTime.utc_now(:second)
    change(player, confirmed_at: now)
  end

  @doc """
  Verifies the password.

  If there is no player or the player doesn't have a password, we call
  `Bcrypt.no_user_verify/0` to avoid timing attacks.
  """
  def valid_password?(%Predictex.Accounts.Player{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end
end

defimpl FunWithFlags.Group, for: Predictex.Accounts.Player do
  @moduledoc """
  Group membership for feature-flag gating. Lets a flag be enabled for the `:admins`
  group (`FunWithFlags.enable(flag, for_group: :admins)`) so it resolves per player off
  `is_admin` — the basis for the "enable for admins first" staged rollout of
  `:native_ko_entry` (predictex-5q6) without a redeploy.

  FunWithFlags normalizes group names to strings internally, so the clause matches both
  `:admins` and `"admins"`. Every other (player, group) pair is a non-member.
  """
  def in?(%{is_admin: true}, group) when group in [:admins, "admins"], do: true
  def in?(_player, _group), do: false
end
