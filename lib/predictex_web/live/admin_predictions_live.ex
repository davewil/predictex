defmodule PredictexWeb.AdminPredictionsLive do
  @moduledoc """
  Admin prediction entry on behalf of players. Two lenses over the same data:
  `?view=player` (primary entry — a per-round grid saved via
  `Predictions.admin_save_round_predictions/3`) and `?view=fixture` (read-only audit lens
  that flags players with no pick). The LiveView is the anti-corruption boundary: it parses
  raw form params into clean typed rows at the edge. Inline editing from the by-fixture lens
  is a deferred follow-up (it would call `Predictions.admin_upsert_prediction/1`).
  """
  use PredictexWeb, :live_view

  alias Predictex.{Accounts, Predictions, Tournament}
  alias PredictexWeb.Flags

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Predictions")
     |> assign(:players, Accounts.list_players())
     |> assign(:rounds, Tournament.list_rounds())
     |> assign(:selected_player_id, nil)
     |> assign(:selected_round_id, nil)
     |> assign(:selected_fixture_id, nil)
     |> assign(:fixtures, [])
     |> assign(:knockout?, false)
     |> assign(:all_fixtures, all_fixtures())
     |> assign(:existing, %{})
     |> assign(:fixture_preds, [])
     |> assign(:missing_players, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :view, view_of(params))}
  end

  defp view_of(%{"view" => "fixture"}), do: :fixture
  defp view_of(_), do: :player

  @impl true
  def handle_event("load_player_round", %{"player_id" => pid, "round_id" => rid}, socket) do
    player_id = to_int(pid)
    round_id = to_int(rid)
    fixtures = fixtures_for_round(round_id)
    existing = existing_for(player_id, fixtures)
    knockout? = knockout_round?(socket.assigns.rounds, round_id)

    {:noreply,
     socket
     |> assign(:selected_player_id, player_id)
     |> assign(:selected_round_id, round_id)
     |> assign(:fixtures, fixtures)
     |> assign(:existing, existing)
     |> assign(:knockout?, knockout?)}
  end

  def handle_event("save_player_round", params, socket) do
    player_id = to_int(params["player_id"])
    round_id = to_int(params["round_id"])
    boost_id = to_int(params["booster_fixture_id"])
    rows = parse_rows(params["rows"] || %{}, boost_id)

    case Predictions.admin_save_round_predictions(player_id, round_id, rows) do
      {:ok, results} ->
        fixtures = fixtures_for_round(round_id)

        {:noreply,
         socket
         |> assign(:existing, existing_for(player_id, fixtures))
         |> put_flash(:info, summarize(results))}

      {:error, {:booster_on_blank, _results}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Can't boost a fixture with no scoreline — enter a score for the boosted fixture or pick \"No booster\". Nothing was saved."
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not save predictions.")}
    end
  end

  def handle_event("load_fixture", %{"fixture_id" => fid}, socket) do
    fixture_id = to_int(fid)
    preds = Predictions.list_fixture_predictions(fixture_id)
    predicted_ids = MapSet.new(preds, & &1.player_id)
    missing = Enum.reject(socket.assigns.players, &MapSet.member?(predicted_ids, &1.id))

    {:noreply,
     socket
     |> assign(:selected_fixture_id, fixture_id)
     |> assign(:fixture_preds, preds)
     |> assign(:missing_players, missing)}
  end

  # --- parsing (anti-corruption boundary) ---

  defp parse_rows(rows, boost_id) do
    Enum.map(rows, fn {fid, attrs} ->
      fixture_id = to_int(fid)

      %{
        fixture_id: fixture_id,
        home_goals: to_int_or_nil(attrs["home_goals"]),
        away_goals: to_int_or_nil(attrs["away_goals"]),
        first_scorer_side: side_or_nil(attrs["first_scorer_side"]),
        first_scorer_player: blank_to_nil(attrs["first_scorer_player"]),
        booster: fixture_id == boost_id
      }
    end)
  end

  defp fixtures_for_round(round_id) do
    Tournament.list_fixtures()
    |> Enum.filter(&(&1.round_id == round_id))
    |> Enum.sort_by(& &1.id)
  end

  defp existing_for(player_id, fixtures) do
    ids = Enum.map(fixtures, & &1.id)

    Predictions.list_player_predictions(player_id)
    |> Enum.filter(&(&1.fixture_id in ids))
    |> Map.new(&{&1.fixture_id, &1})
  end

  defp summarize(results) do
    counts = results |> Map.values() |> Enum.frequencies_by(&result_kind/1)

    "Saved: #{Map.get(counts, :upserted, 0)} · skipped #{Map.get(counts, :skipped, 0)} · errors #{Map.get(counts, :error, 0)}"
  end

  defp result_kind(:upserted), do: :upserted
  defp result_kind(:skipped), do: :skipped
  defp result_kind({:error, _}), do: :error

  defp all_fixtures, do: Tournament.list_fixtures() |> Enum.sort_by(& &1.id)

  # First-team / first-player picks only exist in knockout rounds (rules.md §2).
  defp knockout_round?(rounds, round_id) do
    case Enum.find(rounds, &(&1.id == round_id)) do
      %{stage: :knockout} -> true
      _ -> false
    end
  end

  defp to_int(nil), do: nil
  defp to_int(""), do: nil
  defp to_int(i) when is_integer(i), do: i
  defp to_int(s) when is_binary(s), do: String.to_integer(s)
  defp to_int_or_nil(s) when s in ["", nil], do: nil

  defp to_int_or_nil(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(s), do: s
  defp side_or_nil("home"), do: :home
  defp side_or_nil("away"), do: :away
  defp side_or_nil(_), do: nil

  defp existing_val(existing, fixture_id, field) do
    case Map.get(existing, fixture_id) do
      nil -> nil
      pred -> Map.get(pred, field)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <PredictexWeb.AdminComponents.admin_nav active={:predictions} />

      <div class="mb-4 inline-flex gap-1 rounded-xl border border-base-300 bg-base-200/60 p-1">
        <.link
          patch={~p"/admin/predictions?view=player"}
          class={[
            "rounded-lg px-3.5 py-1.5 text-sm font-bold transition-colors",
            (@view == :player && "bg-primary text-primary-content shadow") ||
              "text-base-content/70 hover:bg-base-300"
          ]}
        >Enter by player</.link>
        <.link
          patch={~p"/admin/predictions?view=fixture"}
          class={[
            "rounded-lg px-3.5 py-1.5 text-sm font-bold transition-colors",
            (@view == :fixture && "bg-primary text-primary-content shadow") ||
              "text-base-content/70 hover:bg-base-300"
          ]}
        >By fixture</.link>
      </div>

      <div :if={@view == :player}>
        <form id="by-player-select" phx-change="load_player_round" class="flex gap-2 mb-4">
          <select name="player_id" class="select select-bordered">
            <option value="">Player…</option>
            <option :for={p <- @players} value={p.id} selected={p.id == @selected_player_id}>
              {p.display_name}
            </option>
          </select>
          <select name="round_id" class="select select-bordered">
            <option value="">Round…</option>
            <option :for={r <- @rounds} value={r.id} selected={r.id == @selected_round_id}>
              {r.name}
            </option>
          </select>
        </form>

        <form
          :if={@fixtures != [] && @selected_player_id}
          id="by-player-form"
          phx-submit="save_player_round"
        >
          <input type="hidden" name="player_id" value={@selected_player_id} />
          <input type="hidden" name="round_id" value={@selected_round_id} />
          <label class="label cursor-pointer gap-2 w-fit mb-2">
            <span class="text-sm">No booster</span>
            <input
              type="radio"
              class="radio"
              name="booster_fixture_id"
              value=""
              checked={Enum.all?(@existing, fn {_id, p} -> !p.booster end)}
            />
          </label>
          <table class="table">
            <thead>
              <tr>
                <th>Fixture</th>
                <th>H</th>
                <th>A</th>
                <th :if={@knockout?}>1st side</th>
                <th :if={@knockout?}>1st player</th>
                <th>⚡</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={f <- @fixtures}>
                <td class="font-medium">
                  {Flags.flag(f.team1)} {f.team1} v {f.team2} {Flags.flag(f.team2)}
                </td>
                <td>
                  <input
                    type="number"
                    min="0"
                    class="input input-bordered font-score w-16"
                    name={"rows[#{f.id}][home_goals]"}
                    value={existing_val(@existing, f.id, :home_goals)}
                  />
                </td>
                <td>
                  <input
                    type="number"
                    min="0"
                    class="input input-bordered font-score w-16"
                    name={"rows[#{f.id}][away_goals]"}
                    value={existing_val(@existing, f.id, :away_goals)}
                  />
                </td>
                <td :if={@knockout?}>
                  <select name={"rows[#{f.id}][first_scorer_side]"} class="select select-bordered">
                    <option value="">—</option>
                    <option
                      value="home"
                      selected={existing_val(@existing, f.id, :first_scorer_side) == :home}
                    >
                      Home
                    </option>
                    <option
                      value="away"
                      selected={existing_val(@existing, f.id, :first_scorer_side) == :away}
                    >
                      Away
                    </option>
                  </select>
                </td>
                <td :if={@knockout?}>
                  <input
                    type="text"
                    class="input input-bordered"
                    name={"rows[#{f.id}][first_scorer_player]"}
                    value={existing_val(@existing, f.id, :first_scorer_player)}
                  />
                </td>
                <td>
                  <input
                    type="radio"
                    class="radio"
                    name="booster_fixture_id"
                    value={f.id}
                    checked={existing_val(@existing, f.id, :booster) == true}
                  />
                </td>
              </tr>
            </tbody>
          </table>
          <button type="submit" class="btn btn-primary mt-4">Save all</button>
        </form>
      </div>

      <div :if={@view == :fixture}>
        <form id="by-fixture-select" phx-change="load_fixture" class="mb-4">
          <select name="fixture_id" class="select select-bordered">
            <option value="">Fixture…</option>
            <option :for={f <- @all_fixtures} value={f.id} selected={f.id == @selected_fixture_id}>
              {Flags.flag(f.team1)} {f.team1} v {f.team2} {Flags.flag(f.team2)}
            </option>
          </select>
        </form>

        <table :if={@selected_fixture_id} class="table">
          <thead>
            <tr>
              <th>Player</th>
              <th>Pick</th>
              <th>⚡</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={p <- @fixture_preds}>
              <td class="font-medium">{p.player.display_name}</td>
              <td class="font-score">{p.home_goals}–{p.away_goals}</td>
              <td>
                <span
                  :if={p.booster}
                  class="rounded bg-accent px-1.5 py-0.5 text-[10px] font-bold text-accent-content"
                >
                  ⚡ 2×
                </span>
              </td>
            </tr>
            <tr :for={pl <- @missing_players} class="opacity-60">
              <td>{pl.display_name}</td>
              <td colspan="2">
                <span class="rounded-md bg-error/15 px-2 py-1 text-[11px] font-semibold text-error">no pick</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end
end
