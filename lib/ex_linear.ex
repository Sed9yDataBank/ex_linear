defmodule ExLinear do
  @moduledoc """
  A clean Linear GraphQL client for Elixir.
  """

  @doc false
  def config do
    Application.get_all_env(:ex_linear)
  end
end
