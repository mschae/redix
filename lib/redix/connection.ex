defmodule Redix.Connection do
  @moduledoc false

  use Connection

  alias Redix.Protocol
  alias Redix.ConnectionUtils
  alias Redix.Connection.Listener
  require Logger

  @type state :: %{}

  @initial_state %{
    # The TCP socket that holds the connection to Redis
    socket: nil,
    # The data that couldn't be parsed (yet)
    tail: "",
    # Options passed when the connection is started
    opts: nil,
    # A queue of operations waiting for a response
    queue: :queue.new,
    # The number of times a reconnection has been attempted
    reconnection_attempts: 0,

    listener: nil,
  }

  ## Callbacks

  @doc false
  def init(opts) do
    {:connect, :init, Dict.merge(@initial_state, opts: opts)}
  end

  @doc false
  def connect(info, s)

  def connect(info, s) do
    case ConnectionUtils.connect(info, s) do
      {:ok, s} ->
        s = start_listener_process(s)
        {:ok, s}
      o ->
        o
    end
  end

  @doc false
  def disconnect(reason, s)

  def disconnect(:stop, s) do
    {:stop, :normal, s}
  end

  def disconnect({:error, reason} = _error, %{queue: _queue} = s) do
    Logger.error "Disconnected from Redis (#{ConnectionUtils.host_for_logging(s)}): #{inspect reason}"

    :gen_tcp.close(s.socket)

    for {:commands, from, _} <- :queue.to_list(s.queue) do
      Connection.reply(from, {:error, :disconnected})
    end

    # Backoff with 0 ms as the backoff time to churn through all the commands in
    # the mailbox before reconnecting.
    s
    |> reset_state
    |> ConnectionUtils.backoff_or_stop(0, reason)
  end

  @doc false
  def handle_call(operation, from, s)

  def handle_call(_operation, _from, %{socket: nil} = s) do
    {:reply, {:error, :closed}, s}
  end

  def handle_call({:commands, commands}, from, s) do
    Listener.enqueue(s.listener, {:commands, from, length(commands)})
    ConnectionUtils.send_noreply(s, Enum.map(commands, &Protocol.pack/1))
  end

  @doc false
  def handle_cast(operation, s)

  def handle_cast(:stop, s) do
    {:disconnect, :stop, s}
  end

  @doc false
  def handle_info({:redix_listener, listener, msg}, %{listener: listener} = s) do
    handle_msg_from_listener(msg, s)
  end

  defp reset_state(s) do
    %{s | queue: :queue.new, tail: "", socket: nil}
  end

  defp start_listener_process(s) do
    {:ok, pid} = Listener.start_link(parent: self(), socket: s.socket)
    :ok = :gen_tcp.controlling_process(s.socket, pid)
    :ok = :inet.setopts(s.socket, active: :once)
    %{s | listener: pid}
  end

  defp handle_msg_from_listener({:disconnect, info}, s) do
    {:disconnect, info, s}
  end

  defp handle_msg_from_listener({:reply, from, reply}, s) do
    Connection.reply(from, reply)
    {:noreply, s}
  end
end
