defmodule Predictex.Fifa.KnockoutTeams do
  @moduledoc """
  Resolve R32 (and later-round) bracket placeholder slots to real team names from FIFA's
  `rounds.json`, ahead of openfootball (predictex-e5o).

  openfootball owns team identity (the two-writer rule). For a knockout fixture that still holds
  a placeholder side (`"3B/E/F/I/J"`, `"1H"`, …), FIFA's `rounds.json` often carries the resolved
  name (`homeSquadName`/`awaySquadName`) earlier — it forces a third-placed slot by elimination as
  groups lock. This module slot-matches our fixture to the FIFA entry (`Crosswalk.slot_key/1`,
  the proven 1:1 knockout join), maps FIFA's name back to the **openfootball-canonical** name
  (`Crosswalk.norm/1` alias table + an index of names already in our fixtures), and fills **only
  the placeholder side(s)** — never a side `Knockout.resolved_team?/1` already calls real. That
  "placeholders only" rule IS the no-downgrade guard: a resolved side is structurally absent from
  the output, so openfootball stays authoritative and reclaims on its next sync.
  """

  alias Predictex.Fifa.Crosswalk
  alias Predictex.{Knockout, Repo, Tournament}
  alias Predictex.Tournament.Fixture

  @ko_stages ~w(r32 r16 qf sf f)

  @doc "`norm(name) => name` for every resolved name; maps a FIFA/lowercased name to its canonical form."
  def canonical_index(names) do
    for n <- names, Knockout.resolved_team?(n), into: %{}, do: {Crosswalk.norm(n), n}
  end

  @doc """
  Per-fixture fills for placeholder knockout slots. One entry per fixture that has a placeholder
  side AND a canonical FIFA name to fill it with; the entry carries only the placeholder side(s).
  """
  def plan(rounds, fixtures, canonical_index) do
    slot_idx =
      for r <- rounds, r["stage"] in @ko_stages, t <- r["tournaments"] || [], into: %{} do
        {Crosswalk.slot_key(t["date"]), {t["homeSquadName"], t["awaySquadName"]}}
      end

    for f <- fixtures,
        not (Knockout.resolved_team?(f.team1) and Knockout.resolved_team?(f.team2)),
        {home, away} = Map.get(slot_idx, Crosswalk.slot_key(f.kickoff_at), {nil, nil}),
        fill = fill_for(f, home, away, canonical_index),
        map_size(fill) > 0 do
      Map.put(fill, :fixture_id, f.id)
    end
  end

  @doc """
  Resolve every fillable placeholder knockout slot from `rounds` and persist it. Returns
  `%{resolved: fixtures_written, sides: name_columns_written, errors: n}` and broadcasts a
  fixtures-changed signal when anything was written. openfootball reclaims authority on its next
  sync (two-writer rule).
  """
  def assign(rounds) do
    fixtures = Repo.all(Fixture)
    by_id = Map.new(fixtures, &{&1.id, &1})
    idx = canonical_index(Enum.flat_map(fixtures, &[&1.team1, &1.team2]))

    summary =
      rounds
      |> plan(fixtures, idx)
      |> Enum.reduce(%{resolved: 0, sides: 0, errors: 0}, fn fill, acc ->
        {fid, attrs} = Map.pop(fill, :fixture_id)

        case Tournament.update_fixture(Map.fetch!(by_id, fid), attrs) do
          {:ok, _} -> %{acc | resolved: acc.resolved + 1, sides: acc.sides + map_size(attrs)}
          {:error, _} -> %{acc | errors: acc.errors + 1}
        end
      end)

    if summary.resolved > 0, do: Tournament.broadcast_change()
    summary
  end

  defp fill_for(f, home, away, idx) do
    t1_ph = not Knockout.resolved_team?(f.team1)
    t2_ph = not Knockout.resolved_team?(f.team2)
    c_home = canonical(idx, home)
    c_away = canonical(idx, away)

    cond do
      # Anchored-only (v1): a fill requires exactly one resolved side to anchor orientation.
      # Both-placeholder is skipped (no anchor to validate FIFA's home/away order); the group
      # winner resolves first via openfootball, after which the anchored branch fills the third.
      t1_ph and t2_ph -> %{}
      t1_ph -> anchored(f.team2, :team1, home, away, c_home, c_away)
      t2_ph -> anchored(f.team1, :team2, home, away, c_home, c_away)
      true -> %{}
    end
  end

  # Anchor on the already-resolved side: whichever FIFA side it equals fixes the orientation, so
  # the placeholder side takes the OTHER FIFA name. If the anchor matches neither, the slot match
  # is spurious → fill nothing.
  defp anchored(anchor, fill_key, fifa_home, fifa_away, c_home, c_away) do
    cond do
      Crosswalk.norm(anchor) == Crosswalk.norm(fifa_home) -> maybe_put(%{}, fill_key, c_away)
      Crosswalk.norm(anchor) == Crosswalk.norm(fifa_away) -> maybe_put(%{}, fill_key, c_home)
      true -> %{}
    end
  end

  defp canonical(_idx, nil), do: nil
  defp canonical(idx, name), do: Map.get(idx, Crosswalk.norm(name))

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
