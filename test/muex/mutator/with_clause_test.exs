defmodule Muex.Mutator.WithClauseTest do
  use ExUnit.Case, async: true

  alias Muex.Mutator.WithClause

  defp arrow(pat, expr, line), do: {:<-, [line: line], [pat, expr]}

  defp with_node(args, line), do: {:with, [line: line], args}

  defp with_args(%{ast: {:with, _, args}}), do: args

  describe "mutate/2" do
    test "deletes each <- clause, keeping the do block" do
      a1 = arrow({:ok, {:a, [line: 1], nil}}, {:foo, [line: 1], []}, 1)
      a2 = arrow({:ok, {:b, [line: 1], nil}}, {:bar, [line: 1], []}, 1)
      kw = [do: :done]
      ast = with_node([a1, a2, kw], 1)

      mutations = WithClause.mutate(ast, %{file: "test.ex"})

      assert [_, _] = mutations
      assert Enum.any?(mutations, &(with_args(&1) == [a2, kw]))
      assert Enum.any?(mutations, &(with_args(&1) == [a1, kw]))
    end

    test "only deletes <- clauses, never bare expressions" do
      bare = {:=, [line: 1], [{:x, [line: 1], nil}, 1]}
      a1 = arrow({:ok, {:a, [line: 1], nil}}, {:foo, [line: 1], []}, 1)
      a2 = arrow({:ok, {:b, [line: 1], nil}}, {:bar, [line: 1], []}, 1)
      kw = [do: :done]
      ast = with_node([bare, a1, a2, kw], 1)

      mutations = WithClause.mutate(ast, %{file: "test.ex"})

      assert [_, _] = mutations

      for mutation <- mutations do
        args = with_args(mutation)
        assert bare in args
        assert kw in args
      end
    end

    test "produces descriptive labels referencing clause position" do
      a1 = arrow(:ok, {:foo, [line: 1], []}, 1)
      a2 = arrow(:ok, {:bar, [line: 1], []}, 1)
      ast = with_node([a1, a2, [do: :ok]], 1)

      mutations = WithClause.mutate(ast, %{file: "test.ex"})

      assert Enum.any?(mutations, &(&1.description == "WithClause: delete clause 1 of 2"))
      assert Enum.any?(mutations, &(&1.description == "WithClause: delete clause 2 of 2"))
    end

    test "does not mutate a with with a single <- clause" do
      ast = with_node([arrow(:ok, {:foo, [line: 1], []}, 1), [do: :ok]], 1)
      assert [] = WithClause.mutate(ast, %{file: "test.ex"})
    end

    test "includes proper metadata" do
      a1 = arrow(:ok, {:foo, [line: 10], []}, 10)
      a2 = arrow(:ok, {:bar, [line: 10], []}, 10)
      ast = with_node([a1, a2, [do: :ok]], 10)

      [mutation | _] = WithClause.mutate(ast, %{file: "lib/m.ex"})

      assert mutation.mutator == Muex.Mutator.WithClause
      assert mutation.location == %{file: "lib/m.ex", line: 10}
    end

    test "returns empty list for non-with AST" do
      assert [] = WithClause.mutate({:case, [line: 1], [:x, [do: []]]}, %{})
      assert [] = WithClause.mutate({:+, [line: 1], [:a, :b]}, %{})
    end
  end

  describe "name/0 and description/0" do
    test "name" do
      assert "WithClause" = WithClause.name()
    end

    test "description mentions with" do
      assert WithClause.description() =~ "with"
    end
  end

  describe "supported_languages/0" do
    test "supports Elixir" do
      assert Muex.Language.Elixir in WithClause.supported_languages()
    end
  end

  test "reports each deletion on the deleted clause's line" do
    ast =
      Code.string_to_quoted!("""
      with :ok <- foo(),
           :ok <- bar() do
        :done
      end
      """)

    lines = ast |> WithClause.mutate(%{file: "lib/m.ex"}) |> Enum.map(& &1.location.line)
    assert lines == [1, 2]
  end

  describe "bindings read later" do
    defp deletions(source) do
      source
      |> Code.string_to_quoted!()
      |> WithClause.mutate(%{file: "lib/m.ex"})
      |> Enum.map(&{&1.description, Macro.to_string(&1.ast)})
    end

    test "keeps a clause whose binding a later clause or the body reads" do
      # Deleting either clause leaves `a` or `b` undefined.
      assert deletions("""
             with {:ok, a} <- foo(), {:ok, b} <- bar(a) do
               b
             end
             """) == []
    end

    test "deletes a clause whose binding only `else` or nothing reads" do
      # Labels still count every `<-` clause.
      assert [{"WithClause: delete clause 2 of 3", _}, {"WithClause: delete clause 3 of 3", _}] =
               deletions("""
               with {:ok, a} <- foo(), {:ok, b} <- bar(a), :ok <- baz(a) do
                 a
               else
                 b -> b
               end
               """)
    end

    test "deletes a clause whose binding an earlier clause already made" do
      assert [{"WithClause: delete clause 2 of 2", _}] =
               deletions("""
               with {:ok, a} <- foo(), {:ok, a} <- bar(a) do
                 a
               end
               """)
    end

    test "a binding by a bare match counts as earlier" do
      assert [{_, "with a = 1, {:ok, b} <- bar(a) do\n  {a, b}\nend"}] =
               deletions("""
               with a = 1, {:ok, a} <- foo(), {:ok, b} <- bar(a) do
                 {a, b}
               end
               """)
    end
  end
end
