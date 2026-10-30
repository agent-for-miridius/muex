defmodule Muex.Mutator do
  @moduledoc """
  Behaviour for mutation operators that transform AST nodes.

  Mutators implement specific mutation strategies (e.g., arithmetic operators,
  boolean operators, literals) and return a list of possible mutations for a given AST.

  Each mutator declares which languages it supports via `supported_languages/0`.
  Mutators targeting the same AST family (e.g., Elixir and Erlang both use BEAM
  AST) can declare support for multiple languages.

  ## Traversal and Pruning

  `walk/3` performs a context-aware, pre-order traversal of the AST. It threads
  the nearest enclosing source line through `context[:line]` and prunes subtrees
  that should never be mutated (module aliases, `use`/`import`/`alias`/`require`,
  documentation and typespec attributes, and keyword/option keys). Callers can
  prune additional framework DSL calls via `context[:skip_calls]`. See `walk/3`
  for the full set of rules.

  ## Equivalent Mutations

  Mutators can declare that a generated mutation is semantically equivalent to the
  original code — meaning no test can ever kill it. This avoids polluting mutation
  scores with false negatives.

  There are two ways to mark equivalence:

  1. **At generation time** — set `equivalent: true` in the mutation map returned
     by `mutate/2`. Use this when the mutator knows at generation time that the
     mutation is equivalent (e.g., swapping arguments to a commutative operator).

  2. **Via the `equivalent?/1` callback** — implement this for more complex
     analysis that needs to inspect the full mutation map. The default
     implementation checks the `:equivalent` key.

  ## Example

      defmodule Muex.Mutator.MyMutator do
        @behaviour Muex.Mutator

        @impl true
        def mutate(ast, _context) do
          # Return list of mutated AST variants
          [mutated_ast_1, mutated_ast_2]
        end

        @impl true
        def name, do: "My Mutator"

        @impl true
        def description, do: "Mutates specific AST patterns"

        @impl true
        def supported_languages, do: [Muex.Language.Elixir, Muex.Language.Erlang]

        # Optional: override for complex equivalence detection
        @impl true
        def equivalent?(%{description: "swap arguments in +()" <> _}), do: true
        def equivalent?(_mutation), do: false
      end
  """
  @typedoc """
  Represents a single mutation with its metadata.

  The `:equivalent`, `:original_ast`, `:original_line`, `:ast_path` and
  `:function_complexity` keys are optional. `walk/3` annotates mutations with
  `:original_ast`, `:original_line`, and `:ast_path`, and with
  `:function_complexity` inside a function.
  When `:equivalent` is `true`, the mutation is considered semantically equivalent
  to the original and will be filtered out by the optimizer.
  """
  @type mutation :: %{
          optional(:original_ast) => term(),
          optional(:original_line) => non_neg_integer(),
          optional(:ast_path) => [non_neg_integer()],
          optional(:function_complexity) => pos_integer(),
          optional(:equivalent) => boolean(),
          ast: term(),
          mutator: module(),
          description: String.t(),
          location: %{file: String.t(), line: non_neg_integer()}
        }

  @doc """
  Applies mutations to the given AST.

  ## Parameters

    - `ast` - The AST to mutate
    - `context` - Map containing additional context (file path, line number, etc.)

  ## Returns

    List of `mutation` maps, each representing a possible mutation
  """
  @callback mutate(ast :: term(), context :: map()) :: [mutation()]

  @doc """
  Returns the name of the mutator.
  """
  @callback name() :: String.t()

  @doc """
  Returns a description of what this mutator does.
  """
  @callback description() :: String.t()

  @doc """
  Returns the list of language adapter modules this mutator supports.

  Mutators that work with the same AST format (e.g., BEAM languages like
  Elixir and Erlang) can declare multiple languages. Discovery will filter
  mutators based on the active language.

  ## Returns

    List of language adapter modules (e.g., `[Muex.Language.Elixir, Muex.Language.Erlang]`)
  """
  @callback supported_languages() :: [module()]

  @doc """
  Returns whether a mutation is semantically equivalent to the original code.

  Equivalent mutations can never be killed by any test and should be filtered out
  to avoid inflating the "survived" count.

  The default implementation checks for `equivalent: true` in the mutation map.
  Override this callback in your mutator for more sophisticated detection.
  """
  @callback equivalent?(mutation :: mutation()) :: boolean()

  @optional_callbacks [equivalent?: 1]

  @doc """
  Checks whether a mutation is equivalent: whether its `:equivalent` key is
  `true`, or else whether its mutator's `equivalent?/1`, if it has one, says
  so.
  """
  @spec equivalent?(mutation()) :: boolean()
  def equivalent?(%{mutator: mutator} = mutation) do
    Map.get(mutation, :equivalent, false) or
      (function_exported?(mutator, :equivalent?, 1) and mutator.equivalent?(mutation))
  end

  def equivalent?(mutation), do: Map.get(mutation, :equivalent, false)

  # Directives whose entire subtree is compile-time metadata, never a
  # runtime value. Mutating them yields invalid mutants.
  @always_skip_calls [:use, :import, :alias, :require]

  # Module attributes that carry documentation or typespecs rather than
  # runtime values. The whole attribute subtree is pruned.
  @skip_attributes [
    :doc,
    :moduledoc,
    :typedoc,
    :type,
    :typep,
    :opaque,
    :spec,
    :callback,
    :macrocallback,
    :behaviour,
    :impl,
    :derive,
    :enforce_keys
  ]

  # Forms whose first argument is a function head rather than a call.
  @definitions [:def, :defp, :defmacro, :defmacrop, :defguard, :defguardp, :defdelegate]

  # Forms that are not calls by name: `case`, `quote`, `{}` and the like.
  @special_forms Keyword.keys(Kernel.SpecialForms.__info__(:macros))

  # The keyword keys of a call's `do` block (`if c, do: x, else: y`), whose
  # values are code rather than options.
  @blocks [:do, :else, :after, :rescue, :catch]

  @doc """
  Walks an AST and collects mutations from all registered mutators.

  The traversal is context-aware: it threads the nearest enclosing source
  line through `context[:line]` (so leaf mutators such as
  `Muex.Mutator.Literal` can report a real location for bare literals that
  carry no AST metadata of their own) and prunes subtrees that should never
  be mutated.

  ## Pruning rules

  The following are skipped for every mutator, regardless of configuration:

    * Module alias segments (`{:__aliases__, _, _}`), e.g. the `Phoenix`
      and `Component` atoms in `use Phoenix.Component`.
    * Directives: `use`, `import`, `alias`, `require`.
    * Documentation and typespec attributes: `@doc`, `@moduledoc`,
      `@typedoc`, `@type`, `@typep`, `@opaque`, `@spec`, `@callback`,
      `@macrocallback`, `@behaviour`, `@impl`, `@derive`, `@enforce_keys`.
    * Keyword/option keys: in a `key: value` pair only `value` is
      traversed, never the atom `key`.
    * The `/` of a function capture (`&Mod.fun/arity`, `&fun/arity`),
      which names the arity; the function is traversed, and so is the
      arity of a remote capture only.
    * The number of a capture placeholder (`&1`). Inside `&(...)`, a
      mutation that drops a placeholder of the node it replaces is
      discarded.
    * The head of a definition (`def`, `defp`, `defmacro`, `defmacrop`,
      `defguard`, `defguardp`, `defdelegate`): `name(params)` and the `\\`
      of a default are never offered. The parameters, default values and
      guard are traversed.
    * The name of a module attribute being set (`timeout(5_000)` in
      `@timeout 5_000`): `@nil` does not compile. The `@` node and the
      value are traversed.
    * The function name of a remote call or capture (`join` in
      `Enum.join(list, ",")`), as a local call's name is not: renamed, it
      names a function that does not exist. The module and arguments are
      traversed, and so is the field of a map field access (`m.key`).
    * In a module body, the Erlang module of a remote call (`:erlang` in
      `:erlang.atom_to_binary(:ok)`), for the same reason.
    * In a module body, a literal argument of a named call, local or remote
      (`:a` in `Map.fetch!(map, :a)`), and the literal value of a trailing
      keyword option (`true` in `accumulate: true`): that code runs when the
      module compiles, where a changed argument can make the call raise.
      An operator's operands, `defstruct` and `defexception`'s arguments,
      and the `do`/`else` blocks of a call such as `if` are still walked.
    * A field name in a `defstruct` or `defexception` (`:a` in
      `defstruct [:a, b: 1]`): renamed, it breaks code that builds the
      struct, in this module or another. Default values are still walked.

  Inside a pattern the walk sets `context[:pattern]` to `true`, so a mutator
  can leave alone what is only valid as an expression. Patterns are a
  definition's parameters, the left of `=` and `<-`, and the left of `->`
  except in `cond` and a `receive`'s `after`. A guard is an expression, walked
  with `context[:guard]` set to `true`, and a `defguard` or `defguardp`'s
  guard also with `context[:defguard]` set to `true`, since it can be called
  outside a guard too. A guard clause's top-level nodes, the guard itself and
  the operands of a top-level `and` or `when`, also have
  `context[:guard_top]` set to `true`. The `<<>>` of a bitstring generator
  (`for <<b <- bin>>`) is not offered.

  A node that cannot be replaced by a value is offered with
  `context[:irreplaceable]` set to `true`. That is the call a pipe feeds
  (`f(y)` in `x |> f(y)`), which lacks its first argument, the text of a
  sigil (`"ab+c"` in `~r/ab+c/i`), which Kernel's sigils require as a string,
  the right side of `in` in a guard, which must be a list or range when
  the guard compiles, and an operand of `<>`, which Kernel rejects as a
  literal that is not a binary. A sigil's modifiers are not offered.

  A module body runs when the module compiles. Outside its definitions the
  walk sets `context[:module_body]` to the body's statements, and also sets
  `context[:statement]` to `true` on each of those statements. A macro's body
  (`defmacro`, `defmacrop`) runs when a caller compiles, and is walked the
  same way, except the code it quotes: the `do` of a `quote` runs where the
  macro is called and is walked as a function body is, apart from what it
  unquotes.

  Callers can prune additional framework DSL calls by passing a list of
  call names (atoms) in `context[:skip_calls]`. For example,
  `[:attr, :slot, :scope, :pipeline]` removes Phoenix component and router
  DSL noise. See `Muex.Config` presets.

  ## Parameters

    - `ast` - The AST to traverse
    - `mutators` - List of mutator modules to apply
    - `context` - Context map. Recognised keys:
      - `:file` - source file path, copied into each mutation's location
      - `:line` - starting line (defaults to `0`); updated as the walk descends
      - `:skip_calls` - extra call names (atoms) to prune

  ## Returns

    List of all mutations found in the AST. Each mutation is augmented with
    `:original_ast` (the matched node), `:original_line` (that node's own
    line) and `:ast_path` (that node's position in `ast`), all used
    later during application. Inside a function it also carries
    `:function_complexity`, that function's `Muex.MutantOptimizer.complexity/1`.
  """
  @spec walk(ast :: term(), mutators :: [module()], context :: map()) :: [mutation()]
  def walk(ast, mutators, context) do
    context = Map.put_new(context, :line, 0)
    skip_calls = Map.get(context, :skip_calls, [])
    collect(ast, mutators, context, skip_calls, [])
  end

  # Recursively collect mutations, threading the enclosing line and the node's
  # position, and pruning skipped subtrees. Preserves `Macro.prewalk/2`
  # (pre-order) ordering while adding context awareness. `path` is the
  # position of `node`, the tuple and list indices leading to it from the root,
  # kept reversed while descending.
  defp collect(node, mutators, context, skip_calls, path) do
    if skip?(node, skip_calls) do
      []
    else
      context =
        context
        |> update_line(node)
        |> update_function(node)
        |> update_arrows(node)
        |> update_statement(path)

      mutations =
        case bitstring_generator?(node) do
          true -> []
          false -> mutate_node(node, mutators, context, path)
        end

      children_context =
        context
        |> Map.drop([:irreplaceable, :statement])
        |> enter_capture(node)
        |> enter_struct(node)
        |> enter_module(node, path)
        |> enter_quote(node)
        |> enter_guard_operand(node)

      mutations ++ collect_children(node, mutators, children_context, skip_calls, path)
    end
  end

  # Inside `&(...)` a mutation must keep every `&N` of the node it replaces:
  # one that drops `&1` (`&(&1 + &2)` to `&(nil + &2)`) or every placeholder
  # (`&0`, `&nil`) does not compile. The capture itself may still be replaced.
  defp enter_capture(context, {:&, _meta, [body]}) when not is_integer(body),
    do: Map.put(context, :capture, true)

  defp enter_capture(context, _node), do: context

  # A bare atom in a list in `defstruct` or `defexception` names a field;
  # see `collect_list/5`.
  defp enter_struct(context, {kind, _meta, args})
       when kind in [:defstruct, :defexception] and is_list(args),
       do: Map.put(context, :fields, true)

  defp enter_struct(context, _node), do: context

  # A mutant that makes the module body raise does not compile.
  # `statement_paths` lets `update_statement` mark the body's own statements.
  # A definition drops both keys: its body runs when called. A macro's body
  # sets them again; see `enter_macro/4`.
  defp enter_module(context, {:defmodule, _meta, [_name, [{:do, body}]]}, path),
    do: enter_body(context, body, below(path, [2, 1, 0, 1]))

  defp enter_module(context, _node, _path), do: context

  # A macro's body runs when a caller compiles, so a mutant that makes it
  # raise there breaks the caller: it is walked as a module body is.
  # `macro_body` stays set for the whole macro, for `enter_quote/2`.
  defp enter_macro(context, kind, [[{:do, body} | _]], path)
       when kind in [:defmacro, :defmacrop] do
    context = enter_body(context, body, below(path, [2, 1, 0, 1]))
    Map.put(context, :macro_body, context.module_body)
  end

  defp enter_macro(context, _kind, _rest, _path), do: context

  # In a macro, what `quote` quotes runs where the macro is called, as a
  # function body does, so the `do` of a `quote` is walked without
  # `module_body`; see the keyword pair clause of `collect_children/5`. Its
  # options (`bind_quoted:`) and what it unquotes run when the macro
  # expands, and are walked as the macro's body.
  defp enter_quote(%{macro_body: _} = context, {:quote, _meta, args}) when is_list(args),
    do: Map.put(context, :quoting, true)

  defp enter_quote(%{macro_body: statements} = context, {form, _meta, [_expr]})
       when form in [:unquote, :unquote_splicing] and not is_map_key(context, :module_body),
       do: Map.put(context, :module_body, statements)

  defp enter_quote(context, _node), do: context

  # An error in a guard fails its whole clause, so an `and`'s operands, and
  # each clause of `a when b`, are top-level only when the node is.
  defp enter_guard_operand(%{guard_top: true} = context, {form, _meta, [_left, _right]})
       when form in [:and, :when],
       do: context

  defp enter_guard_operand(context, _node), do: Map.delete(context, :guard_top)

  defp enter_body(context, body, body_path) do
    {statements, paths} =
      case body do
        {:__block__, _block_meta, statements} ->
          paths =
            for {_statement, index} <- Enum.with_index(statements),
                do: below(body_path, [2, index])

          {statements, paths}

        statement ->
          {[statement], [body_path]}
      end

    Map.merge(context, %{module_body: statements, statement_paths: MapSet.new(paths)})
  end

  defp update_statement(%{statement_paths: paths} = context, path) do
    if MapSet.member?(paths, path), do: Map.put(context, :statement, true), else: context
  end

  defp update_statement(context, _path), do: context

  # `for <<byte <- bin>>`: the `<<>>` marks a bitstring generator and is not a
  # value, so only what is inside it is offered.
  defp bitstring_generator?({:<<>>, _meta, [{:<-, _, _}]}), do: true
  defp bitstring_generator?(_node), do: false

  defp mutate_node(node, mutators, context, path) do
    keeps_placeholders? = keeps_placeholders(node, context)

    Enum.flat_map(mutators, fn mutator ->
      node
      |> mutator.mutate(context)
      |> Enum.filter(&keeps_placeholders?.(&1.ast))
      |> Enum.map(&annotate(&1, node, context, path))
    end)
  end

  # Whether a replacement for `node` keeps each of its capture placeholders;
  # see `enter_capture/2`.
  defp keeps_placeholders(node, %{capture: true}) do
    needed = placeholders(node)
    &MapSet.subset?(needed, placeholders(&1))
  end

  defp keeps_placeholders(_node, _context), do: fn _ast -> true end

  defp placeholders(ast) do
    {_ast, found} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:&, _meta, [n]} = node, acc when is_integer(n) -> {node, MapSet.put(acc, n)}
        node, acc -> {node, acc}
      end)

    found
  end

  # Record what a mutation needs at application time: the matched node itself,
  # and the line that identifies it. The two are separate values on purpose.
  # `location.line` is what the report shows, and a mutator may deliberately
  # point it somewhere other than the matched node — StatementDeletion reports
  # the deleted statement's line while the node it replaces is the enclosing
  # block. `:original_line` is the matched node's own line (the enclosing line
  # when the node carries no metadata of its own). `:ast_path` is where
  # the node sits in the walked AST: the same code can appear twice on one
  # line (`x + 1 + (x + 1)`), and only its position tells the copies apart.
  # `Muex.Compiler` replaces the node at that position, and falls back to
  # matching on `:original_line` when there is none.
  #
  # `:function_complexity` is the enclosing function's, for
  # `Muex.MutantOptimizer`; code outside any function has none.
  defp annotate(mutation, node, context, path) do
    mutation
    |> Map.put(:original_ast, node)
    |> Map.put(:original_line, Map.get(context, :line) || 0)
    |> Map.put(:ast_path, Enum.reverse(path))
    |> put_function_complexity(context)
  end

  defp put_function_complexity(mutation, %{function_complexity: complexity}),
    do: Map.put(mutation, :function_complexity, complexity)

  defp put_function_complexity(mutation, _context), do: mutation

  # The position `steps` below `path`, with `steps` written root first.
  defp below(path, steps), do: Enum.reverse(steps, path)

  # Map/struct update: `%{subject | key: value}`, and the inner `%{}` of
  # `%Struct{subject | key: value}`. The `|` here is the update special form,
  # not a call, and `%{}` accepts it in exactly one shape: subject on the left,
  # pairs on the right. Mutating the node itself breaks that shape — swapping
  # its arguments yields `%{[key: value] | subject}`, which no parser produces
  # and `Code.Normalizer` refuses to unparse. Visit the operands, never the
  # `|` node.
  defp collect_children(
         {:%{}, _meta, [{:|, pipe_meta, [subject, pairs]}]},
         mutators,
         context,
         skip_calls,
         path
       ) do
    context = update_line(context, {:|, pipe_meta, []})

    collect(subject, mutators, context, skip_calls, below(path, [2, 0, 2, 0])) ++
      collect_args(pairs, mutators, context, skip_calls, below(path, [2, 0, 2, 1]))
  end

  # Function capture: `&Mod.fun/arity` and `&fun/arity`. The `/` names the
  # arity; it is neither division nor a call, so mutating it only makes captures
  # that do not compile (`&(Path.dirname() * 1)`, `&1`). Visit the function and
  # the arity, never the `/` node. `&(&1 / 2)` is division and is walked as
  # usual: what tells the two apart is the left operand, the same test
  # Elixir's capture expansion uses.
  defp collect_children(
         {:&, _meta, [{:/, _slash_meta, [function, arity]} = slash] = args},
         mutators,
         context,
         skip_calls,
         path
       )
       when is_integer(arity) do
    case function_reference(function) do
      nil ->
        collect_args(args, mutators, context, skip_calls, below(path, [2]))

      kind ->
        context = update_line(context, slash)

        collect(function, mutators, context, skip_calls, below(path, [2, 0, 2, 0])) ++
          collect_arity(kind, arity, mutators, context, skip_calls, below(path, [2, 0, 2, 1]))
    end
  end

  # Capture placeholder: `&1`. Its number is not a value; changing it leaves
  # `&0`, or a capture that skips `&1`.
  defp collect_children({:&, _meta, [n]}, _mutators, _context, _skip_calls, _path)
       when is_integer(n),
       do: []

  # Definition: `def name(params) when guard`. The head is not a call, so no
  # mutator is offered it; see `collect_head/5`. The body and options are
  # walked as usual, a macro's body as a module body; see `enter_macro/4`.
  defp collect_children({kind, _meta, [head | rest]}, mutators, context, skip_calls, path)
       when kind in @definitions do
    context = Map.drop(context, [:module_body, :statement_paths])
    body_context = enter_macro(context, kind, rest, path)

    head_context =
      if kind in [:defguard, :defguardp], do: Map.put(context, :defguard, true), else: context

    collect_head(head, mutators, head_context, skip_calls, below(path, [2, 0])) ++
      (rest
       |> Enum.with_index(1)
       |> Enum.flat_map(fn {node, index} ->
         collect(node, mutators, body_context, skip_calls, below(path, [2, index]))
       end))
  end

  # Module attribute set: `@name value`. `name(value)` is not a call: `@`
  # accepts only a name with at most one argument, so only the value is walked.
  defp collect_children(
         {:@, _meta, [{name, name_meta, [value]}]},
         mutators,
         context,
         skip_calls,
         path
       )
       when is_atom(name) do
    context = update_line(context, {name, name_meta, []})
    collect(value, mutators, context, skip_calls, below(path, [2, 0, 2, 0]))
  end

  # Match: `pattern = value`. The value keeps the enclosing context: inside a
  # pattern it is a pattern too.
  defp collect_children({:=, _meta, [left, right]}, mutators, context, skip_calls, path) do
    collect_pattern(left, mutators, context, skip_calls, below(path, [2, 0])) ++
      collect(right, mutators, context, skip_calls, below(path, [2, 1]))
  end

  # Pipe: `value |> call(args)`. The call itself is walked with
  # `context[:irreplaceable]` set; its arguments are not.
  defp collect_children({:|>, _meta, [left, right]}, mutators, context, skip_calls, path) do
    collect(left, mutators, context, skip_calls, below(path, [2, 0])) ++
      collect(
        right,
        mutators,
        Map.put(context, :irreplaceable, true),
        skip_calls,
        below(path, [2, 1])
      )
  end

  # Generator or `with` clause: `pattern when guard <- value`.
  defp collect_children({:<-, _meta, [left, right]}, mutators, context, skip_calls, path) do
    context = Map.delete(context, :pattern)

    collect_guarded(left, mutators, context, skip_calls, below(path, [2, 0])) ++
      collect(right, mutators, context, skip_calls, below(path, [2, 1]))
  end

  # Clause: `patterns when guard -> body`, in `case`, `fn`, `receive`, `try`,
  # `with`'s `else` and `for`'s `reduce:`. A `cond` clause and a `receive`
  # timeout put an expression on the left instead; see `update_arrows/2`.
  defp collect_children({:->, _meta, [lefts, body]}, mutators, context, skip_calls, path)
       when is_list(lefts) do
    {left_kind, context} = Map.pop(context, :arrow_left, :pattern)
    context = Map.delete(context, :pattern)

    collect_left =
      case left_kind do
        :pattern -> &collect_guarded/5
        :expression -> &collect/5
      end

    lefts_mutations =
      lefts
      |> Enum.with_index()
      |> Enum.flat_map(fn {left, index} ->
        collect_left.(left, mutators, context, skip_calls, below(path, [2, 0, index]))
      end)

    lefts_mutations ++ collect(body, mutators, context, skip_calls, below(path, [2, 1]))
  end

  # `left in right` in a guard: `right` must be a list or range when the guard
  # compiles, so it is walked with `context[:irreplaceable]` set.
  defp collect_children(
         {:in, _meta, [left, right]},
         mutators,
         %{guard: true} = context,
         skip_calls,
         path
       ) do
    collect(left, mutators, context, skip_calls, below(path, [2, 0])) ++
      collect(
        right,
        mutators,
        Map.put(context, :irreplaceable, true),
        skip_calls,
        below(path, [2, 1])
      )
  end

  # `left <> right`: Kernel rejects an operand that is a literal but not a
  # binary (`nil <> "x"`) when it compiles, so both are walked with
  # `context[:irreplaceable]` set.
  defp collect_children({:<>, _meta, [_left, _right] = args}, mutators, context, skip_calls, path) do
    context = Map.put(context, :irreplaceable, true)
    collect_args(args, mutators, context, skip_calls, below(path, [2]))
  end

  # Call with an atom form: descend into args only. This mirrors
  # `Macro.traverse/4`, which does not visit the call name itself.
  defp collect_children({form, _meta, args}, mutators, context, skip_calls, path)
       when is_atom(form) do
    cond do
      sigil?(form) ->
        collect_sigil(args, mutators, context, skip_calls, below(path, [2]))

      named_call?(form, args) ->
        collect_call_args(args, mutators, context, skip_calls, below(path, [2]))

      true ->
        collect_args(args, mutators, context, skip_calls, below(path, [2]))
    end
  end

  # Remote call: `Mod.fun(args)`. The function name is not offered, as a local
  # call's is not: renamed, the call names a function that does not exist,
  # which fails to compile when the module body calls it. `expr.field` is a
  # map field access, not a call, so its field is offered as usual.
  defp collect_children(
         {{:., _dot_meta, [module, fun]} = dot, meta, args},
         mutators,
         context,
         skip_calls,
         path
       )
       when is_atom(fun) and is_list(args) do
    dot_mutations =
      if field_access?(module, meta, args) do
        collect(dot, mutators, context, skip_calls, below(path, [0]))
      else
        dot_context = update_line(context, dot)

        mutate_node(dot, mutators, dot_context, below(path, [0])) ++
          collect_module(module, mutators, dot_context, skip_calls, below(path, [0, 2, 0]))
      end

    dot_mutations ++ collect_call_args(args, mutators, context, skip_calls, below(path, [2]))
  end

  # Call with a non-atom form (e.g. an anonymous function call `f.(x)`):
  # descend into both the form and the args.
  defp collect_children({form, _meta, args}, mutators, context, skip_calls, path) do
    collect(form, mutators, context, skip_calls, below(path, [0])) ++
      collect_args(args, mutators, context, skip_calls, below(path, [2]))
  end

  # Two-element tuple: a keyword pair or literal pair. Never mutate an atom
  # key; traverse the value, unless it is the literal value of a module-body
  # call's option (see `collect_call_args/5`), which consumes the flag. In a
  # struct definition the value is a default, not field names. The `do` of a
  # `quote` in a macro is walked as a function body; see `enter_quote/2`.
  defp collect_children({left, right}, mutators, context, skip_calls, path) do
    {options?, context} = Map.pop(context, :options, false)
    {quoting?, context} = Map.pop(context, :quoting, false)
    context = Map.delete(context, :fields)

    context =
      if quoting? and left == :do,
        do: Map.drop(context, [:module_body, :statement_paths]),
        else: context

    left_mutations =
      if is_atom(left),
        do: [],
        else: collect(left, mutators, context, skip_calls, below(path, [0]))

    right_mutations =
      if options? and literal?(right) and left not in @blocks,
        do: [],
        else: collect(right, mutators, context, skip_calls, below(path, [1]))

    left_mutations ++ right_mutations
  end

  defp collect_children(list, mutators, context, skip_calls, path) when is_list(list) do
    collect_list(list, mutators, context, skip_calls, path)
  end

  defp collect_children(_leaf, _mutators, _context, _skip_calls, _path), do: []

  # A remote call's module. An Erlang module renamed (`:erlang` to
  # `:mutated_atom`) names a module that does not exist, which fails to
  # compile when the module body calls it; in a function it raises when
  # called, so there it is still offered.
  defp collect_module(module, _mutators, %{module_body: _}, _skip_calls, _path)
       when is_atom(module),
       do: []

  defp collect_module(module, mutators, context, skip_calls, path),
    do: collect(module, mutators, context, skip_calls, path)

  # A named call's arguments. In a module body the call runs when the module
  # compiles, and a changed literal argument can make it raise there
  # (`Map.fetch!(map, :mutated_atom)`, `accumulate: false` for
  # `Module.register_attribute/3`), so a literal argument is not offered, nor
  # the literal value of a trailing keyword list's option. Elsewhere the call
  # raises when run, so its arguments are walked as usual.
  defp collect_call_args(args, mutators, %{module_body: _} = context, skip_calls, path) do
    last = length(args) - 1

    args
    |> Enum.with_index()
    |> Enum.flat_map(fn {arg, index} ->
      arg_context =
        if index == last and Keyword.keyword?(arg),
          do: Map.put(context, :options, true),
          else: context

      if literal?(arg),
        do: [],
        else: collect(arg, mutators, arg_context, skip_calls, below(path, [index]))
    end)
  end

  defp collect_call_args(args, mutators, context, skip_calls, path),
    do: collect_args(args, mutators, context, skip_calls, path)

  # A call by name rather than an operator or a special form. `defstruct`
  # and `defexception` are left out: their arguments are field names and
  # default values, and a changed default still compiles.
  defp named_call?(form, args) when is_list(args) do
    form not in @special_forms and form not in [:defstruct, :defexception] and
      not Macro.operator?(form, length(args))
  end

  defp named_call?(_form, _args), do: false

  defp literal?(ast), do: is_atom(ast) or is_number(ast) or is_binary(ast) or ast == []

  # Args may be a list (normal call) or an atom such as `nil`/`Elixir` for
  # variables and zero-arity forms, which carry no child nodes. `path` is the
  # position of `args` itself.
  defp collect_args(args, _mutators, _context, _skip_calls, _path) when is_atom(args), do: []

  defp collect_args(args, mutators, context, skip_calls, path) when is_list(args) do
    collect_list(args, mutators, context, skip_calls, path)
  end

  defp collect_args(args, mutators, context, skip_calls, path) do
    collect(args, mutators, context, skip_calls, path)
  end

  # In a struct definition a bare atom in a list is a field name, which other
  # code builds the struct with (`%S{a: 1}`), so it is not offered.
  defp collect_list(list, mutators, context, skip_calls, path) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {node, _index} when is_atom(node) and is_map_key(context, :fields) ->
        []

      {node, index} ->
        collect(node, mutators, context, skip_calls, below(path, [index]))
    end)
  end

  # A sigil's arguments: `~r/text/mods` is `sigil_r(<<"text">>, ~c"mods")`.
  # Kernel's sigils are macros that need the text as `<<>>` and valid
  # modifiers, so the text is walked with `context[:irreplaceable]` set and
  # the modifiers not at all.
  defp collect_sigil([text | _modifiers], mutators, context, skip_calls, path) do
    context = Map.put(context, :irreplaceable, true)
    collect(text, mutators, context, skip_calls, below(path, [0]))
  end

  defp collect_sigil(_args, _mutators, _context, _skip_calls, _path), do: []

  # A definition's head. Removing `name(params)` leaves `def nil`, and
  # rewriting it under any other mutator renames or redefines the function
  # rather than changing what it does, so the head node itself is never
  # offered. A guard's `when` is still offered (`Muex.Mutator.Guard`) and the
  # guard is walked as an expression. Each parameter is a pattern, apart from
  # a default value.
  defp collect_head({:when, _meta, [head, guard]} = node, mutators, context, skip_calls, path) do
    context = update_line(context, node)

    mutate_node(node, mutators, context, path) ++
      collect_head(head, mutators, context, skip_calls, below(path, [2, 0])) ++
      collect_guard(guard, mutators, context, skip_calls, below(path, [2, 1]))
  end

  defp collect_head({_name, _meta, params} = head, mutators, context, skip_calls, path)
       when is_list(params) do
    context = update_line(context, head)

    params
    |> Enum.with_index()
    |> Enum.flat_map(fn {param, index} ->
      collect_param(param, mutators, context, skip_calls, below(path, [2, index]))
    end)
  end

  defp collect_head(_head, _mutators, _context, _skip_calls, _path), do: []

  # `pattern \\ default` is not a call either: only its operands are walked,
  # the pattern as a pattern and the default as an expression.
  defp collect_param(
         {:\\, _meta, [pattern, default]} = param,
         mutators,
         context,
         skip_calls,
         path
       ) do
    context = update_line(context, param)

    collect_pattern(pattern, mutators, context, skip_calls, below(path, [2, 0])) ++
      collect(default, mutators, context, skip_calls, below(path, [2, 1]))
  end

  defp collect_param(pattern, mutators, context, skip_calls, path),
    do: collect_pattern(pattern, mutators, context, skip_calls, path)

  # A clause's pattern, possibly guarded: `p1, p2 when guard` arrives as one
  # `when` whose last argument is the guard. The `when` is still offered
  # (`Muex.Mutator.Guard`) and the guard is walked as an expression.
  defp collect_guarded({:when, _meta, args} = node, mutators, context, skip_calls, path)
       when is_list(args) and args != [] do
    context = update_line(context, node)
    {patterns, [guard]} = Enum.split(args, -1)

    pattern_mutations =
      patterns
      |> Enum.with_index()
      |> Enum.flat_map(fn {pattern, index} ->
        collect_pattern(pattern, mutators, context, skip_calls, below(path, [2, index]))
      end)

    mutate_node(node, mutators, context, path) ++
      pattern_mutations ++
      collect_guard(guard, mutators, context, skip_calls, below(path, [2, length(patterns)]))
  end

  defp collect_guarded(pattern, mutators, context, skip_calls, path),
    do: collect_pattern(pattern, mutators, context, skip_calls, path)

  # Walk a pattern, telling mutators so through `context[:pattern]`.
  defp collect_pattern(pattern, mutators, context, skip_calls, path),
    do: collect(pattern, mutators, Map.put(context, :pattern, true), skip_calls, path)

  # Walk a guard, telling mutators so through `context[:guard]`, and which of
  # its nodes are top-level through `context[:guard_top]`.
  defp collect_guard(guard, mutators, context, skip_calls, path),
    do:
      collect(
        guard,
        mutators,
        Map.merge(context, %{guard: true, guard_top: true}),
        skip_calls,
        path
      )

  # The left operand of `/` in `&(left / arity)` when Elixir reads the capture
  # as a function reference: `:remote` for `Mod.fun` (no arguments), `:local`
  # for `fun`.
  defp function_reference({{:., _dot_meta, [_module, fun]}, _meta, []}) when is_atom(fun),
    do: :remote

  defp function_reference({fun, _meta, context}) when is_atom(fun) and is_atom(context),
    do: :local

  defp function_reference(_left), do: nil

  # `expr.field`: no parentheses, no arguments, and an expression rather than
  # a module on the left.
  defp field_access?(module, meta, []) do
    Keyword.get(meta, :no_parens, false) and not module_name?(module)
  end

  defp field_access?(_module, _meta, _args), do: false

  defp module_name?({:__aliases__, _meta, _segments}), do: true
  defp module_name?({:__MODULE__, _meta, context}) when is_atom(context), do: true
  defp module_name?(module), do: is_atom(module)

  # A capture's arity. A remote capture of an arity that does not exist still
  # compiles, so its arity is offered. A local, imported or operator capture
  # of one fails to compile (`&+/3`), and which arities exist is not known
  # here, so its arity is not.
  defp collect_arity(:remote, arity, mutators, context, skip_calls, path),
    do: collect(arity, mutators, context, skip_calls, path)

  defp collect_arity(:local, _arity, _mutators, _context, _skip_calls, _path), do: []

  @doc """
  Whether `name` names a sigil, as `:sigil_r` does for `~r/.../`.
  """
  @spec sigil?(atom()) :: boolean()
  def sigil?(name) when is_atom(name), do: String.starts_with?(Atom.to_string(name), "sigil_")

  # Module alias segments: pure structural metadata.
  defp skip?({:__aliases__, _meta, _segments}, _skip_calls), do: true

  # Documentation and typespec module attributes.
  defp skip?({:@, _meta, [{attr, _attr_meta, _attr_args}]}, _skip_calls)
       when attr in @skip_attributes,
       do: true

  # Directive calls and configured DSL calls.
  defp skip?({form, _meta, args}, skip_calls)
       when is_atom(form) and (is_list(args) or is_nil(args)) do
    form in @always_skip_calls or form in skip_calls
  end

  defp skip?(_node, _skip_calls), do: false

  defp update_line(context, {_form, meta, _args}) when is_list(meta) do
    case Keyword.get(meta, :line) do
      nil -> context
      line -> Map.put(context, :line, line)
    end
  end

  defp update_line(context, _node), do: context

  defp update_function(context, {def, _meta, [_head | _]} = node)
       when def in [:def, :defp, :defmacro, :defmacrop],
       do: Map.put(context, :function_complexity, Muex.MutantOptimizer.complexity(node))

  defp update_function(context, _node), do: context

  # The clauses of a `cond`, and a `receive`'s `after` clause, put an
  # expression left of `->` rather than a pattern. Nothing but the keyword
  # list holding them lies between this node and those `->`s, which consume
  # the flag.
  defp update_arrows(context, {:cond, _meta, [[do: [{:->, _, _} | _]]]}),
    do: Map.put(context, :arrow_left, :expression)

  defp update_arrows(context, {:after, [{:->, _meta, _args} | _]}),
    do: Map.put(context, :arrow_left, :expression)

  defp update_arrows(context, _node), do: context
end
