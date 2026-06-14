defmodule PredictexWeb.HealthController do
  @moduledoc """
  Liveness endpoint for the reverse proxy (caddy-docker-proxy health checks) and the
  deploy smoke test. Returns `{"status":"ok"}` once the app is serving requests.
  """
  use PredictexWeb, :controller

  def index(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
