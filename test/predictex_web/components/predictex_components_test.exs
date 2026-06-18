defmodule PredictexWeb.PredictexComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import PredictexWeb.PredictexComponents

  describe "local_time/1" do
    test "renders a <time> element with UTC ISO8601 datetime and server-side local text, no JS hook" do
      dt = ~U[2026-06-18 19:00:00Z]

      html =
        render_component(&local_time/1, at: dt, id: "kickoff-card-42", tz: "America/New_York")

      # datetime stays canonical UTC for machine readers
      assert html =~ ~s(datetime="2026-06-18T19:00:00Z")
      assert html =~ ~s(id="kickoff-card-42")
      # 19:00 UTC shifted to America/New_York (EDT, -04:00) -> 15:00, rendered server-side
      assert html =~ "15:00"
      # the client hook is gone — conversion is now entirely server-side
      refute html =~ "phx-hook"
    end

    test "renders TBC span when at is nil" do
      html = render_component(&local_time/1, at: nil, id: "kickoff-card-99")

      assert html =~ "TBC"
      refute html =~ "<time"
    end
  end
end
