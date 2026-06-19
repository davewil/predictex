defmodule PredictexWeb.AdminWriteResultTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [assign: 3]

  alias PredictexWeb.AdminWriteResult

  # A bare socket with an initialized flash map — enough to exercise reload + flash
  # without standing up a full LiveView. `:flash` is a reserved assign, so it's seeded
  # via direct struct construction rather than `assign/3`.
  defp socket, do: %Phoenix.LiveView.Socket{assigns: %{flash: %{}, __changed__: %{}}}

  defp reload, do: fn s -> assign(s, :reloaded, true) end

  describe "handle/5 on success" do
    test "runs reload and flashes the :info message" do
      {:noreply, s} =
        AdminWriteResult.handle(socket(), {:ok, :ignored}, reload(), "Saved.", "Failed.")

      assert s.assigns.reloaded == true
      assert s.assigns.flash["info"] == "Saved."
      refute Map.has_key?(s.assigns.flash, "error")
    end

    test "derives the :info message from the :ok payload when given a function" do
      {:noreply, s} =
        AdminWriteResult.handle(
          socket(),
          {:ok, %{upserted: 3}},
          reload(),
          fn results -> "Saved #{results.upserted}." end,
          "Failed."
        )

      assert s.assigns.flash["info"] == "Saved 3."
    end
  end

  describe "handle/5 on error" do
    test "skips reload and flashes the :error message" do
      {:noreply, s} =
        AdminWriteResult.handle(socket(), {:error, :nope}, reload(), "Saved.", "Could not save.")

      refute Map.has_key?(s.assigns, :reloaded)
      assert s.assigns.flash["error"] == "Could not save."
      refute Map.has_key?(s.assigns.flash, "info")
    end

    test "maps the error reason to a specific message when given a function" do
      error_msg = fn
        {:booster_on_blank, _} -> "Can't boost a blank fixture."
        _ -> "Could not save predictions."
      end

      {:noreply, special} =
        AdminWriteResult.handle(
          socket(),
          {:error, {:booster_on_blank, %{}}},
          reload(),
          "Saved.",
          error_msg
        )

      {:noreply, generic} =
        AdminWriteResult.handle(socket(), {:error, :other}, reload(), "Saved.", error_msg)

      assert special.assigns.flash["error"] == "Can't boost a blank fixture."
      assert generic.assigns.flash["error"] == "Could not save predictions."
    end
  end
end
