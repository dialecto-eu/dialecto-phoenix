defmodule DialectoPhoenix.TestBackend do
  @moduledoc false
  # Unguarded: `Code.ensure_loaded?/1` can't see a module of the project being
  # compiled alongside it. An app gets this package as an already compiled
  # dependency, where the guard holds (see the guarded-backend test).
  use Gettext.Backend,
    otp_app: :dialecto_phoenix,
    priv: "test/fixtures/gettext",
    default_locale: "en"

  @before_compile DialectoPhoenix.Gettext
end
