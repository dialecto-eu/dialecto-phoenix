<p align="center">
  <a href="https://dialecto.eu">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset=".github/brand/readme-banner-dark.svg">
      <img alt="Dialecto" src=".github/brand/readme-banner-light.svg" width="420">
    </picture>
  </a>
</p>

# dialecto_phoenix

In-context editing for Phoenix apps translated with gettext, for use with [Dialecto](https://dialecto.eu).

While the editor is open, every translated string on a page of your running dev app can be clicked and edited in a
Dialecto sidebar, with the gettext rules intact: contexts (`pgettext`), one field per plural form, and `%{name}`
placeholders. Your edits become Dialecto's usual minimal-diff pull request against your translation files.

This is a dev-only dependency. The two opt-in lines in Setup compile to nothing where the dependency is absent, so
production carries no trace of it.

Documentation lives at [dialecto.eu/docs](https://dialecto.eu/docs).

## What it does

The add-on does three things in your dev server:

- It wraps your gettext backend so that, only while the editor is open, each translation is returned with an
  invisible marker that records the domain, the message key (the msgid, or the msgctxt and msgid), the locale and
  the arguments the string was formatted with. That is how the editor knows which catalog entry a piece of text on
  the page came from.
- It adds a plug to your endpoint that injects Dialecto's overlay script into your pages and answers three small
  routes under `/__dialecto/` for the overlay.
- It renders drafts: strings you have edited in the sidebar show through your app's real gettext path after a
  reload, until you discard them or open the pull request.

## What Dialecto reads, and what it never reads

Dialecto reads only your translation files, never your source code. The Dialecto GitHub App reads only the
translation-file paths confirmed for your project. Each time it reads, it also matches the names in the repository's
file listing, never their contents, against the pattern list below, and shows the project's managers any translation
files it finds outside those paths; nothing under them is read until someone adds the path. This add-on does not
widen that: it never reads, scans or uploads your source code or your catalogs.

The patterns it looks for are these:

- `**/LC_MESSAGES/*.po` and `**/*.pot` for gettext.
- `**/config/locales/**/*.yml` for Rails locale files.
- `**/_locales/*/messages.json` for browser-extension messages.
- JSON files named after your source locale, either `**/<source locale>.json` or `**/<source locale>/*.json`.

Folders named `node_modules`, `vendor`, `deps`, `_build`, `build`, `dist`, `tmp`, `log`, `coverage`, `test`, `spec`
or `fixtures`, and any folder whose name starts with a dot, are never proposed.

That is an improvement over reading the whole source tree, which GitHub's permission would allow. One caveat is part
of the design: GitHub's Contents permission applies to the whole repository, so GitHub does not enforce this
boundary. Dialecto's own code does. A team that wants the boundary enforced outside Dialecto's code can block the
App's read access and let its CI push the translation files instead (CI-push mode); the generated workflow lists
exactly which paths it sends, in your own repository.

The catalogs reach Dialecto from a push (the App reads the confirmed paths) or from your CI. The add-on itself never
sends them.

## What runs where

On your machine, in your dev server:

- The Gettext wrapper and the plug, as described above.
- `git`, run locally on request by `GET /__dialecto/context` to read the `origin` remote, the current branch and
  commit, and which files under your catalogs folder have uncommitted changes. The answer goes to the page that
  asked and nowhere else.

In your browser, from Dialecto:

- The overlay script, loaded from `<url>/assets/in-context/overlay.js` with `defer`, where `url` defaults to
  `https://app.dialecto.eu`. The page renders even when Dialecto is slow or unreachable.
- The Dialecto sidebar, which the overlay frames. You sign in to your Dialecto account there, and the first time a
  Dialecto window asks you to allow it. Your edits are saved there as drafts on your project, and the pull request is
  opened from there.
- The overlay talks to your dev server (`/__dialecto/context`, `/__dialecto/overrides`, `/__dialecto/marking`) and to
  the sidebar by browser messaging. The text and identities of strings on the page, which come from your
  translations and their arguments, are what the editor works on, so avoid opening the editor on pages that show
  data you would not want in Dialecto.

The add-on makes no outbound request of its own. Your Elixir code never calls Dialecto's servers.

## Setup

1. Add the dependency for `:dev` only. The package is not on Hex yet, so install it from GitHub:

   ```elixir
   # mix.exs
   {:dialecto_phoenix, github: "dialecto-eu/dialecto-phoenix", only: :dev}
   ```

   To pin it to a commit, add `ref: "<commit-sha>"`. Once it is published on Hex, use
   `{:dialecto_phoenix, "~> 0.1", only: :dev}`. A local checkout also works:
   `{:dialecto_phoenix, path: "../dialecto-phoenix", only: :dev}`.

2. Mark the gettext backend, right after `use Gettext.Backend`:

   ```elixir
   # lib/my_app_web/gettext.ex
   defmodule MyAppWeb.Gettext do
     use Gettext.Backend, otp_app: :my_app

     if Code.ensure_loaded?(DialectoPhoenix.Gettext),
       do: @before_compile(DialectoPhoenix.Gettext)
   end
   ```

3. Add the plug to the endpoint, before the router and before `Plug.Parsers`, so it reads its own small JSON bodies:

   ```elixir
   # lib/my_app_web/endpoint.ex
   if Code.ensure_loaded?(DialectoPhoenix.Plug), do: plug(DialectoPhoenix.Plug)
   ```

4. Recompile the backend (`mix compile --force`, or touch the file) and run `mix phx.server`. An "Edit text" button
   appears at the bottom right of every page.

The add-on finds the project on its own: it reads the app's git remote and Dialecto matches it to your project.
Requirements: Elixir 1.18 or later, `gettext ~> 1.0`, `expo ~> 1.0` and `plug ~> 1.15`.

Dialecto is in a soft launch. The app at `https://app.dialecto.eu` is open to early-access teams by email at
info@dialecto.eu, and the editor needs an account there.

## Configuration

An environment variable wins over `config :dialecto_phoenix, ...`, which wins over the default. The names match the
Astro add-on's.

| Option | Env var | Default | What it is for |
| --- | --- | --- | --- |
| `url` | `DIALECTO_URL` | `https://app.dialecto.eu` | The Dialecto that serves the overlay and sidebar. Set it when you run Dialecto yourself, for example `http://localhost:4500`. |
| `project` | `DIALECTO_PROJECT` | none | The project's `owner/name` slug or its number. Use it when the git remote doesn't identify the project, or when several projects share one repository. |
| `catalogs` | `DIALECTO_CATALOGS` | `priv/gettext` | The catalogs folder whose uncommitted files the sidebar warns about. |
| `enabled` | `DIALECTO_IN_CONTEXT` | on | `enabled: false` or `DIALECTO_IN_CONTEXT=off` (also `false`, `0` or `no`) turns the add-on off. |
| `paths` | `DIALECTO_PATHS` | every page | Comma-separated path prefixes whose pages get the editor, to keep it off admin screens, say. |

```elixir
# config/dev.exs
config :dialecto_phoenix, url: "http://localhost:4500", paths: ["/app"]
```

## Safety

- Dev only: the dependency is `only: :dev`, and the `Code.ensure_loaded?/1` guards compile the opt-in lines away
  elsewhere.
- Loopback only: the request `Host` must be `localhost`, `127.0.0.1` or `[::1]`, which also defeats DNS rebinding.
  A POST must carry the site's own `Origin`, and a request with a foreign `Origin` or `Sec-Fetch-Site: cross-site`
  is refused. The overlay never loads into an iframe, such as Dialecto's own sidebar.
- Markers are on only while the editor is open and heartbeating. A closed tab can't leave them on: marking lapses
  90 seconds after the last heartbeat.
- With marking off and no drafts, a lookup costs two ETS reads on top of gettext's own.

## Run your own fork

You can run your own version of this package.

1. Fork the repository.
2. Depend on your fork, pinned to a commit:

   ```elixir
   {:dialecto_phoenix, git: "https://github.com/your-org/your-fork.git", ref: "<commit-sha>", only: :dev}
   ```

   or, from a checkout, `{:dialecto_phoenix, path: "../your-fork", only: :dev}`.

What the fork covers is the Elixir package: the gettext wrapper, the plug, the git context and the settings. It has
no hidden dependencies on Dialecto's servers; its Hex dependencies are `gettext`, `expo` and `plug`. What it does not
include is the overlay and the sidebar. Those are served by a Dialecto instance, which is `https://app.dialecto.eu`
unless you set `url`. A fork still needs a Dialecto to load them from, hosted by Dialecto or run by you with `url`
pointing at it.

## Develop

```sh
mix deps.get
mix test
```

| File | Role |
| --- | --- |
| `lib/dialecto_phoenix.ex` | Entry point and version. |
| `lib/dialecto_phoenix/gettext.ex` | The `@before_compile` backend wrapper, plural selection and draft overrides. |
| `lib/dialecto_phoenix/plug.ex` | The `/__dialecto/*` routes, the origin rules and the loader injection. |
| `lib/dialecto_phoenix/config.ex` | Settings from the environment and app config. |
| `lib/dialecto_phoenix/{marker,args}.ex` | The invisible marker codec and the argument payload. |
| `lib/dialecto_phoenix/{store,overrides}.ex` | Marking state and saved drafts, in an ETS table. |
| `lib/dialecto_phoenix/git_context.ex` | The git remote, branch, commit and uncommitted catalogs. |

## Licence

MIT. See [LICENSE](LICENSE).

## Security

Please report vulnerabilities privately, through GitHub's private vulnerability reporting on this repository, and not
in a public issue.

## Contributing

Issues and pull requests are welcome. Please keep changes small and tested. The marker format, the `/__dialecto/*`
routes and the loopback rules are shared with the overlay and the Astro add-on, so changing them needs a major
version.
