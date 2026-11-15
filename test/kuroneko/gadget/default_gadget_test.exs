defmodule Kuroneko.Gadget.DefaultGadgetTest do
  # The application environment is global.
  use ExUnit.Case, async: false

  alias Kuroneko.Gadget.Storage

  @moduletag :tmp_dir

  test "the only gadget in configfs, else one named kuroneko", %{tmp_dir: configfs} do
    assert Kuroneko.Gadget.only_gadget(configfs) == Path.join(configfs, "kuroneko")
    File.mkdir!(Path.join(configfs, "g1"))
    assert Kuroneko.Gadget.only_gadget(configfs) == Path.join(configfs, "g1")
    File.mkdir!(Path.join(configfs, "g2"))
    assert Kuroneko.Gadget.only_gadget(configfs) == Path.join(configfs, "kuroneko")
  end

  test "the application environment chooses the gadget", %{tmp_dir: tmp_dir} do
    Application.put_env(:kuroneko_gadget, :gadget, tmp_dir)
    on_exit(fn -> Application.delete_env(:kuroneko_gadget, :gadget) end)

    assert Kuroneko.Gadget.default_gadget() == tmp_dir
    assert Storage.medium() == {:error, :no_storage}
  end
end
