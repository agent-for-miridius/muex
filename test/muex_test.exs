defmodule MuexTest do
  use ExUnit.Case
  doctest Muex

  test "module loads successfully" do
    assert Code.ensure_loaded?(Muex)
  end

  describe "check_threshold/2" do
    test "fails a run that tested no mutants when the threshold is above 0%" do
      result = %{results: [], score_low: 0.0, score_high: 0.0}

      assert Muex.check_threshold(result, 80) ==
               {:error, "Mutation score 0.0% is below threshold 80%"}
    end

    test "passes a run that tested no mutants at a 0% threshold" do
      assert Muex.check_threshold(%{results: [], score_low: 0.0, score_high: 0.0}, 0) == :ok
    end

    test "compares the low bound and reports the range" do
      result = %{results: [:r], score_low: 50.0, score_high: 90.0}

      assert Muex.check_threshold(result, 80) ==
               {:error, "Mutation score 50.0%..90.0% is below threshold 80%"}

      assert Muex.check_threshold(result, 50) == :ok
    end
  end
end
