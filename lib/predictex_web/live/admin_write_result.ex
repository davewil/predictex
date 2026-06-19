defmodule PredictexWeb.AdminWriteResult do
  @moduledoc """
  Shared `{:ok, _}` / `{:error, _}` → reload + flash handling for the admin LiveViews
  (predictex-r90).

  The three admin write surfaces (`AdminFixturesLive`, `AdminPlayersLive`,
  `AdminPredictionsLive`) all turn a context call's result into the same UX: on success
  reload the page's data assigns and flash an `:info` message; on failure flash an
  `:error` message and leave the data untouched. Centralizing it here means the
  flash/reload *strategy* lives in one place — change it once, not in three handlers.

  `handle/5` always returns the `{:noreply, socket}` a `handle_event/3` expects.

  Both messages accept a plain string *or* a 1-arity function: pass a function when the
  message depends on the payload (e.g. `&summarize/1` over the `:ok` results) or on the
  error reason (e.g. mapping `{:booster_on_blank, _}` to its specific copy).
  """
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Phoenix.LiveView.Socket

  @type msg :: String.t() | (term() -> String.t())

  @doc """
  Resolve a write `result` into `{:noreply, socket}`.

    * `reload` — `(socket -> socket)`, run only on `{:ok, _}` to refresh data assigns.
    * `ok_msg` — the `:info` flash; a string, or a fn of the `:ok` payload.
    * `error_msg` — the `:error` flash; a string, or a fn of the `:error` reason.
  """
  @spec handle(
          Socket.t(),
          {:ok, term()} | {:error, term()},
          (Socket.t() -> Socket.t()),
          msg(),
          msg()
        ) :: {:noreply, Socket.t()}
  def handle(socket, result, reload, ok_msg, error_msg)
      when is_function(reload, 1) do
    case result do
      {:ok, payload} ->
        {:noreply, socket |> reload.() |> put_flash(:info, resolve(ok_msg, payload))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, resolve(error_msg, reason))}
    end
  end

  defp resolve(msg, _arg) when is_binary(msg), do: msg
  defp resolve(fun, arg) when is_function(fun, 1), do: fun.(arg)
end
