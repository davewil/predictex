# Seed the database with the World Cup schedule + results from openfootball.
#
#   mix run priv/repo/seeds.exs                                       # fetch the live 2026 feed
#   WORLDCUP_JSON=path/to/worldcup.json mix run priv/repo/seeds.exs   # use a local file (offline)
#
# Idempotent: re-running upserts rounds/fixtures and preserves admin-entered cohort %.

alias Predictex.Results.Ingest

result =
  case System.get_env("WORLDCUP_JSON") do
    nil ->
      IO.puts("Seeding from the live openfootball 2026 feed…")
      Ingest.sync_from_url()

    path ->
      IO.puts("Seeding from #{path}…")
      Ingest.sync_from_file(path)
  end

IO.inspect(result, label: "ingest")

# Dev/test convenience account, so `mix ecto.reset` always yields a usable login with a
# realistic, populated set of predictions.
#
# GUARDED to dev/test: this account has a known password and must NEVER exist in prod.
# (Prod boots via `Predictex.Release.migrate`, not this script, so it won't run there — the
# guard is belt-and-braces against a stray `MIX_ENV=prod mix run priv/repo/seeds.exs`.)
#
# Demo's picks are REAL data, not fabricated: the crowd-favourite scoreline for every group
# match, taken from FIFA's own `matchStats.json` (`quickPicks` = the most-predicted scorelines).
# The FIFA snapshots in `priv/fifa/` were grabbed ONCE (see priv/fifa/README.md) and are read
# from disk here — no live network, so seeding is deterministic and offline. Picks are written
# through the real import path (`Fifa.Import.plan/3` -> `Predictions.admin_save_round_predictions/3`),
# the same code the live /import flow uses — no hand-set DB records.
defmodule DemoSeed do
  alias Predictex.Fifa.Import
  alias Predictex.{Predictions, Tournament}

  @group_rounds 1..3

  def ensure_player(attrs) do
    case Predictex.Accounts.get_player_by_email(attrs.email) do
      nil ->
        case Predictex.Accounts.register_player(attrs) do
          {:ok, p} ->
            IO.puts("Seeded demo player #{p.email} (password: #{attrs.password})")
            p

          {:error, cs} ->
            IO.inspect(cs.errors, label: "demo player seed FAILED")
            nil
        end

      existing ->
        IO.puts("Demo player #{attrs.email} already exists — left as-is")
        existing
    end
  end

  # Seed only when the player has no predictions yet (self-healing + idempotent).
  def maybe_seed_predictions(nil), do: :noop

  def maybe_seed_predictions(player) do
    if Predictions.list_player_predictions(player.id) == [] do
      seed_predictions(player)
    else
      IO.puts("Demo player already has predictions — left as-is")
    end
  end

  defp seed_predictions(player) do
    rounds = read_json("rounds.json")
    stats = read_json("matchStats.json")

    rows = crowd_favourite_rows(rounds, stats)
    %{matched: matched} = Import.plan(rows, rounds, Tournament.list_fixtures())

    written =
      matched
      |> Import.to_write_rows()
      |> Enum.reduce(0, fn {round_id, write_rows}, acc ->
        case Predictions.admin_save_round_predictions(player.id, round_id, write_rows) do
          {:ok, results} -> acc + Enum.count(results, fn {_id, r} -> r == :upserted end)
          {:error, _} -> acc
        end
      end)

    IO.puts(
      "Seeded #{written} demo predictions from FIFA crowd favourites (#{length(rows)} group matches)"
    )
  end

  # One payload row per group match, carrying the most-popular scoreline. The highest-confidence
  # pick in each round gets the booster (one per round, mirroring the real game rule).
  defp crowd_favourite_rows(rounds, stats) do
    rounds
    |> Enum.filter(&(&1["id"] in @group_rounds))
    |> Enum.flat_map(fn round ->
      scored =
        (round["tournaments"] || [])
        |> Enum.map(fn match ->
          case favourite(stats, match["id"]) do
            {hs, as} -> {match["id"], hs, as, confidence(stats, match["id"])}
            nil -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      booster_id =
        case Enum.sort_by(scored, fn {_id, _h, _a, c} -> c end, :desc) do
          [{id, _, _, _} | _] -> id
          [] -> nil
        end

      Enum.map(scored, fn {id, hs, as, _c} ->
        %{
          "round" => round["id"],
          "matchId" => id,
          "homeScore" => hs,
          "awayScore" => as,
          "booster" => id == booster_id
        }
      end)
    end)
  end

  # quickPicks is FIFA's most-predicted scorelines (desc by %); the head is the crowd favourite.
  # Matches with no quickPicks return nil and are skipped (none in the current group-stage snapshot).
  defp favourite(stats, match_id) do
    case stats[to_string(match_id)] do
      %{"quickPicks" => [%{"homeScore" => h, "awayScore" => a} | _]} -> {h, a}
      _ -> nil
    end
  end

  defp confidence(stats, match_id) do
    case stats[to_string(match_id)] do
      %{"quickPicks" => [%{"percentage" => p} | _]} -> p
      _ -> 0
    end
  end

  defp read_json(name) do
    :predictex
    |> :code.priv_dir()
    |> Path.join("fifa/#{name}")
    |> File.read!()
    |> Jason.decode!()
  end
end

if Mix.env() in [:dev, :test] do
  %{email: "demo@predictex.test", password: "predictex-demo-1234", display_name: "Demo Player"}
  |> DemoSeed.ensure_player()
  |> DemoSeed.maybe_seed_predictions()
end
