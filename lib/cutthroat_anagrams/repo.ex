defmodule CutthroatAnagrams.Repo do
  use Ecto.Repo,
    otp_app: :cutthroat_anagrams,
    adapter: Ecto.Adapters.Postgres
end
