defmodule Muex.Mutator.FunctionCall do
  @moduledoc """
  Mutator for function calls.

  Applies mutations to function calls:
  - Remove function calls (replace with nil)
  - Swap function arguments (when there are 2+ args)

  A pattern holds no calls, so nothing in one is mutated. Removing a pattern
  unbinds its variables, and swapping `"pre" <> rest` makes a binary pattern
  that does not compile. A node the walk marks `:irreplaceable` is not
  removed either: `value |> nil` does not compile (`Muex.Mutator.Pipe` drops
  the stage), nor does a sigil with `nil` for its text, nor `x in nil` in a
  guard, nor `nil <> "x"`. The arguments of a
  sigil, `raise`, `reraise`, and `in` in a guard are not swapped.

  In a module body, outside its definitions, and in a macro's body outside
  the code it quotes (see `Muex.Mutator.walk/3`), no call is swapped, and
  only an attribute definition or the body's last statement is removed: that
  code runs at compile time, and `Muex.Mutator.StatementDeletion` deletes
  the other statements. Nor is a statement removed that defines what the
  module reads at compile time, such as an attribute read in a definition's
  head or in the module body, or a `defexception`, which other modules may
  build.
  """
  @behaviour Muex.Mutator

  alias Muex.Mutator.References

  @commutative_ops [:+, :*, :==, :!=, :===, :!==, :and, :or, :&&, :||]
  @impl true
  def name do
    "FunctionCall"
  end

  @impl true
  def description do
    "Mutates function calls (remove calls, swap arguments)"
  end

  @impl true
  def supported_languages, do: [Muex.Language.Elixir, Muex.Language.Erlang]

  @impl true
  def mutate(_ast, %{pattern: true}), do: []

  def mutate(ast, context) do
    case ast do
      {func, meta, args} when is_atom(func) and is_list(args) and args != [] ->
        line = Keyword.get(meta, :line, 0)

        if special_form?(func) do
          []
        else
          removal(ast, "remove #{func}() call", context, line) ++
            swap(ast, "#{func}", swappable?(func, context), context, line)
        end

      {{:., _dot_meta, [module, func]}, meta, args} when is_list(args) and args != [] ->
        line = Keyword.get(meta, :line, 0)

        removal(ast, "remove #{inspect(module)}.#{func}() call", context, line) ++
          swap(ast, "#{inspect(module)}.#{func}", true, context, line)

      _ ->
        []
    end
  end

  @impl true
  def equivalent?(%{description: description, ast: {func, _, _}}) when is_atom(func) do
    String.contains?(description, "swap arguments") and func in @commutative_ops
  end

  def equivalent?(%{description: description, ast: {{:., _, [_, func]}, _, _}}) do
    String.contains?(description, "swap arguments") and func in @commutative_ops
  end

  def equivalent?(_mutation), do: false

  defp special_form?(func) do
    func in [
      :def,
      :defp,
      :defmacro,
      :defmacrop,
      :defdelegate,
      :defguard,
      :defguardp,
      :defmodule,
      :defstruct,
      :import,
      :require,
      :alias,
      :use,
      :quote,
      :unquote,
      :if,
      :unless,
      :case,
      :cond,
      :for,
      :with,
      :receive,
      :try,
      :__block__,
      :=,
      :|>,
      :.,
      :&,
      :->,
      :<-,
      :when,
      :fn,
      :"::",
      :%{},
      :%
    ]
  end

  defp removal(_ast, _description, %{irreplaceable: true}, _line), do: []

  # A module body runs when the module compiles, so a call whose value it uses
  # cannot become `nil` (`defstruct nil`, `for f <- nil`). Of its statements,
  # StatementDeletion deletes all but attribute definitions and the last one;
  # those are removed here, unless they define what the module reads at
  # compile time (`@limits` in `x in @limits` in a guard).
  defp removal(ast, description, %{module_body: statements, statement: true} = context, line) do
    if (attribute_definition?(ast) or ast == List.last(statements)) and
         not References.still_referenced?(ast, List.delete(statements, ast)),
       do: [build_mutation(nil, description, context, line)],
       else: []
  end

  defp removal(_ast, _description, %{module_body: _}, _line), do: []

  defp removal(_ast, description, context, line),
    do: [build_mutation(nil, description, context, line)]

  defp attribute_definition?({:@, _meta, [{_name, _attribute_meta, [_value]}]}), do: true
  defp attribute_definition?(_ast), do: false

  # Swap a call's first two arguments.
  # In a module body a swap mostly raises when the module compiles
  # (`Enum.join(",", list)`).
  defp swap(_ast, _name, _swappable?, %{module_body: _}, _line), do: []

  defp swap({call, meta, [first, second | rest]}, name, true, context, line) do
    [
      build_mutation(
        {call, meta, [second, first | rest]},
        "swap arguments in #{name}()",
        context,
        line
      )
    ]
  end

  defp swap(_ast, _name, _swappable?, _context, _line), do: []

  # Kernel's sigils are macros that take the text first and the modifiers
  # second; swapped, they do not compile. Nor does `[1, 2] in x` in a guard,
  # which needs a list or range on the right when it compiles. `raise(Mod,
  # attrs)` expands to `Mod.exception(attrs)`, so swapped it does not compile
  # when `attrs` is a literal string, number or list, and otherwise only
  # raises something else; `reraise` is the same.
  defp swappable?(:in, %{guard: true}), do: false
  defp swappable?(func, _context) when func in [:raise, :reraise], do: false
  defp swappable?(func, _context), do: not Muex.Mutator.sigil?(func)

  defp build_mutation(mutated_ast, description, context, line) do
    %{
      ast: mutated_ast,
      mutator: __MODULE__,
      description: "#{name()}: #{description}",
      location: %{file: Map.get(context, :file, "unknown"), line: line}
    }
  end
end
