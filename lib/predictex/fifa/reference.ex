defmodule Predictex.Fifa.Reference do
  @moduledoc """
  Server-side fetch of FIFA's PUBLIC static reference JSON (no auth, CDN-cached). Only the
  `/api/...` prediction endpoints are Akamai/cookie gated; `/json/...` is plain-fetchable.

  `fetch_rounds/0` is the crosswalk source for `Fifa.Import`; `get_json/1` is the shared
  HTTP helper reused by `Workers.CohortSync`.
  """
  @rounds_url "https://play.fifa.com/json/match_predictor/rounds.json"

  @doc "Fetch `rounds.json`. Returns `{:ok, rounds_list} | {:error, reason}`."
  def fetch_rounds, do: get_json(@rounds_url)

  @doc "GET a URL and return decoded JSON. `{:ok, map | list} | {:error, reason}`."
  def get_json(url) do
    {:ok, _} = Application.ensure_all_started(:req)

    case Req.get(url, receive_timeout: 15_000) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) or is_list(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        Jason.decode(body)

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
