defmodule Redix.Connection.Auth do
  @moduledoc false

  alias Redix.Protocol

  @type error :: Redix.Error.t | atom

  @spec auth_and_select_db(%{}) :: {:ok, %{}} | {:error, error, %{}}
  def auth_and_select_db(state) do
    state = Map.put(state, :tail, "")

    case auth(state, state.opts[:password]) do
      {:ok, state} ->
        case select_db(state, state.opts[:database]) do
          {:ok, state} ->
            :ok = :inet.setopts(state.socket, active: :once)
            {:ok, state}
          {:error, _reason, _state} = err ->
            err
        end
      {:error, _reason, _state} = err ->
        err
    end
  end

  defp auth(state, nil) do
    {:ok, state}
  end

  defp auth(state, password) when is_binary(password) do
    case pack_and_send(state, ["AUTH", password]) do
      :ok ->
        case wait_for_response(state) do
          {:ok, "OK", state} ->
            state = put_in(state.opts[:password], :redacted)
            {:ok, state}
          {:ok, error, state} ->
            {:error, error, state}
          {:error, reason} ->
            {:error, reason, state}
        end
      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp select_db(state, nil) do
    {:ok, state}
  end

  defp select_db(state, db) do
    case pack_and_send(state, ["SELECT", db]) do
      :ok ->
        case wait_for_response(state) do
          {:ok, "OK", state} ->
            {:ok, state}
          {:ok, error, state} ->
            {:error, error, state}
          {:error, reason} ->
            {:error, reason, state}
        end
      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp wait_for_response(%{socket: socket} = state) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        data = state.tail <> data
        case Protocol.parse(data) do
          {:ok, value, rest} ->
            {:ok, value, %{state | tail: rest}}
          {:error, :incomplete} ->
            wait_for_response(%{state | tail: data})
        end
      {:error, _} = err ->
        err
    end
  end

  defp pack_and_send(%{socket: socket} = _state, command) do
    :gen_tcp.send(socket, Protocol.pack(command))
  end
end
