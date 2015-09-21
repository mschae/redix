defmodule Redix.Connection.Listener do
  use GenServer

  alias Redix.Protocol

  @initial_state %{
    parent: nil,
    queue: :queue.new,
    tail: <<>>,
    socket: nil,
  }

  ## Client

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, [])
  end

  def enqueue(pid, what) do
    GenServer.cast(pid, {:enqueue, what})
  end

  ## Server callbacks

  def init(opts) do
    {:ok, Dict.merge(@initial_state, opts)}
  end

  def handle_cast({:enqueue, what}, s) do
    s = update_in(s.queue, &:queue.in(what, &1))
    {:noreply, s}
  end

  @doc false
  def handle_info(msg, s)

  def handle_info({:tcp, socket, data}, %{socket: socket} = s) do
    :ok = :inet.setopts(socket, active: :once)
    s = new_data(s, s.tail <> data)
    {:noreply, s}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = s) do
    # {:disconnect, {:error, :tcp_closed}, s}
    send_to_parent(s, {:disconnect, {:error, :tcp_closed}})
    {:noreply, s}
  end

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = s) do
    # {:disconnect, {:error, reason}, s}
    send_to_parent(s, {:disconnect, {:error, reason}})
    {:noreply, s}
  end

  ## Helper functions

  defp new_data(s, <<>>) do
    %{s | tail: <<>>}
  end

  defp new_data(s, data) do
    {{:value, {:commands, from, ncommands}}, new_queue} = :queue.out(s.queue)

    case Protocol.parse_multi(data, ncommands) do
      {:ok, resp, rest} ->
        # Connection.reply(from, format_resp(resp))
        send_to_parent(s, {:reply, from, format_resp(resp)})
        s = %{s | queue: new_queue}
        new_data(s, rest)
      {:error, :incomplete} ->
        %{s | tail: data}
    end
  end

  defp format_resp(%Redix.Error{} = err), do: {:error, err}
  defp format_resp(resp), do: {:ok, resp}

  defp send_to_parent(s, msg) do
    send(s.parent, {:redix_listener, self(), msg})
  end
end
