defmodule PredictexWeb.TimeHelpersTest do
  use ExUnit.Case, async: true

  alias PredictexWeb.TimeHelpers

  describe "kickoff/2" do
    test "converts summer UTC datetime to BST (Europe/London, UTC+1)" do
      # 2026-06-28 19:00 UTC = 20:00 BST
      dt = ~U[2026-06-28 19:00:00Z]
      assert TimeHelpers.kickoff(dt, "Europe/London") == "Sun 28 Jun · 20:00"
    end

    test "winter Europe/London datetime stays at +0 (GMT, no offset)" do
      # 2026-01-10 14:30 UTC = 14:30 GMT (no offset — proves the tz DB, not a hardcoded +1)
      dt = ~U[2026-01-10 14:30:00Z]
      assert TimeHelpers.kickoff(dt, "Europe/London") == "Sat 10 Jan · 14:30"
    end

    test "Etc/UTC returns the UTC time with no offset and no suffix" do
      dt = ~U[2026-06-28 19:00:00Z]
      assert TimeHelpers.kickoff(dt, "Etc/UTC") == "Sun 28 Jun · 19:00"
    end

    test "unknown/invalid timezone falls back to UTC formatting with ' UTC' suffix" do
      dt = ~U[2026-06-28 19:00:00Z]
      assert TimeHelpers.kickoff(dt, "Not/AZone") == "Sun 28 Jun · 19:00 UTC"
    end

    test "nil tz falls back to UTC formatting with ' UTC' suffix" do
      dt = ~U[2026-06-28 19:00:00Z]
      assert TimeHelpers.kickoff(dt, nil) == "Sun 28 Jun · 19:00 UTC"
    end

    test "nil datetime returns 'TBC'" do
      assert TimeHelpers.kickoff(nil, "Europe/London") == "TBC"
      assert TimeHelpers.kickoff(nil, nil) == "TBC"
    end
  end
end
