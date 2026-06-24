defmodule PredictexWeb.PredictexComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import PredictexWeb.PredictexComponents

  describe "fixture_card/1 scoring breakdown (predictex-4ez)" do
    defp completed_fx(overrides) do
      base = %{
        fixture: %{
          id: 1,
          team1: "Mexico",
          team2: "Poland",
          kickoff_at: ~U[2026-06-15 12:00:00Z],
          home_goals: 2,
          away_goals: 1,
          is_live: false,
          live_minute: nil,
          live_home_goals: nil,
          live_away_goals: nil
        },
        prediction: %{
          home_goals: 2,
          away_goals: 1,
          first_scorer_side: nil,
          first_scorer_player: nil
        },
        status: :completed,
        locked?: true,
        points: 30,
        breakdown: [
          %{label: "Outcome", pts: 10, tone: "success"},
          %{label: "Exact", pts: 5, tone: "accent"}
        ],
        risky_pct: nil,
        booster?: false,
        exact?: true
      }

      Map.merge(base, overrides)
    end

    test "renders each breakdown chip and the headline points" do
      html = render_component(&fixture_card/1, fx: completed_fx(%{}), stage: :group)

      assert html =~ "Outcome"
      assert html =~ "+10"
      assert html =~ "Exact"
      assert html =~ "+30"
    end

    test "shows a ×2 reconciliation badge on a boosted fixture so chips and headline agree" do
      fx = completed_fx(%{booster?: true, points: 60})
      html = render_component(&fixture_card/1, fx: fx, stage: :group)

      assert html =~ "×2"
      assert html =~ "+60"
    end

    test "renders the risky-pick banner with the backing percentage when risky fired" do
      fx =
        completed_fx(%{
          risky_pct: 12,
          breakdown: [
            %{label: "Outcome", pts: 10, tone: "success"},
            %{label: "Risky", pts: 10, tone: "accent"}
          ]
        })

      html = render_component(&fixture_card/1, fx: fx, stage: :group)

      assert html =~ "Risky pick paid off"
      assert html =~ "only 12% backed it"
    end

    test "no breakdown chips or banner before the fixture is completed" do
      fx =
        completed_fx(%{
          status: :scheduled,
          points: nil,
          breakdown: nil,
          exact?: false,
          fixture: %{
            id: 1,
            team1: "Mexico",
            team2: "Poland",
            kickoff_at: ~U[2026-06-15 12:00:00Z],
            home_goals: nil,
            away_goals: nil,
            is_live: false,
            live_minute: nil,
            live_home_goals: nil,
            live_away_goals: nil
          }
        })

      html = render_component(&fixture_card/1, fx: fx, stage: :group)

      refute html =~ "Risky pick paid off"
      refute html =~ "Outcome"
    end
  end

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
