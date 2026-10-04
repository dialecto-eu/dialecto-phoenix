defmodule DialectoPhoenix.Config do
  @moduledoc """
  The add-on's settings, with the same names as the Astro add-on's.
  Environment variables win over `config :dialecto_phoenix, …`:

    * `url` / `DIALECTO_URL` — the Dialecto that serves the overlay and the
      sidebar (default `https://app.dialecto.eu`);
    * `project` / `DIALECTO_PROJECT` — a project slug or id, when the git
      remote isn't enough to find it;
    * `catalogs` / `DIALECTO_CATALOGS` — the catalogs folder whose uncommitted
      files the sidebar warns about (default `priv/gettext`);
    * `enabled` / `DIALECTO_IN_CONTEXT=off` — switches the add-on off;
    * `paths` / `DIALECTO_PATHS` (comma-separated) — path prefixes whose pages
      get the editor (default: every page), to keep it off admin screens, say.
  """

  @default_url "https://app.dialecto.eu"
  @default_catalogs "priv/gettext"
  @off ~w(off false 0 no)
  @on ~w(on true 1 yes)

  @type t :: %{
          enabled: boolean(),
          url: String.t(),
          url_valid: boolean(),
          project: String.t() | nil,
          catalogs: String.t(),
          paths: [String.t()] | nil
        }

  @doc "Settings from `env` (the OS environment) and `app_env` (the app config)."
  @spec settings(map(), keyword()) :: t()
  def settings(env \\ System.get_env(), app_env \\ Application.get_all_env(:dialecto_phoenix)) do
    url =
      String.trim_trailing(first_text([env["DIALECTO_URL"], app_env[:url]]) || @default_url, "/")

    %{
      enabled: enabled?(env["DIALECTO_IN_CONTEXT"], app_env[:enabled]),
      url: url,
      url_valid: Regex.match?(~r/\Ahttps?:\/\/[^\/\s]/i, url),
      project: first_text([env["DIALECTO_PROJECT"], app_env[:project]]),
      catalogs: first_text([env["DIALECTO_CATALOGS"], app_env[:catalogs]]) || @default_catalogs,
      paths: paths(env["DIALECTO_PATHS"], app_env[:paths])
    }
  end

  @doc "True when the editor belongs on `path` under `settings.paths`."
  @spec path_allowed?(t(), String.t()) :: boolean()
  def path_allowed?(%{paths: nil}, _path), do: true

  def path_allowed?(%{paths: prefixes}, path) do
    Enum.any?(prefixes, fn prefix ->
      base = String.trim_trailing(prefix, "/")
      path == base or String.starts_with?(path, base <> "/")
    end)
  end

  defp paths(env_value, configured) do
    prefixes =
      case first_text([env_value]) do
        nil -> List.wrap(configured)
        text -> String.split(text, ",")
      end

    case prefixes
         |> Enum.filter(&is_binary/1)
         |> Enum.map(&String.trim/1)
         |> Enum.reject(&(&1 == "")) do
      [] -> nil
      list -> list
    end
  end

  defp first_text(candidates) do
    Enum.find_value(candidates, fn
      value when is_binary(value) -> if String.trim(value) != "", do: String.trim(value)
      value when is_integer(value) -> Integer.to_string(value)
      _other -> nil
    end)
  end

  defp enabled?(env_value, configured) do
    case env_value |> to_string() |> String.trim() |> String.downcase() do
      value when value in @off -> false
      value when value in @on -> true
      _unset -> configured != false
    end
  end
end
