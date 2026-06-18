defmodule PredictexWeb.PredictexComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import PredictexWeb.PredictexComponents

  describe "local_time/1" do
    test "renders a <time> element with ISO8601 datetime, phx-hook, id, and UTC fallback text" do
      dt = ~U[2026-06-18 19:00:00Z]

      html = render_component(&local_time/1, at: dt, id: "kickoff-card-42")

      assert html =~ ~s(datetime="2026-06-18T19:00:00Z")
      assert html =~ ~s(phx-hook="LocalTime")
      assert html =~ ~s(id="kickoff-card-42")
      assert html =~ "UTC"
    end

    test "renders TBC span when at is nil" do
      html = render_component(&local_time/1, at: nil, id: "kickoff-card-99")

      assert html =~ "TBC"
      refute html =~ "<time"
    end
  end
end
