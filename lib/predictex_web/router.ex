defmodule PredictexWeb.Router do
  use PredictexWeb, :router

  import PredictexWeb.PlayerAuth

  # SHA-256 of the inline theme <script> in root.html.heex, base64-encoded — the exact bytes
  # the browser hashes for the CSP 'sha256-...' source expression. Guarded by
  # PredictexWeb.CSPTest, which recomputes this from the rendered page: if the inline script
  # changes without updating this value, that test fails (and the browser would block it).
  @theme_script_hash "6GNRXphE5cePbii63vY7NqMXODo9lGI9WNtFRNLGf8E="

  # Content-Security-Policy for browser responses (predictex-y58). Strict script-src — inline
  # execution is whitelisted only by the hash above, never 'unsafe-inline'. style/font-src
  # allow Google Fonts (stylesheet + woff2); connect-src 'self' covers the same-origin
  # LiveView websocket. Set via put_secure_browser_headers so sobelow's Config.CSP detects it.
  @content_security_policy [
                             "default-src 'self'",
                             "script-src 'self' 'sha256-#{@theme_script_hash}'",
                             "style-src 'self' https://fonts.googleapis.com",
                             "font-src 'self' https://fonts.gstatic.com",
                             "img-src 'self' data:",
                             "connect-src 'self'",
                             "base-uri 'self'",
                             "frame-ancestors 'self'",
                             "object-src 'none'"
                           ]
                           |> Enum.join("; ")

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PredictexWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"content-security-policy" => @content_security_policy}
    plug :fetch_current_scope_for_player
    # Classify UA (mobile/desktop); read by LiveViews via the session
    plug PredictexWeb.PlatformPlug
    # Stash the viewer's IANA tz (set client-side as a cookie) into the session,
    # so the disconnected mount can render local kickoff times before the socket connects.
    plug :put_tz
  end

  # Copy the `tz` cookie (written by app.js) into the session for the on_mount hook.
  defp put_tz(conn, _opts) do
    conn = fetch_cookies(conn)

    case conn.cookies["tz"] do
      tz when is_binary(tz) and tz != "" -> put_session(conn, "tz", tz)
      _ -> conn
    end
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", PredictexWeb do
    pipe_through :browser

    # Optional auth: assigns current_scope (nil when logged out) so the public
    # leaderboard can highlight the logged-in player's own row (predictex-kzz).
    live_session :public,
      on_mount: [{PredictexWeb.PlayerAuth, :mount_current_scope}] do
      live "/", LeaderboardLive, :index
    end
  end

  scope "/", PredictexWeb do
    pipe_through :api

    get "/health", HealthController, :index
  end

  # Other scopes may use custom stacks.
  # scope "/api", PredictexWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:predictex, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: PredictexWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", PredictexWeb do
    pipe_through [:browser, :require_authenticated_player]

    live_session :require_authenticated_player,
      on_mount: [
        {PredictexWeb.PlayerAuth, :require_authenticated},
        {PredictexWeb.TimeZone, :assign_tz}
      ] do
      live "/fixtures/:id", FixtureLive, :show
      live "/predictions", MyPredictionsLive, :index
      live "/import", ImportLive, :index
      live "/players/settings", PlayerLive.Settings, :edit
      live "/players/settings/confirm-email/:token", PlayerLive.Settings, :confirm_email
    end

    # Chain :require_authenticated (logged-out -> login) then :require_admin (non-admin -> /).
    live_session :require_admin,
      on_mount: [
        {PredictexWeb.PlayerAuth, :require_authenticated},
        {PredictexWeb.PlayerAuth, :require_admin}
      ] do
      live "/admin", AdminLive, :index
      live "/admin/predictions", AdminPredictionsLive, :index
      live "/admin/fixtures", AdminFixturesLive, :index
      live "/admin/players", AdminPlayersLive, :index
    end

    post "/players/update-password", PlayerSessionController, :update_password
  end

  # FunWithFlags admin dashboard — forwarded plug router, so it needs the
  # plug-level admin guard (the on_mount :require_admin hook only covers LiveViews).
  # Chained require_authenticated -> require_admin mirrors the :require_admin live_session.
  scope path: "/admin/feature-flags" do
    pipe_through [:browser, :require_authenticated_player, :require_admin_player]

    forward "/", FunWithFlags.UI.Router, namespace: "admin/feature-flags"
  end

  scope "/", PredictexWeb do
    pipe_through [:browser]

    live_session :current_player,
      on_mount: [{PredictexWeb.PlayerAuth, :mount_current_scope}] do
      live "/players/register", PlayerLive.Registration, :new
      live "/players/log-in", PlayerLive.Login, :new
      live "/players/log-in/:token", PlayerLive.Confirmation, :new
    end

    post "/players/log-in", PlayerSessionController, :create
    delete "/players/log-out", PlayerSessionController, :delete
  end
end
