defmodule DialectoPhoenix.PlainBackend do
  @moduledoc false
  # The same catalogs without the wrapper: what an unmarked lookup must equal.
  use Gettext.Backend,
    otp_app: :dialecto_phoenix,
    priv: "test/fixtures/gettext",
    default_locale: "en"
end
