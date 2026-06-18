defmodule PredictexWeb.TimeZoneTest do
  use ExUnit.Case, async: true

  alias PredictexWeb.TimeZone

  # A bare socket is not connected, so on_mount takes the disconnected (session) path.
  # The connect-param path needs a live websocket and is exercised JS-side, not here.
  defp socket, do: %Phoenix.LiveView.Socket{}

  describe "on_mount :assign_tz (disconnected / session path)" do
    test "assigns the tz from the session when present" do
      {:cont, socket} =
        TimeZone.on_mount(:assign_tz, %{}, %{"tz" => "America/New_York"}, socket())

      assert socket.assigns.tz == "America/New_York"
    end

    test "falls back to Etc/UTC when the session has no tz" do
      {:cont, socket} = TimeZone.on_mount(:assign_tz, %{}, %{}, socket())

      assert socket.assigns.tz == "Etc/UTC"
    end
  end
end
