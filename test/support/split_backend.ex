defmodule DialectoPhoenix.SplitBackend do
  @moduledoc false
  # Gettext compiles each locale into its own module here; the wrapper must
  # still compose with the clauses it generates.
  use Gettext.Backend,
    otp_app: :dialecto_phoenix,
    priv: "test/fixtures/gettext",
    default_locale: "en",
    split_module_by: [:locale]

  @before_compile DialectoPhoenix.Gettext
end
