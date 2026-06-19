defmodule PredictexWeb.CSPTest do
  @moduledoc """
  Guards the Content-Security-Policy served on the :browser pipeline (predictex-y58).

  The script-src hash test is deliberately non-circular: it recomputes the SHA-256 of the
  *rendered* inline theme script and asserts that exact digest appears in the CSP header. If
  the inline script in root.html.heex is ever edited without updating `@theme_script_hash` in
  the router, this fails — which is precisely the moment the browser would start blocking the
  script.
  """
  use PredictexWeb.ConnCase, async: true

  describe "Content-Security-Policy header on browser responses" do
    test "is present with the expected directives", %{conn: conn} do
      conn = get(conn, ~p"/players/log-in")

      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "default-src 'self'"
      assert csp =~ "object-src 'none'"
      assert csp =~ "base-uri 'self'"
      assert csp =~ "frame-ancestors 'self'"
      # Google Fonts: stylesheet from fonts.googleapis.com, woff2 from fonts.gstatic.com.
      assert csp =~ "style-src 'self' https://fonts.googleapis.com"
      assert csp =~ "font-src 'self' https://fonts.gstatic.com"
      # LiveView websocket + XHR are same-origin.
      assert csp =~ "connect-src 'self'"
    end

    test "whitelists the exact inline theme script via its sha256 hash", %{conn: conn} do
      conn = get(conn, ~p"/players/log-in")
      html = html_response(conn, 200)
      assert [csp] = get_resp_header(conn, "content-security-policy")

      script = extract_inline_script(html)
      digest = :crypto.hash(:sha256, script) |> Base.encode64()

      assert csp =~ "'sha256-#{digest}'",
             "CSP script-src must contain the SHA-256 of the rendered inline theme script.\n" <>
               "Expected: 'sha256-#{digest}'\nGot CSP: #{csp}"
    end

    test "does not fall back to 'unsafe-inline' for scripts", %{conn: conn} do
      conn = get(conn, ~p"/players/log-in")
      assert [csp] = get_resp_header(conn, "content-security-policy")

      # script-src must lock down inline execution via the hash, never 'unsafe-inline'.
      [script_src] =
        csp
        |> String.split(";")
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&String.starts_with?(&1, "script-src"))

      refute script_src =~ "unsafe-inline"
    end
  end

  # The inline theme script is the only <script> in the root layout rendered with no
  # attributes (the app.js tag is `<script defer ... src=...>`), so a bare `<script>` opening
  # tag matches it uniquely. The captured group is exactly the element's text content — the
  # bytes the browser hashes for a 'sha256-...' source expression.
  defp extract_inline_script(html) do
    [_full, content] = Regex.run(~r{<script>(.*?)</script>}s, html)
    content
  end
end
