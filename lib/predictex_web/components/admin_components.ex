defmodule PredictexWeb.AdminComponents do
  @moduledoc "Shared function components for the admin console."
  use PredictexWeb, :html

  @doc """
  Admin chrome shared by every admin LiveView: the ADMIN-badged identity row
  plus a segmented section nav. Utilitarian — speed & density over flair, per
  the design brief.
  """
  attr :active, :atom, required: true

  def admin_nav(assigns) do
    ~H"""
    <div class="mb-4 space-y-3">
      <div class="flex items-center gap-2.5">
        <span class="text-lg font-black tracking-tight">Admin console</span>
        <span class="rounded-md border border-error/35 bg-error/15 px-2 py-0.5 text-[9px] font-extrabold uppercase tracking-widest text-error">
          Admin
        </span>
      </div>

      <nav class="inline-flex flex-wrap gap-1 rounded-xl border border-base-300 bg-base-200/60 p-1">
        <.link navigate={~p"/admin"} class={admin_tab(@active == :home)}>Home</.link>
        <.link navigate={~p"/admin/predictions"} class={admin_tab(@active == :predictions)}>
          Predictions
        </.link>
        <.link navigate={~p"/admin/fixtures"} class={admin_tab(@active == :fixtures)}>
          Fixtures
        </.link>
        <.link navigate={~p"/admin/players"} class={admin_tab(@active == :players)}>
          Players
        </.link>
      </nav>
    </div>
    """
  end

  @admin_tab_base "rounded-lg px-3.5 py-1.5 text-sm font-bold transition-colors"
  defp admin_tab(true), do: [@admin_tab_base, "bg-primary text-primary-content shadow"]
  defp admin_tab(false), do: [@admin_tab_base, "text-base-content/70 hover:bg-base-300"]

  @doc """
  A compact stat for the admin headers — `<.admin_stat label="players" value={12} />`.
  Density-first: mono number, muted label.
  """
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :tone, :string, default: "base"

  def admin_stat(assigns) do
    ~H"""
    <span class="text-xs text-base-content/60">
      <strong class={["font-score", @tone == "success" && "text-success"]}>{@value}</strong> {@label}
    </span>
    """
  end
end
