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
  alias PredictexWeb.AdminWriteResult
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

    reload = fn socket ->
      assign(socket, :existing, existing_for(player_id, fixtures_for_round(round_id)))
    end

    # Parse + validate at the shared prediction-intake boundary (pure); persist on success.
    case Predictions.parse_pick_rows(params["rows"] || %{}, params["booster_fixture_id"]) do
      {:ok, rows} ->
        AdminWriteResult.handle(
          socket,
          Predictions.admin_save_round_predictions(player_id, round_id, rows),
          reload,
          &summarize/1,
          &prediction_error/1
        )

      {:error, :booster_on_blank} ->
        {:noreply, put_flash(socket, :error, prediction_error(:booster_on_blank))}
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

  # Booster-on-blank gets its own copy; any other error is a generic save failure.
  defp prediction_error({:booster_on_blank, _results}),
    do:
      "Can't boost a fixture with no scoreline — enter a score for the boosted fixture or pick \"No booster\". Nothing was saved."

  defp prediction_error(:booster_on_blank), do: prediction_error({:booster_on_blank, %{}})
  defp prediction_error(_), do: "Could not save predictions."

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

  defp existing_val(existing, fixture_id, field) do
    case Map.get(existing, fixture_id) do
      nil -> nil
      pred -> Map.get(pred, field)
    end
  end
end
