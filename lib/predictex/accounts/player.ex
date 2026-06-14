defmodule Predictex.Accounts.Player do
  @moduledoc """
  A league participant. Minimal for now (`display_name`, optional `email`, `is_admin`);
  full authentication is layered in during the web phase and reconciled then.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "players" do
    field :email, :string
    field :display_name, :string
    field :is_admin, :boolean, default: false

    has_many :predictions, Predictex.Predictions.Prediction

    timestamps()
  end

  @doc false
  def changeset(player, attrs) do
    player
    |> cast(attrs, [:email, :display_name, :is_admin])
    |> validate_required([:display_name])
    |> update_change(:email, &normalize_email/1)
    |> validate_email()
    |> unique_constraint(:email)
  end

  # Optional field: only validate the format when an email is actually present.
  defp validate_email(changeset) do
    validate_change(changeset, :email, fn :email, email ->
      if is_binary(email) and not Regex.match?(~r/^[^@\s]+@[^@\s]+$/, email) do
        [email: "must be a valid email"]
      else
        []
      end
    end)
  end

  defp normalize_email(nil), do: nil
  defp normalize_email(email), do: email |> String.trim() |> String.downcase()
end
