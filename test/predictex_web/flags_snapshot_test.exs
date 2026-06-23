defmodule PredictexWeb.FlagsSnapshotTest do
  @moduledoc """
  Data-contract regression for `PredictexWeb.Flags` against a frozen snapshot of the
  openfootball 2026 feed's team-name list (predictex-c9s).

  WHY: `Flags` is keyed on the exact strings the live feed emits for `.team1`/`.team2`.
  CI can't reach the live feed, so coverage can silently rot — when a WC2026 placeholder
  ("1A", "W73") resolves to a real nation the map doesn't cover, that team renders ⚽ in
  prod and nothing catches it. This test stands in for the fetch-and-diff CI can't run.

  The snapshot lives at `test/support/fixtures/openfootball/team_names_2026.txt` — the
  distinct `team1`/`team2` set from the feed, frozen 2026-06-23 (48 real nations + the
  bracket placeholders still unresolved at that date). Regenerate it (and re-check
  coverage) with:

      curl -fsSL https://raw.githubusercontent.com/openfootball/worldcup.json/master/2026/worldcup.json \\
        | jq -r '.matches[] | .team1, .team2' | LC_ALL=C sort -u \\
        > test/support/fixtures/openfootball/team_names_2026.txt

  If a regenerated snapshot makes this test fail, a newly-resolved nation needs a
  `PredictexWeb.Flags` entry (or a stale/misspelled key needs fixing).
  """
  use ExUnit.Case, async: true

  alias PredictexWeb.Flags

  # openfootball bracket placeholders, not real nations: group-position slots ("1A",
  # "2B"), third-place combos ("3A/B/C/D/F"), and knockout winner/loser slots ("W73",
  # "L101"). They intentionally fall back to ⚽ until the feed resolves them. No real
  # nation name starts with a digit or with W/L followed by a digit.
  @placeholder ~r{^[0-9]|^[WL][0-9]}

  @snapshot Path.expand("../support/fixtures/openfootball/team_names_2026.txt", __DIR__)

  defp snapshot_names do
    @snapshot
    |> File.read!()
    |> String.split("\n", trim: true)
  end

  # {placeholders, real_nations}
  defp partition_names do
    Enum.split_with(snapshot_names(), &Regex.match?(@placeholder, &1))
  end

  test "the snapshot fixture exists and lists more than the 48 nations (placeholders too)" do
    names = snapshot_names()

    assert length(names) > 48,
           "snapshot looks empty or stale (#{length(names)} names) — regenerate it"
  end

  test "Flags covers every real nation in the feed snapshot — none falls back to ⚽" do
    {_placeholders, nations} = partition_names()

    uncovered = Enum.filter(nations, &(Flags.flag(&1) == "⚽"))

    assert uncovered == [],
           "openfootball feed nations with no flag (would render ⚽ in prod): " <>
             inspect(uncovered)
  end

  test "Flags has no entries beyond the feed's nations (closed 48-team set, no stale keys)" do
    {_placeholders, nations} = partition_names()

    stale = Flags.known() -- nations

    assert stale == [],
           "Flags maps nations absent from the feed snapshot — stale or misspelled: " <>
             inspect(stale)
  end

  test "every feed placeholder falls back to ⚽ (no accidental real-nation match)" do
    {placeholders, _nations} = partition_names()

    mismatched = Enum.filter(placeholders, &(Flags.flag(&1) != "⚽"))

    assert mismatched == [],
           "feed placeholders that unexpectedly map to a flag: " <> inspect(mismatched)
  end
end
