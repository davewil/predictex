defmodule PredictexWeb.TimeHelpers do
  @moduledoc "Pure UTC->local kickoff formatting (predictex-fb5). The single tz-safety point."
  @fmt "%a %d %b · %H:%M"

  def kickoff(nil, _tz), do: "TBC"

  def kickoff(%DateTime{} = dt, tz) when is_binary(tz) and tz != "" do
    case DateTime.shift_zone(dt, tz) do
      {:ok, local} -> Calendar.strftime(local, @fmt)
      {:error, _} -> Calendar.strftime(dt, @fmt) <> " UTC"
    end
  end

  def kickoff(%DateTime{} = dt, _tz), do: Calendar.strftime(dt, @fmt) <> " UTC"
end
