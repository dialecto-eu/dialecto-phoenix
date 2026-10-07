# dialecto_phoenix

A library, not an app: a dev-only Hex-style dependency (`only: :dev` in the host app) that gives
Phoenix apps translated with gettext in-context editing through Dialecto. Public, MIT, in the
`dialecto-eu` org. It pairs with the Dialecto app (`dlocal` repo, app.dialecto.eu; spec 17 in
`ddd-plan`). Sibling add-ons: `dialecto-astro` and `source-rewrite`. Main line: `main`. Not on Hex
yet; hosts install it from GitHub.

## Run and verify

```sh
mix deps.get
mix test
```

There is no server or endpoint here, so no Tidewave and no `.mcp.json`. Run it for real from a host
Phoenix app with `{:dialecto_phoenix, path: "../dialecto-phoenix", only: :dev}`.

## Layout

`lib/dialecto_phoenix/`: `gettext.ex` (the `@before_compile` backend wrapper, plurals, draft
overrides), `plug.ex` (the `/__dialecto/*` routes, origin rules, loader injection), `config.ex`,
`marker.ex` and `args.ex` (the invisible marker codec), `store.ex` and `overrides.ex` (ETS state),
`git_context.ex`.

## Rules that bite

- Dev only: the opt-in lines compile to nothing where the dependency is absent (`Code.ensure_loaded?`).
- Loopback only: `Host` must be `localhost`, `127.0.0.1` or `[::1]` and the socket's peer address
  (`Plug.Conn.get_peer_data/1`, never `X-Forwarded-For`) must be loopback; a POST needs the site's own
  `Origin`; foreign `Origin` or `Sec-Fetch-Site: cross-site` is refused; the overlay never loads in an
  iframe. Markers lapse 90 seconds after the last heartbeat.
- It makes no outbound request and never reads, scans or uploads source code or catalogs.
- Hex dependencies stay `gettext`, `expo` and `plug`.
- The marker format, the `/__dialecto/*` routes and the loopback rules are shared with the overlay and
  `dialecto-astro`; changing them needs a major version.
