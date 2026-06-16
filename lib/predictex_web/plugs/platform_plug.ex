defmodule PredictexWeb.PlatformPlug do
  @moduledoc """
  Classifies the request as `"mobile"` or `"desktop"` from the User-Agent and stores it in the
  session as `:platform`, so LiveViews can pick the right flow on BOTH the disconnected
  (static) and connected (websocket) mount — the session is available to both, whereas
  `connect_info` is nil on the first static render. Defaults to `"mobile"` when the UA is absent:
  the harder-to-misuse path and the majority of the audience. The value is stored as a string
  for cross-store safety.
  """
  import Plug.Conn

  @mobile ~r/Mobi|Android|iPhone|iPad|iPod/i

  def init(opts), do: opts

  def call(conn, _opts) do
    platform =
      case get_req_header(conn, "user-agent") do
        [ua | _] -> if Regex.match?(@mobile, ua), do: "mobile", else: "desktop"
        [] -> "mobile"
      end

    put_session(conn, :platform, platform)
  end
end
