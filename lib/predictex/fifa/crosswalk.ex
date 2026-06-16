defmodule Predictex.Fifa.Crosswalk do
  @moduledoc """
  Pure FIFA <-> Fixture matching authority. Shared by `Fifa.Cohort` (cohort %) and
  `Fifa.Import` (member predictions) so the match identity and the verified name-alias
  table live in exactly one place.

  Match identity is the `{utc_date, unordered team-set}` of a fixture vs a FIFA match
  (`rounds.json` `tournaments[]`). Group stage runs several matches per calendar date, so
  the team-set is part of the key, not a tiebreaker. Home/away is oriented by the
  first-listed-is-home convention (our `team1` == FIFA `homeSquadName`).
  """

  # FIFA -> openfootball normalized-name divergences, derived by diffing the live
  # squads.json vs worldcup.json feeds (the predictex-c9s shared artifact).
  @aliases %{
    "bosnia and herzegovina" => "bosnia & herzegovina",
    "cabo verde" => "cape verde",
    "congo dr" => "dr congo",
    "czechia" => "czech republic",
    "côte d'ivoire" => "ivory coast",
    "ir iran" => "iran",
    "korea republic" => "south korea",
    "türkiye" => "turkey"
  }

  @whitespace ~r/\s+/

  @doc "Index fixtures by their match key for O(1) crosswalk lookup."
  def index_fixtures(fixtures) when is_list(fixtures),
    do: Map.new(fixtures, fn f -> {match_key(f.kickoff_at, f.team1, f.team2), f} end)

  @doc "The `{utc_date, MapSet of normalized names}` identity key."
  def match_key(datetime_or_iso, a, b),
    do: {utc_date(datetime_or_iso), MapSet.new([norm(a), norm(b)])}

  @doc "True when FIFA's home team is our `team1` after alias-normalisation (no swap needed)."
  def home_first?(fifa_home_name, fixture_team1),
    do: norm(fifa_home_name) == norm(fixture_team1)

  @doc "Lowercase, collapse whitespace, then apply the FIFA->openfootball alias."
  def norm(nil), do: ""

  def norm(name) when is_binary(name) do
    n = name |> String.downcase() |> String.trim() |> String.replace(@whitespace, " ")
    Map.get(@aliases, n, n)
  end

  @doc "Returns the UTC `Date` for a `DateTime` struct or an offset ISO8601 string; `nil` otherwise."
  # FIFA `date` is offset-bearing ISO8601 ("...+01:00"); fixture kickoff_at is UTC.
  # Both reduce to a UTC Date for the key.
  def utc_date(%DateTime{} = dt), do: DateTime.to_date(dt)

  def utc_date(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> DateTime.to_date(dt)
      _ -> nil
    end
  end

  def utc_date(_), do: nil
end
