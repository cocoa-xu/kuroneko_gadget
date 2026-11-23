defmodule Kuroneko.Gadget.DefaultGadgetTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "the only gadget in configfs, else one named kuroneko", %{tmp_dir: configfs} do
    assert Kuroneko.Gadget.default_gadget(configfs) == Path.join(configfs, "kuroneko")
    File.mkdir!(Path.join(configfs, "g1"))
    assert Kuroneko.Gadget.default_gadget(configfs) == Path.join(configfs, "g1")
    File.mkdir!(Path.join(configfs, "g2"))
    assert Kuroneko.Gadget.default_gadget(configfs) == Path.join(configfs, "kuroneko")
  end
end
