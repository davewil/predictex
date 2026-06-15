defmodule PredictexWeb.AdminComponents do
  @moduledoc "Shared function components for the admin console."
  use PredictexWeb, :html

  @doc "Section nav bar shared by all admin LiveViews."
  attr :active, :atom, required: true

  def admin_nav(assigns) do
    ~H"""
    <nav class="tabs tabs-boxed mb-4">
      <.link navigate={~p"/admin"} class={["tab", @active == :home && "tab-active"]}>Home</.link>
      <.link
        navigate={~p"/admin/predictions"}
        class={["tab", @active == :predictions && "tab-active"]}
      >Predictions</.link>
      <.link navigate={~p"/admin/fixtures"} class={["tab", @active == :fixtures && "tab-active"]}>Fixtures</.link>
      <.link navigate={~p"/admin/players"} class={["tab", @active == :players && "tab-active"]}>Players</.link>
    </nav>
    """
  end
end
