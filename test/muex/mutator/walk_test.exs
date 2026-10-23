defmodule Muex.Mutator.WalkTest do
  use ExUnit.Case, async: true

  alias Muex.Mutator
  alias Muex.Mutator.Arithmetic
  alias Muex.Mutator.FunctionCall
  alias Muex.Mutator.Literal

  # A minimal mutator that records the enclosing line supplied by the
  # traversal in `context[:line]`. Used to assert line propagation
  # independently of any particular built-in mutator.
  defmodule LineProbe do
    @moduledoc false
    @behaviour Muex.Mutator

    @impl true
    def mutate(node, context) when is_integer(node) do
      [
        %{
          ast: node,
          mutator: __MODULE__,
          description: "probe #{node}",
          location: %{file: Map.get(context, :file, "?"), line: Map.get(context, :line, 0)}
        }
      ]
    end

    def mutate(_node, _context), do: []

    @impl true
    def name, do: "LineProbe"

    @impl true
    def description, do: "probe"

    @impl true
    def supported_languages, do: [Muex.Language.Elixir, Muex.Language.Erlang]
  end

  defp ast!(source), do: Code.string_to_quoted!(source)

  # The node at `path`: tuple and list indices, from the root.
  defp follow(node, []), do: node
  defp follow(tuple, [index | rest]) when is_tuple(tuple), do: follow(elem(tuple, index), rest)
  defp follow(list, [index | rest]) when is_list(list), do: follow(Enum.at(list, index), rest)

  # Every mutant of `source` under `mutators` that does not compile, as
  # `{description, line, error}`. `source` must define one module, with a name
  # no other test compiles.
  defp invalid_mutants(source, mutators) do
    ast = ast!(source)
    entry = %{ast: ast, path: "s.ex"}

    for mutation <- Mutator.walk(ast, mutators, %{file: "s.ex"}),
        error = compile_error(mutation, entry),
        do: {mutation.description, mutation.location.line, error}
  end

  defp compile_error(mutation, entry) do
    {:ok, source} = Muex.Compiler.compile_to_source(mutation, entry, Muex.Language.Elixir)

    {result, diagnostics} =
      Code.with_diagnostics([log: false], fn ->
        try do
          {:ok, Code.compile_string(source)}
        rescue
          error -> {:error, Exception.message(error)}
        end
      end)

    case result do
      {:ok, modules} ->
        for {module, _binary} <- modules, do: :code.purge(module) && :code.delete(module)
        nil

      {:error, message} ->
        [message | for(%{severity: :error} = d <- diagnostics, do: d.message)]
    end
  end

  describe "line propagation" do
    test "leaf literals inherit the nearest enclosing line" do
      ast =
        ast!("""
        defmodule Sample do
          def run(x) do
            y = x + 41
            y - 1
          end
        end
        """)

      mutations = Mutator.walk(ast, [LineProbe], %{file: "sample.ex"})
      lines = mutations |> Enum.map(& &1.location.line) |> Enum.sort()

      # 41 is on line 3, 1 is on line 4 of the source above.
      assert 3 in lines
      assert 4 in lines
      refute 0 in lines
    end

    test "defaults the line to 0 when no enclosing metadata exists" do
      # A bare literal has no metadata and no enclosing node.
      assert [mutation] = Mutator.walk(7, [LineProbe], %{file: "bare.ex"})
      assert mutation.location.line == 0
    end
  end

  describe "structural pruning" do
    test "module alias segments are never mutated" do
      ast =
        ast!("""
        defmodule Sample do
          def run, do: Enum.count([1, 2])
        end
        """)

      mutations = Mutator.walk(ast, [Literal], %{file: "s.ex"})

      refute Enum.any?(mutations, &(&1.original_ast in [:Sample, :Enum]))
    end

    test "use/import/alias/require subtrees are skipped" do
      ast =
        ast!("""
        defmodule Sample do
          use GenServer
          import List
          alias Map, as: M
          require Logger
          def run, do: :ok
        end
        """)

      mutations = Mutator.walk(ast, [Literal, FunctionCall], %{file: "s.ex"})

      refute Enum.any?(
               mutations,
               &(&1.original_ast in [:GenServer, :List, :Map, :Logger, :as, :M])
             )
    end

    test "documentation attributes are not mutated" do
      ast =
        ast!(~S'''
        defmodule Sample do
          @moduledoc "module documentation"
          @doc "function documentation"
          def run, do: 1
        end
        ''')

      descriptions =
        ast
        |> Mutator.walk([Literal], %{file: "s.ex"})
        |> Enum.map(& &1.description)

      refute Enum.any?(descriptions, &String.contains?(&1, "documentation"))
    end

    test "keyword keys are skipped but their values are mutated" do
      ast =
        ast!("""
        defmodule Sample do
          def run, do: configure(timeout: 5)
        end
        """)

      mutations = Mutator.walk(ast, [Literal], %{file: "s.ex"})

      refute Enum.any?(mutations, &(&1.original_ast == :timeout))
      assert Enum.any?(mutations, &(&1.original_ast == 5))
    end

    test "the `|` of a map update is skipped but its operands are mutated" do
      ast =
        ast!("""
        defmodule Sample do
          def bump(state), do: %{state | count: state.count + 1}
        end
        """)

      mutations = Mutator.walk(ast, [Literal, FunctionCall, Arithmetic], %{file: "s.ex"})

      refute Enum.any?(mutations, &match?({:|, _meta, _args}, &1.original_ast))
      assert Enum.any?(mutations, &match?({:+, _meta, _args}, &1.original_ast))
      assert Enum.any?(mutations, &(&1.original_ast == 1))
    end

    test "the `|` of a struct update is skipped" do
      ast =
        ast!("""
        defmodule Sample do
          def bump(state), do: %Sample.State{state | count: 1}
        end
        """)

      mutations = Mutator.walk(ast, [Literal, FunctionCall], %{file: "s.ex"})

      refute Enum.any?(mutations, &match?({:|, _meta, _args}, &1.original_ast))
      assert Enum.any?(mutations, &(&1.original_ast == 1))
    end

    test "the `|` of a list cons is still mutated" do
      # `[head | tail]` is a different node in a different position: swapping
      # its arguments unparses and compiles, so it stays a real mutation.
      ast =
        ast!("""
        defmodule Sample do
          def prepend(head, tail), do: [head | tail]
        end
        """)

      mutations = Mutator.walk(ast, [FunctionCall], %{file: "s.ex"})

      assert Enum.any?(mutations, &match?({:|, _meta, _args}, &1.original_ast))
    end

    test "the `/` of a function capture is skipped; its function is walked, and the arity of a remote capture only, since a missing local arity does not compile" do
      # `&Path.dirname/1` and `&double/1` put a `/` under `&` that names the
      # arity. FunctionCall treated it as a call and removed it or swapped its
      # arguments, Arithmetic as division: none of those is a valid capture.
      # `&double/3` does not compile when `double/3` is not defined;
      # `&Path.dirname/2` compiles and fails when called.
      ast =
        ast!("""
        defmodule Sample do
          def run(xs), do: xs |> Enum.map(&Path.dirname/1) |> Enum.map(&double/2)
        end
        """)

      mutations = Mutator.walk(ast, [Literal, FunctionCall, Arithmetic], %{file: "s.ex"})

      refute Enum.any?(mutations, &match?({:/, _meta, _args}, &1.original_ast))

      # A remote function's name is never offered; see "remote calls".
      assert [1, 1] =
               mutations
               |> Enum.map(& &1.original_ast)
               |> Enum.filter(&(&1 in [:dirname, 1, 2]))
    end

    test "no mutant of a local, imported or operator capture fails to compile" do
      source = """
      defmodule Muex.WalkTest.Captures do
        def double(x), do: x * 2
        def run(xs), do: {Enum.map(xs, &double/1), Enum.reduce(xs, &+/2), Enum.reduce(xs, &max/2)}
      end
      """

      assert invalid_mutants(source, Muex.Config.all_mutators()) == []
    end

    test "the operands of a capture's `/` take the `/` line" do
      ast =
        ast!("""
        defmodule Sample do
          def run(xs) do
            Enum.map(xs, &(
              Path.dirname/1
            ))
          end
        end
        """)

      mutations = Mutator.walk(ast, [Literal], %{file: "s.ex"})

      assert [4, 4] = for(%{original_ast: 1} = m <- mutations, do: m.location.line)
    end

    test "no mutant inside a capture's body fails to compile" do
      source = """
      defmodule Muex.WalkTest.CaptureBodies do
        def run(xs) do
          {Enum.map(xs, &(&1 + 1)), Enum.reduce(xs, 0, &(&1 + &2)), Enum.map(xs, &max(&1, 2)),
           Enum.map(xs, &{&1, :x}), Enum.reduce(xs, 0, &(&2 - &1)), Enum.reduce(xs, [], &[&1 | &2])}
        end
      end
      """

      assert invalid_mutants(source, Muex.Config.all_mutators()) == []
    end

    test "inside a capture, mutations that keep every placeholder are still offered" do
      ast = ast!("defmodule Sample, do: def(run(xs), do: Enum.reduce(xs, 0, &(&1 + &2 * 3)))")

      changed =
        for %{ast: ast, original_ast: original} <- Mutator.walk(ast, [Arithmetic, Literal], %{}),
            do: {Macro.to_string(original), Macro.to_string(ast)}

      assert {"&1 + &2 * 3", "&1 - &2 * 3"} in changed
      assert {"&2 * 3", "&2 / 3"} in changed
      assert {"3", "4"} in changed
      refute Enum.any?(changed, &match?({_, "0"}, &1))
    end

    test "the `/` of division inside a capture is still mutated" do
      ast =
        ast!("""
        defmodule Sample do
          def halve(xs), do: Enum.map(xs, &(&1 / 2))
        end
        """)

      mutations = Mutator.walk(ast, [FunctionCall, Arithmetic], %{file: "s.ex"})

      assert Enum.any?(mutations, &match?({:/, _meta, _args}, &1.original_ast))
    end
  end

  describe "definition heads" do
    @heads """
    defmodule Muex.WalkTest.Heads do
      defguard is_pos(x) when is_integer(x) and x > 0
      def add(a, b) when is_number(a) and is_number(b), do: a + b
      defp scale(a, b \\\\ 2), do: a * b
      def zero(n) when is_pos(n), do: scale(n)
      def tag({:ok, v}, [h | t]), do: {v, h, t}
      def bin("pre" <> rest, <<c::size(8), _::binary>>), do: {rest, c}
      defmacro twice(x, y), do: quote(do: unquote(x) + unquote(y))
      defdelegate sum(a, b), to: Kernel, as: :+
    end
    """

    test "no mutant of a head fails to compile" do
      assert invalid_mutants(@heads, Muex.Config.all_mutators()) == []
    end

    test "the head is never offered; parameters, defaults and guards are" do
      mutations = Mutator.walk(ast!(@heads), Muex.Config.all_mutators(), %{file: "s.ex"})
      originals = Enum.map(mutations, &Macro.to_string(&1.original_ast))

      for head <- ["add(a, b)", "scale(a, b \\\\ 2)", "b \\\\ 2", "is_pos(x)", "sum(a, b)"] do
        refute head in originals
      end

      assert 2 in Enum.map(mutations, & &1.original_ast)
      assert "pre" in Enum.map(mutations, & &1.original_ast)
      assert "Guard: replace guard with true" in Enum.map(mutations, & &1.description)
      assert "is_number(a) and is_number(b)" in originals
    end
  end

  describe "patterns" do
    @patterns """
    defmodule Muex.WalkTest.Patterns do
      def run(x, bin, xs) do
        [h | t] = xs
        "pre" <> rest = bin
        a = case x do
          {p, q} when p > q -> p - q
          [m | n] -> {m, n}
          _ -> 0
        end
        f = fn [c | d] -> {c, d}; "pre" <> s -> s end
        w = with {:ok, z} <- {:ok, x}, [e | g] <- xs do
          {z, e, g}
        else
          [k | l] -> {k, l}
        end
        v = for [i | j] <- [xs], <<b::size(8) <- bin>>, do: {i, j, b}
        r = receive do
          {:msg, [aa | bb]} -> {aa, bb}
        after
          max(1, 2) -> :timeout
        end
        c = cond do
          max(x, 1) > 2 -> :big
          true -> :small
        end
        tr = try do
          x
        catch
          :throw, [ta | tb] -> {ta, tb}
        end
        {h, t, rest, a, f, w, v, r, c, tr}
      end
    end
    """

    test "no mutant of a pattern fails to compile" do
      assert invalid_mutants(@patterns, Muex.Config.all_mutators()) == []
    end

    test "guards, `cond` conditions and `after` timeouts are still expressions" do
      mutations = Mutator.walk(ast!(@patterns), [FunctionCall], %{file: "s.ex"})
      originals = Enum.map(mutations, &Macro.to_string(&1.original_ast))

      assert "p > q" in originals
      assert "max(1, 2)" in originals
      assert "max(x, 1) > 2" in originals
      refute "h | t" in originals
      refute "\"pre\" <> rest" in originals
    end
  end

  describe "pipes" do
    @pipes """
    defmodule Muex.WalkTest.Pipes do
      def run(xs, f), do: xs |> Enum.map(f) |> Enum.reduce(0, f) |> max(length(xs))
    end
    """

    test "no mutant of a pipe fails to compile" do
      assert invalid_mutants(@pipes, Muex.Config.all_mutators()) == []
    end

    test "a pipe's target keeps its argument swap; its arguments are still removable" do
      mutations = @pipes |> ast!() |> Mutator.walk([FunctionCall], %{file: "s.ex"})

      changed =
        for %{ast: ast, original_ast: original} <- mutations,
            do: {Macro.to_string(original), ast && Macro.to_string(ast)}

      assert {"Enum.reduce(0, f)", "Enum.reduce(f, 0)"} in changed
      assert [{"length(xs)", nil}] == Enum.filter(changed, &match?({_, nil}, &1))
    end
  end

  describe "module attributes" do
    @attributes """
    defmodule Muex.WalkTest.Attributes do
      @timeout 5_000
      @limits [1, max(2, 3)]
      def run, do: @timeout * length(@limits)
    end
    """

    test "no mutant of a module attribute fails to compile" do
      assert invalid_mutants(@attributes, Muex.Config.all_mutators()) == []
    end

    test "an attribute's name is never offered; its value and the attribute are" do
      mutations = @attributes |> ast!() |> Mutator.walk([FunctionCall, Literal], %{file: "s.ex"})
      originals = Enum.map(mutations, &Macro.to_string(&1.original_ast))

      refute "timeout(5000)" in originals
      assert "@timeout 5000" in originals
      assert 5_000 in Enum.map(mutations, & &1.original_ast)
      assert 3 in Enum.map(mutations, & &1.original_ast)
    end
  end

  describe "sigils" do
    @sigils ~S'''
    defmodule Muex.WalkTest.Sigils do
      def run(name) do
        t = ~s(raw #{name} and #{name})
        {t, Regex.match?(~r/ab+c/i, t), ~w(a b c)a, ~S(upper), ~c"chars"}
      end
    end
    '''

    test "no mutant of a sigil fails to compile" do
      assert invalid_mutants(@sigils, Muex.Config.all_mutators()) == []
    end

    test "a sigil can be removed and its text mutated" do
      mutations = @sigils |> ast!() |> Mutator.walk([FunctionCall, Literal], %{file: "s.ex"})

      changed =
        for %{ast: ast, original_ast: original} <- mutations,
            do: {Macro.to_string(original), ast && Macro.to_string(ast)}

      assert {"~r/ab+c/i", nil} in changed
      assert {"\"ab+c\"", "\"\""} in changed
      assert {"\"raw \#{name} and \#{name}\"", "\"\#{name}raw  and \#{name}\""} in changed
    end
  end

  describe "`in` in guards" do
    @guard_ins """
    defmodule Muex.WalkTest.GuardIns do
      defguard is_small(v) when v in 1..10
      def run(x, y) when x in [1, 2] do
        f = fn z when z not in [3] -> z end
        case y do
          z when z in [1, 2] and is_small(z) -> f.(z)
          _ -> y in [x]
        end
      end
    end
    """

    test "no mutant of an `in` in a guard fails to compile" do
      assert invalid_mutants(@guard_ins, Muex.Config.all_mutators()) == []
    end

    test "outside a guard `in` is still swapped; inside one its right side is still mutated" do
      mutations = @guard_ins |> ast!() |> Mutator.walk([FunctionCall], %{file: "s.ex"})

      changed =
        for %{ast: ast, original_ast: original} <- mutations,
            do: {Macro.to_string(original), ast && Macro.to_string(ast)}

      assert {"y in [x]", "[x] in y"} in changed
      assert {"1..10", "10..1"} in changed
      assert {"v in 1..10", nil} in changed
    end

    test "a module attribute read right of `in` in a guard is not removed" do
      source = "def run(x) when x in @limits, do: x"
      mutations = source |> ast!() |> Mutator.walk([FunctionCall], %{file: "s.ex"})

      refute Enum.any?(mutations, &match?(%{original_ast: {:@, _, _}, ast: nil}, &1))
    end
  end

  describe "`<>`" do
    @concats """
    defmodule Muex.WalkTest.Concats do
      @prefix "p" <> String.upcase("q")
      def run(x), do: {@prefix, String.upcase(x) <> "y", "p" <> String.downcase(x) <> x}
    end
    """

    test "no mutant of a `<>` fails to compile" do
      assert invalid_mutants(@concats, Muex.Config.all_mutators()) == []
    end

    test "a `<>` is still removed and swapped, and its operands still mutated" do
      mutations = @concats |> ast!() |> Mutator.walk([FunctionCall, Literal], %{file: "s.ex"})

      changed =
        for %{ast: ast, original_ast: original} <- mutations,
            do: {Macro.to_string(original), ast && Macro.to_string(ast)}

      assert {"String.upcase(x) <> \"y\"", nil} in changed
      assert {"String.upcase(x) <> \"y\"", "\"y\" <> String.upcase(x)"} in changed
      assert {"\"y\"", "\"\""} in changed
      refute {"String.upcase(x)", nil} in changed
    end
  end

  describe "module bodies" do
    @module_body """
    defmodule Muex.WalkTest.ModuleBody do
      Module.register_attribute(__MODULE__, :acc, accumulate: true)
      @acc max(1, 2)
      @joined Enum.join(["a", "b"], ",")
      @q div(10, 3)
      defstruct Enum.concat([:a], [:b])

      for f <- Enum.reverse([:x, :y]) do
        def unquote(:"get_\#{f}")(), do: unquote(f)
      end

      def run(xs), do: {@acc, @joined, @q, Enum.join(xs, ","), div(7, 2)}
    end
    """

    test "no FunctionCall mutant of a module body fails to compile" do
      assert invalid_mutants(@module_body, [FunctionCall]) == []
    end

    test "a module body's statements are still removed, and calls in a definition still swapped and removed" do
      mutations = @module_body |> ast!() |> Mutator.walk([FunctionCall], %{file: "s.ex"})

      changed =
        for %{ast: ast, original_ast: original} <- mutations,
            do: {Macro.to_string(original), ast && Macro.to_string(ast)}

      assert {"Module.register_attribute(__MODULE__, :acc, accumulate: true)", nil} in changed
      assert {"Enum.join(xs, \",\")", "Enum.join(\",\", xs)"} in changed
      assert {"div(7, 2)", "div(2, 7)"} in changed
      assert {"div(7, 2)", nil} in changed
      refute {"div(10, 3)", "div(3, 10)"} in changed
      refute {"div(10, 3)", nil} in changed
    end

    @compile_time_reads """
    defmodule Muex.WalkTest.CompileTimeReads do
      @limits [1, 2]
      @fields [:a, :b]
      @names [:x]
      @n 8
      @runtime 5
      @all @names ++ [:y]
      defstruct @fields

      for f <- @all do
        def unquote(f)(), do: unquote(f)
      end

      def limited(x) when x in @limits, do: x
      def sized(<<x::size(@n), _rest::binary>>), do: x
      def run, do: @runtime
    end
    """

    test "no mutant removing an attribute the module reads at compile time fails to compile" do
      assert invalid_mutants(@compile_time_reads, [FunctionCall]) == []
    end

    test "an attribute definition read only in a function body is still removed" do
      mutations = @compile_time_reads |> ast!() |> Mutator.walk([FunctionCall], %{file: "s.ex"})

      removed =
        for %{ast: nil, original_ast: {:@, _, [{_name, _, [_value]}]} = original} <- mutations,
            do: Macro.to_string(original)

      assert removed == ["@runtime 5"]
    end
  end

  describe "remote calls" do
    @remote_calls """
    defmodule Muex.WalkTest.RemoteCalls do
      Module.register_attribute(__MODULE__, :acc, accumulate: true)
      @joined Enum.join(["a", "b"], ",")
      def run(m, x), do: {@joined, m.key, :erlang.atom_to_binary(x), Enum.map([x], &String.upcase/1)}
    end
    """

    test "a remote call's function name is never offered" do
      mutations = @remote_calls |> ast!() |> Mutator.walk([Literal], %{file: "s.ex"})
      originals = Enum.map(mutations, & &1.original_ast)

      for name <- [:register_attribute, :join, :atom_to_binary, :map, :upcase],
          do: refute(name in originals)

      assert :key in originals
      assert :erlang in originals
      assert :acc in originals
    end

    test "no Literal mutant of a remote call fails to compile" do
      assert invalid_mutants(@remote_calls, [Literal]) == []
    end
  end

  describe "configurable skip_calls" do
    test "prunes configured DSL calls, leaving the rest intact" do
      ast =
        ast!("""
        defmodule Sample do
          attr :class, :string
          def run, do: 7
        end
        """)

      with_skip = Mutator.walk(ast, [Literal], %{file: "s.ex", skip_calls: [:attr]})
      without_skip = Mutator.walk(ast, [Literal], %{file: "s.ex"})

      refute Enum.any?(with_skip, &(&1.original_ast in [:class, :string]))
      assert Enum.any?(without_skip, &(&1.original_ast in [:class, :string]))
      # The unrelated function body literal is still mutated.
      assert Enum.any?(with_skip, &(&1.original_ast == 7))
    end
  end

  describe "original_ast and backwards compatibility" do
    test "every mutation is augmented with the matched original_ast" do
      ast = ast!("def add(a, b), do: a + b")

      mutations = Mutator.walk(ast, [Arithmetic], %{file: "s.ex"})

      assert Enum.all?(mutations, &Map.has_key?(&1, :original_ast))
      assert Enum.any?(mutations, &match?({:+, _meta, _args}, &1.original_ast))
    end

    test "every mutation's ast_path leads to its original_ast" do
      # Muex.Compiler replaces the node at `:ast_path` and falls back to
      # matching on the line when the position is wrong, so a wrong position
      # would not fail loudly: the mutant would quietly rewrite every equal
      # node on its line again. This source goes through every clause of the
      # walk: map and struct updates, captures, remote calls, keyword and
      # literal pairs, lists, attributes and blocks.
      ast =
        ast!("""
        defmodule Sample do
          @limit 10
          def run(s, xs) do
            s = %{hd([s]) | count: s.count + 1, seen: [1, 2 + 3]}
            t = %Sample.State{s | total: {s.count * 2, :ok}}
            ys = Enum.map(xs, &Path.dirname/1) ++ Enum.map(xs, &(&1 / 2))
            case Map.get(t, :total, 1 - 1) do
              {n, :ok} when n > @limit -> [x: n + 1 + (n + 1)]
              _ -> ys |> Enum.reverse() |> hd()
            end
          end
        end
        """)

      mutations = Mutator.walk(ast, Muex.Config.all_mutators(), %{file: "s.ex"})

      assert length(mutations) > 50

      for mutation <- mutations do
        assert follow(ast, mutation.ast_path) == mutation.original_ast,
               "#{mutation.description} at #{inspect(mutation.ast_path)}"
      end
    end

    test "remote call arguments are still traversed" do
      ast = ast!("def run, do: String.duplicate(\"ab\", 3)")

      mutations = Mutator.walk(ast, [Literal], %{file: "s.ex"})

      assert Enum.any?(mutations, &(&1.original_ast == "ab"))
      assert Enum.any?(mutations, &(&1.original_ast == 3))
    end
  end
end
