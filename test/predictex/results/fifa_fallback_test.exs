defmodule Predictex.Results.FifaFallbackTest do
  use ExUnit.Case, async: true

  alias Predictex.Results.FifaFallback

  defp group_fixture(status \\ :scheduled),
    do: %{round: %{stage: :group}, status: status}

  defp finished_body(h, a),
    do: %{"MatchStatus" => 0, "HomeTeam" => %{"Score" => h}, "AwayTeam" => %{"Score" => a}}

  test "settles an unsettled group fixture from a finished frame" do
    assert {:ok, %{status: :completed, home_goals: 3, away_goals: 0}} =
             FifaFallback.settle_attrs(group_fixture(), finished_body(3, 0))
  end

  test "skips when the match is not finished (MatchStatus 3)" do
    body = %{"MatchStatus" => 3, "HomeTeam" => %{"Score" => 1}, "AwayTeam" => %{"Score" => 0}}
    assert :skip = FifaFallback.settle_attrs(group_fixture(), body)
  end

  test "skips when a score is missing" do
    body = %{"MatchStatus" => 0, "HomeTeam" => %{"Score" => 1}, "AwayTeam" => %{}}
    assert :skip = FifaFallback.settle_attrs(group_fixture(), body)
  end

  test "skips a knockout fixture (ET/penalties out of scope)" do
    ko = %{round: %{stage: :knockout}, status: :scheduled}
    assert :skip = FifaFallback.settle_attrs(ko, finished_body(1, 0))
  end

  test "skips an already-completed fixture" do
    assert :skip = FifaFallback.settle_attrs(group_fixture(:completed), finished_body(3, 0))
  end

  test "skips when there is no captured body" do
    assert :skip = FifaFallback.settle_attrs(group_fixture(), nil)
  end
end
