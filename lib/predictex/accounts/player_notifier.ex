defmodule Predictex.Accounts.PlayerNotifier do
  @moduledoc false
  import Swoosh.Email

  alias Predictex.Mailer
  alias Predictex.Accounts.Player

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from({"Predictex", "contact@example.com"})
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver instructions to update a player email.
  """
  def deliver_update_email_instructions(player, url) do
    deliver(player.email, "Update email instructions", """

    ==============================

    Hi #{player.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(player, url) do
    case player do
      %Player{confirmed_at: nil} -> deliver_confirmation_instructions(player, url)
      _ -> deliver_magic_link_instructions(player, url)
    end
  end

  defp deliver_magic_link_instructions(player, url) do
    deliver(player.email, "Log in instructions", """

    ==============================

    Hi #{player.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(player, url) do
    deliver(player.email, "Confirmation instructions", """

    ==============================

    Hi #{player.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """)
  end
end
