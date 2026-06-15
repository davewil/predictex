defmodule PredictexWeb.Flags do
  @moduledoc """
  Maps a team name (the exact strings the openfootball 2026 feed emits) to a flag
  emoji for display. Presentation-only and best-effort: any unmapped string —
  including playoff-winner placeholders — falls back to ⚽, so an unknown team never
  breaks the page. Keys are verified against the live feed (fetch-and-diff during
  implementation).

  Note: England and Scotland use Unicode tag-sequence emoji (black flag + subdivision
  tags) rather than two regional-indicator characters, because neither has an ISO
  3166-1 alpha-2 code. All other nations use standard regional-indicator pairs.
  """

  @fallback "⚽"

  # Keys are the exact strings the feed emits for .team1 / .team2.
  # Placeholders such as "1A", "2B", "W73", "3A/B/C/D/F", "L101" are intentionally
  # absent — they fall back to ⚽.
  @flags %{
    "Algeria" => "🇩🇿",
    "Argentina" => "🇦🇷",
    "Australia" => "🇦🇺",
    "Austria" => "🇦🇹",
    "Belgium" => "🇧🇪",
    "Bosnia & Herzegovina" => "🇧🇦",
    "Brazil" => "🇧🇷",
    "Canada" => "🇨🇦",
    "Cape Verde" => "🇨🇻",
    "Colombia" => "🇨🇴",
    "Croatia" => "🇭🇷",
    "Curaçao" => "🇨🇼",
    "Czech Republic" => "🇨🇿",
    "DR Congo" => "🇨🇩",
    "Ecuador" => "🇪🇨",
    "Egypt" => "🇪🇬",
    "England" => "🏴󠁧󠁢󠁥󠁮󠁧󠁿",
    "France" => "🇫🇷",
    "Germany" => "🇩🇪",
    "Ghana" => "🇬🇭",
    "Haiti" => "🇭🇹",
    "Iran" => "🇮🇷",
    "Iraq" => "🇮🇶",
    "Ivory Coast" => "🇨🇮",
    "Japan" => "🇯🇵",
    "Jordan" => "🇯🇴",
    "Mexico" => "🇲🇽",
    "Morocco" => "🇲🇦",
    "Netherlands" => "🇳🇱",
    "New Zealand" => "🇳🇿",
    "Norway" => "🇳🇴",
    "Panama" => "🇵🇦",
    "Paraguay" => "🇵🇾",
    "Portugal" => "🇵🇹",
    "Qatar" => "🇶🇦",
    "Saudi Arabia" => "🇸🇦",
    "Scotland" => "🏴󠁧󠁢󠁳󠁣󠁴󠁿",
    "Senegal" => "🇸🇳",
    "South Africa" => "🇿🇦",
    "South Korea" => "🇰🇷",
    "Spain" => "🇪🇸",
    "Sweden" => "🇸🇪",
    "Switzerland" => "🇨🇭",
    "Tunisia" => "🇹🇳",
    "Turkey" => "🇹🇷",
    "Uruguay" => "🇺🇾",
    "USA" => "🇺🇸",
    "Uzbekistan" => "🇺🇿"
  }

  @doc "Flag emoji for a team name; ⚽ when unmapped."
  @spec flag(String.t() | nil) :: String.t()
  def flag(team) when is_binary(team), do: Map.get(@flags, team, @fallback)
  def flag(_), do: @fallback

  @doc "All mapped team strings (used by the data-contract diff)."
  @spec known() :: [String.t()]
  def known, do: Map.keys(@flags)
end
