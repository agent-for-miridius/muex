ExUnit.start()

defmodule Muex.TestCwd do
  @moduledoc false

  # For a test module that changes directory: `setup {Muex.TestCwd, :restore_on_exit}`.
  # File.cd!/2 changes back in an `after`, which a test killed by its timeout
  # never runs, and the directory is the whole VM's: every later test, and its
  # tmp_dir, would start from the killed test's directory.
  def restore_on_exit(_context) do
    cwd = File.cwd!()
    ExUnit.Callbacks.on_exit(fn -> File.cd!(cwd) end)
  end
end
