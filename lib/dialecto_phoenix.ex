defmodule DialectoPhoenix do
  @moduledoc """
  Dialecto's in-context editor for Phoenix apps translated with gettext.
  Dev-only: add it as a `only: :dev` dependency and opt in with
  two guarded lines that compile to nothing where the dependency is absent,
  so production carries no trace of it:

      # mix.exs
      {:dialecto_phoenix, "~> 0.1", only: :dev}

      # lib/my_app_web/gettext.ex, after `use Gettext.Backend, …`
      if Code.ensure_loaded?(DialectoPhoenix.Gettext), do: @before_compile(DialectoPhoenix.Gettext)

      # lib/my_app_web/endpoint.ex, before the router
      if Code.ensure_loaded?(DialectoPhoenix.Plug), do: plug(DialectoPhoenix.Plug)

  `DialectoPhoenix.Gettext` marks every translation while the editor is
  open; `DialectoPhoenix.Plug` loads the editor's overlay into the app's
  pages and answers it on `/__dialecto/*`. Settings: `DialectoPhoenix.Config`.
  """

  @version Mix.Project.config()[:version]

  @doc "The add-on's version, reported to the sidebar."
  @spec version() :: String.t()
  def version, do: @version
end
