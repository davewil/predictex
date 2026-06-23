defmodule Predictex.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Predictex.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Predictex.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Predictex.DataCase
    end
  end

  setup tags do
    Predictex.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.

  ## Async invariant: create rounds in ascending `:ordinal` order

  `rounds.ordinal` has a unique index. When an `async: true` test inserts more than one
  round, insert them in ascending ordinal order (group ordinal 1 before knockout ordinal 4,
  etc.). Concurrent sandbox transactions take the index locks one ordinal at a time; if any
  test inserts a higher ordinal before a lower one while others go low→high, the lock-wait
  graph can cycle and PostgreSQL kills a transaction with a `40P01` deadlock. Ascending
  everywhere keeps it acyclic. If a `40P01` on a rounds insert ever recurs, the offender is a
  test inserting rounds out of order — reorder it ascending (predictex-dmh).
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Predictex.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
