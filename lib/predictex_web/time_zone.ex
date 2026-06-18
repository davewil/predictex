defmodule PredictexWeb.TimeZone do
  @moduledoc """
  on_mount hook that assigns the viewer's IANA timezone as `:tz` (predictex-fb5).

  On the connected mount the browser sends its real tz as the `_tz` connect param
  (set by app.js). On the disconnected (static) mount there is no socket yet, so we
  fall back to the `tz` session value the router's `put_tz` plug copied from the
  cookie. Failing both, `"Etc/UTC"` — the safe, label-free default.
  """
  import Phoenix.LiveView, only: [connected?: 1, get_connect_params: 1]
  import Phoenix.Component, only: [assign: 3]

  def on_mount(:assign_tz, _params, session, socket) do
    tz =
      if connected?(socket) do
        get_connect_params(socket)["_tz"]
      else
        session["tz"]
      end

    {:cont, assign(socket, :tz, tz || "Etc/UTC")}
  end
end
