defmodule ExLinearTest do
  use ExUnit.Case, async: true

  describe "ExLinear" do
    test "module is loaded" do
      assert Code.ensure_loaded?(ExLinear)
    end

    test "config returns keyword list" do
      config = ExLinear.config()
      assert is_list(config)
    end
  end
end
