defmodule Redix.Utils do
  @moduledoc false

  require Logger
  alias Redix.Connection.Auth

  # We use exit_on_close: false so that we can consistently close the socket
  # (with :gen_tcp.close/1) in the disconnect/2 callback. If we left the default
  # value of exit_on_close: true and still called :gen_tcp.close/1 in
  # disconnect/2, then we would sometimes close an already closed socket, which
  # is harmless but inconsistent. Credit for this strategy goes to James Fish.
  @socket_opts [:binary, active: false, exit_on_close: false]

  @default_timeout 5000

  @spec connect(term, Redix.Connection.state) :: term
  def connect(info, %{opts: opts} = state) do
    {host, port, socket_opts, timeout} = tcp_connection_opts(opts)

    case :gen_tcp.connect(host, port, socket_opts, timeout) do
      {:ok, socket} ->
        setup_socket_buffers(socket)

        case Auth.auth_and_select_db(%{state | socket: socket, reconnection_attempts: 0}) do
          {:ok, state} ->
            {:ok, state}
          {:error, _reason, _state} = err ->
            handle_connection_error(info, err)
        end
      {:error, reason} ->
        Logger.error ["Error connecting to Redis (#{format_host(state)}):",
                      :inet.format_error(reason)]
        handle_connection_error(info, {:error, reason, state})
    end
  end

  @spec format_host(Redix.Connection.state) :: String.t
  def format_host(%{opts: opts} = _state) do
    "#{opts[:host]}:#{opts[:port]}"
  end

  @spec send_reply(Redix.Connection.state, iodata, term) ::
    {:reply, term, Redix.Connection.state} |
    {:disconnect, term, Redix.Connection.state}
  def send_reply(%{socket: socket} = state, data, reply) do
    case :gen_tcp.send(socket, data) do
      :ok ->
        {:reply, reply, state}
      {:error, _reason} = err ->
        {:disconnect, err, state}
    end
  end

  @spec send_noreply(Redix.Connection.state, iodata) ::
    {:noreply, Redix.Connection.state} |
    {:disconnect, term, Redix.Connection.state}
  def send_noreply(%{socket: socket} = state, data) do
    case :gen_tcp.send(socket, data) do
      :ok ->
        {:noreply, state}
      {:error, _reason} = err ->
        {:disconnect, err, state}
    end
  end

  defp handle_connection_error(:init, {:error, reason, state}) do
    on_failed_connect_hook(state, reason, :init)
  end

  defp handle_connection_error(:backoff, {:error, reason, state}) do
    on_failed_connect_hook(state, reason, {:backoff, state.on_failed_connect_result})
  end

  # Extracts the TCP connection options (host, port and socket opts) from the
  # given `opts`.
  defp tcp_connection_opts(opts) do
    host = to_char_list(Keyword.fetch!(opts, :host))
    port = Keyword.fetch!(opts, :port)
    socket_opts = @socket_opts ++ Keyword.fetch!(opts, :socket_opts)
    timeout = opts[:timeout] || @default_timeout

    {host, port, socket_opts, timeout}
  end

  # Setups the `:buffer` option of the given socket.
  defp setup_socket_buffers(socket) do
    {:ok, [sndbuf: sndbuf, recbuf: recbuf, buffer: buffer]} =
      :inet.getopts(socket, [:sndbuf, :recbuf, :buffer])

    buffer = buffer |> max(sndbuf) |> max(recbuf)
    :ok = :inet.setopts(socket, [buffer: buffer])
  end

  defp on_failed_connect_hook(state, error_reason, arg) do
    fun = state.opts[:on_failed_connect] || fn(_) -> {:backoff, state.opts[:backoff], nil} end

    unless is_function(fun, 1) do
      raise "on_failed_connect is not a function of arity 1"
    end

    case fun.(arg) do
      :stop ->
        {:stop, error_reason, state}
      {:backoff, time, next_result} ->
        {:backoff, time, %{state | on_failed_connect_result: next_result}}
    end
  end
end
