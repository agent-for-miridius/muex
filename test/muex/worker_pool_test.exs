defmodule Muex.WorkerPoolTest do
  use ExUnit.Case, async: true

  alias Muex.WorkerPool

  describe "start_link/1" do
    test "starts worker pool with default max_workers" do
      assert {:ok, pid} = WorkerPool.start_link()
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "starts worker pool with custom max_workers" do
      assert {:ok, pid} = WorkerPool.start_link(max_workers: 8)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "run_mutations/7" do
    test "returns empty list for no mutations" do
      {:ok, pool} = WorkerPool.start_link(max_workers: 2)

      file_entry = %{
        path: "test/fixtures/sample.ex",
        ast: {:defmodule, [], []},
        module_name: Sample
      }

      results =
        WorkerPool.run_mutations(
          pool,
          [],
          file_entry,
          Muex.Language.Elixir,
          %{},
          %{},
          timeout_ms: 1000
        )

      assert results == []
      GenServer.stop(pool)
    end

    # `mix test` given no files runs every test, so a mutant with no selected
    # test would be judged by the whole suite. The run must stop instead.
    @tag :tmp_dir
    test "refuses a mutant with no selected test file", %{tmp_dir: tmp_dir} do
      {:ok, pool} = WorkerPool.start_link(max_workers: 1)

      mutation = %{location: %{file: "lib/sample.ex", line: 1}}
      file_entry = %{path: "lib/sample.ex", ast: {:defmodule, [], []}, module_name: Sample}

      assert {:error, message} =
               WorkerPool.run_mutations(
                 pool,
                 [mutation],
                 %{"lib/sample.ex" => file_entry},
                 Muex.Language.Elixir,
                 %{},
                 %{"lib/sample.ex" => Sample},
                 timeout_ms: 1000,
                 project_root: tmp_dir,
                 test_paths: [Path.join(tmp_dir, "no_such_test_dir")]
               )

      assert message =~ "no test file was selected"
      assert message =~ "lib/sample.ex"
      GenServer.stop(pool)
    end

    # A crash inside muex says nothing about the tests. It used to be recorded as
    # a timeout, which the high score bound counts as killed.
    @tag :tmp_dir
    test "records a worker that raises as invalid, with the error", %{tmp_dir: tmp_dir} do
      assert [%{result: :invalid, error: error, test_files: []}] =
               run_one_with_adapter(tmp_dir, __MODULE__.RaisingAdapter)

      assert error =~ "muex crashed while running this mutant"
      assert error =~ "RuntimeError"
      assert error =~ "unparse blew up"
    end

    @tag :tmp_dir
    test "records a worker that exits as invalid, with the reason", %{tmp_dir: tmp_dir} do
      assert [%{result: :invalid, error: error}] =
               run_one_with_adapter(tmp_dir, __MODULE__.ExitingAdapter)

      assert error =~ "muex crashed while running this mutant"
      assert error =~ ":unparse_gave_up"
    end

    # Each worker has its own sandbox, with its own copy of the file.
    @tag :tmp_dir
    test "runs mutants of the same file at the same time", %{tmp_dir: tmp_dir} do
      Process.register(self(), __MODULE__.BlockingAdapter)
      run = Task.async(fn -> run_with_adapter(tmp_dir, __MODULE__.BlockingAdapter, 2, 2) end)

      # Building the sandboxes comes first. It starts `mix` three times, which
      # takes about a second on an idle machine and tens of seconds on a busy
      # one, so only the test's own timeout bounds it.
      first = receive do: ({:unparsing, pid} -> pid)
      assert_receive {:unparsing, second}, 10_000
      Enum.each([first, second], &send(&1, :go))

      assert [%{result: :invalid}, %{result: :invalid}] = Task.await(run)
    end

    @tag :tmp_dir
    test "refuses an umbrella target outside apps/", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "apps"))
      {:ok, pool} = WorkerPool.start_link(max_workers: 1)

      mutation = %{location: %{file: "lib/root.ex", line: 1}}
      file_entry = %{path: "lib/root.ex", ast: {:defmodule, [], []}, module_name: Root}

      assert {:error, message} =
               WorkerPool.run_mutations(
                 pool,
                 [mutation],
                 %{"lib/root.ex" => file_entry},
                 Muex.Language.Elixir,
                 %{},
                 %{},
                 timeout_ms: 1000,
                 project_root: tmp_dir,
                 test_paths: [tmp_dir]
               )

      assert message =~ "only files under apps/<app>/ can be mutated"
      GenServer.stop(pool)
    end
  end

  describe "terminate/2" do
    # The pool used to remove the sandboxes and leave each running `mix test`
    # to finish, which then wrote its build files back into the removed tree.
    @tag :tmp_dir
    test "stops a running mutant's `mix test` before removing the sandboxes",
         %{tmp_dir: tmp_dir} do
      # The mutant's test sends its OS pid here, then hangs. (Not a FIFO: while
      # File.read!/1 waits on one, the pool never builds its sandbox.)
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listener)
      project = Path.join(tmp_dir, "project")
      write_hanging_project!(project, port)

      {:ok, pool} = GenServer.start(WorkerPool, max_workers: 1)
      {:ok, ast} = Code.string_to_quoted(File.read!(Path.join(project, "lib/hang.ex")))

      [mutation | _] =
        Muex.Mutator.walk(ast, [Muex.Mutator.Literal], %{file: "lib/hang.ex"})

      spawn(fn ->
        WorkerPool.run_mutations(
          pool,
          [mutation],
          %{"lib/hang.ex" => %{path: "lib/hang.ex", ast: ast, module_name: Hang}},
          Muex.Language.Elixir,
          %{},
          %{"lib/hang.ex" => Hang},
          timeout_ms: 60_000,
          project_root: project,
          test_paths: [Path.join(project, "test")]
        )
      end)

      {:ok, socket} = :gen_tcp.accept(listener, 50_000)
      {:ok, os_pid} = :gen_tcp.recv(socket, 0, 5_000)
      on_exit(fn -> System.cmd("kill", ["-9", os_pid], stderr_to_stdout: true) end)
      [%{base: base} | _] = :sys.get_state(pool).sandboxes

      GenServer.stop(pool, :shutdown)

      assert {_, 1} = System.cmd("ps", ["-p", os_pid], stderr_to_stdout: true)
      refute File.exists?(base)
    end
  end

  defp write_hanging_project!(project, port) do
    files = %{
      "mix.exs" => """
      defmodule Hang.MixProject do
        use Mix.Project
        def project, do: [app: :hang, version: "0.1.0"]
      end
      """,
      "lib/hang.ex" => "defmodule Hang do\n  def one, do: 1\nend\n",
      "test/test_helper.exs" => "ExUnit.start()\n",
      # Passes unmutated; a mutant hangs.
      "test/hang_test.exs" => """
      defmodule HangTest do
        use ExUnit.Case

        test "one" do
          if Hang.one() != 1 do
            {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, #{port}, [:binary])
            :ok = :gen_tcp.send(socket, System.pid())
            Process.sleep(:infinity)
          end
        end
      end
      """
    }

    for {path, content} <- files do
      full = Path.join(project, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end
  end

  describe "deadline" do
    # The pool is driven through handle_info/2 with a hand-built state, so no
    # sandbox or `mix test` run is needed to check what the deadline does.
    test "drops the queued mutants and replies once the running one finishes" do
      ref = make_ref()
      running = mutation(1)

      {state, worker_ref} =
        running_state(running, [mutation(2), mutation(3)], deadline_ref: ref)

      assert {:noreply, state} = WorkerPool.handle_info({:deadline, ref}, state)
      assert state.dropped_mutations == 2
      assert state.pending_by_file == %{}
      refute_received {:reply, _}

      assert {:noreply, _} =
               WorkerPool.handle_info({:worker_done, worker_ref, result(running)}, state)

      assert_received {:reply, {:partial, [%{mutation: ^running}], partial}}
      assert partial == %{mutations_run: 1, mutations_total: 3}
    end

    test "replies at once when nothing is running" do
      ref = make_ref()

      state = %WorkerPool.State{
        opts: [],
        caller: {self(), :reply},
        total_mutations: 4,
        pending_by_file: %{"lib/a.ex" => :queue.from_list([mutation(1)])},
        results: [result(mutation(0))],
        completed_mutations: 3,
        deadline_ref: ref
      }

      assert {:noreply, _} = WorkerPool.handle_info({:deadline, ref}, state)
      assert_received {:reply, {:partial, [_], %{mutations_run: 1, mutations_total: 4}}}
    end

    test "is not partial when every mutant had already started" do
      ref = make_ref()
      running = mutation(1)
      {state, worker_ref} = running_state(running, [], deadline_ref: ref)

      assert {:noreply, state} = WorkerPool.handle_info({:deadline, ref}, state)
      assert state.dropped_mutations == 0

      assert {:noreply, _} =
               WorkerPool.handle_info({:worker_done, worker_ref, result(running)}, state)

      assert_received {:reply, [%{mutation: ^running}]}
    end

    test "replies with the plain list when there is no deadline" do
      running = mutation(1)
      {state, worker_ref} = running_state(running, [])

      assert {:noreply, _} =
               WorkerPool.handle_info({:worker_done, worker_ref, result(running)}, state)

      assert_received {:reply, [%{mutation: ^running}]}
    end

    test "ignores a tick that is not the current run's" do
      {state, _} = running_state(mutation(1), [mutation(2)], deadline_ref: make_ref())

      assert {:noreply, ^state} = WorkerPool.handle_info({:deadline, make_ref()}, state)
    end

    test "ignores a tick that arrives after the reply" do
      ref = make_ref()
      state = %WorkerPool.State{caller: nil, deadline_ref: ref}

      assert {:noreply, ^state} = WorkerPool.handle_info({:deadline, ref}, state)
    end

    test "a stopped run is still an error, not a partial result" do
      ref = make_ref()
      running = mutation(1)
      {state, worker_ref} = running_state(running, [mutation(2)], deadline_ref: ref)
      {:noreply, state} = WorkerPool.handle_info({:deadline, ref}, state)

      assert {:noreply, _} =
               WorkerPool.handle_info({:worker_done, worker_ref, {:stop, "broken"}}, state)

      assert_received {:reply, {:error, "broken"}}
    end

    test "spread/2 keeps the order when there is no deadline" do
      queues = %{"lib/a.ex" => :queue.from_list(Enum.map(1..20, &mutation/1))}

      assert WorkerPool.spread(queues, nil) == queues
    end

    test "spread/2 shuffles each file's queue the same way every time" do
      mutations = Enum.map(1..20, &mutation/1)
      queues = %{"lib/a.ex" => :queue.from_list(mutations)}

      assert %{"lib/a.ex" => spread} = WorkerPool.spread(queues, 60_000)
      assert %{"lib/a.ex" => again} = WorkerPool.spread(queues, 60_000)

      assert :queue.to_list(spread) != mutations
      assert Enum.sort_by(:queue.to_list(spread), & &1.location.line) == mutations
      assert spread == again
    end
  end

  # Language adapters that fail while rendering the mutant, which the worker
  # does after choosing tests and before anything touches the sandbox.
  defmodule RaisingAdapter do
    def unparse(_ast), do: raise("unparse blew up")
  end

  defmodule ExitingAdapter do
    def unparse(_ast), do: exit(:unparse_gave_up)
  end

  # Tells the test process (registered under this module's name) that a worker
  # has started, and holds that worker until the test lets it go.
  defmodule BlockingAdapter do
    def unparse(_ast) do
      send(__MODULE__, {:unparsing, self()})

      receive do
        :go -> exit(:released)
      end
    end
  end

  defp mutation(line) do
    %{
      mutator: Muex.Mutator.Arithmetic,
      description: "mutation #{line}",
      location: %{file: "lib/a.ex", line: line}
    }
  end

  defp result(mutation) do
    %{mutation: mutation, result: :killed, duration_ms: 1, error: nil, test_files: []}
  end

  # One worker running `running`, the mutants in `queued` not yet started.
  defp running_state(running, queued, extra \\ []) do
    worker_ref = make_ref()
    monitor_ref = make_ref()

    state = %WorkerPool.State{
      max_workers: 1,
      opts: [],
      caller: {self(), :reply},
      total_mutations: 1 + length(queued),
      pending_by_file: if(queued == [], do: %{}, else: %{"lib/a.ex" => :queue.from_list(queued)}),
      active_workers: %{worker_ref => {running, "lib/a.ex", 0, monitor_ref, self()}},
      monitor_to_worker: %{monitor_ref => worker_ref},
      deadline_ref: Keyword.get(extra, :deadline_ref)
    }

    {state, worker_ref}
  end

  defp run_one_with_adapter(tmp_dir, adapter), do: run_with_adapter(tmp_dir, adapter, 1, 1)

  defp run_with_adapter(tmp_dir, adapter, mutant_count, max_workers) do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.mkdir_p!(Path.join(tmp_dir, "test"))

    File.write!(Path.join(tmp_dir, "mix.exs"), """
    defmodule Crash.MixProject do
      use Mix.Project
      def project, do: [app: :crash, version: "0.1.0"]
    end
    """)

    File.write!(Path.join(tmp_dir, "lib/crash.ex"), "defmodule Crash do\n  def one, do: 1\nend\n")
    File.write!(Path.join(tmp_dir, "test/crash_test.exs"), "")

    {:ok, pool} = WorkerPool.start_link(max_workers: max_workers)
    {:ok, ast} = Code.string_to_quoted(File.read!(Path.join(tmp_dir, "lib/crash.ex")))
    file_entry = %{path: "lib/crash.ex", ast: ast, module_name: Crash}

    mutations =
      ast
      |> Muex.Mutator.walk([Muex.Mutator.Literal], %{file: "lib/crash.ex"})
      |> Enum.take(mutant_count)

    results =
      WorkerPool.run_mutations(
        pool,
        mutations,
        %{"lib/crash.ex" => file_entry},
        adapter,
        %{},
        %{"lib/crash.ex" => Crash},
        timeout_ms: 10_000,
        project_root: tmp_dir,
        test_paths: [Path.join(tmp_dir, "test")]
      )

    GenServer.stop(pool)
    results
  end
end
