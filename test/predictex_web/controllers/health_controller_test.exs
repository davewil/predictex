defmodule PredictexWeb.HealthControllerTest do
  use PredictexWeb.ConnCase, async: true

  test "GET /health returns ok", %{conn: conn} do
    conn = get(conn, ~p"/health")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end
end
