defmodule Kuroneko.Gadget.Configfs do
  @moduledoc false

  @type error() :: Kuroneko.Gadget.configfs_error()

  @spec read(Path.t()) :: {:ok, binary()} | {:error, error()}
  def read(path) do
    case File.read(path) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, {:configfs, path, reason}}
    end
  end

  @spec read_text(Path.t()) :: {:ok, String.t()} | {:error, error()}
  def read_text(path) do
    with {:ok, data} <- read(path), do: {:ok, String.trim_trailing(data, "\n")}
  end

  @spec read_integer(Path.t()) :: {:ok, integer()} | {:error, error()}
  def read_integer(path) do
    with {:ok, text} <- read_text(path), do: {:ok, String.to_integer(text)}
  end

  @spec write(Path.t(), iodata()) :: :ok | {:error, error()}
  def write(path, value) do
    case File.write(path, value) do
      :ok -> :ok
      {:error, reason} -> {:error, {:configfs, path, reason}}
    end
  end

  @spec write_all(Path.t(), [{String.t(), iodata()}]) :: :ok | {:error, error()}
  def write_all(dir, attributes) do
    Enum.reduce_while(attributes, :ok, fn {name, value}, :ok ->
      case write(Path.join(dir, name), value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @spec write_existing(Path.t(), [{String.t(), iodata()}]) :: :ok | {:error, error()}
  def write_existing(dir, attributes) do
    write_all(
      dir,
      Enum.filter(attributes, fn {name, _value} -> File.exists?(Path.join(dir, name)) end)
    )
  end

  @spec mkdir(Path.t()) :: :ok | {:error, error()}
  def mkdir(path), do: check(File.mkdir_p(path), path)

  @spec link(Path.t(), Path.t()) :: :ok | {:error, error()}
  def link(target, path), do: check(File.ln_s(target, path), path)

  @spec unlink(Path.t()) :: :ok | {:error, error()}
  def unlink(path), do: check(File.rm(path), path)

  # configfs takes a directory's attributes and default groups with it. A
  # plain directory, as in tests, needs them gone first; configfs refuses to
  # delete an attribute, so there this changes nothing.
  @spec rmdir(Path.t()) :: :ok | {:error, error()}
  def rmdir(path) do
    case File.rmdir(path) do
      {:error, reason} when reason in [:eexist, :enotempty] ->
        case File.rm_rf(path) do
          {:ok, _removed} -> :ok
          {:error, _reason, _file} -> {:error, {:configfs, path, reason}}
        end

      result ->
        check(result, path)
    end
  end

  defp check(:ok, _path), do: :ok
  defp check({:error, reason}, path), do: {:error, {:configfs, path, reason}}
end
