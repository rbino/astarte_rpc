defmodule Astarte.RPC.AMQPServer do
  @callback process_rpc(payload :: binary) :: :ok | {:ok, reply :: term} | {:error, reason :: term}

  require Logger
  use GenServer
  use AMQP

  @connection_backoff 10000
  @queue "rpc_queue"

  def start_link do
    GenServer.start_link(__MODULE__, [])
  end

  def init(_opts) do
    rabbitmq_connect(false)
  end

  defp rabbitmq_connect(retry \\ true) do
    options = []
    with {:ok, conn} <- Connection.open(options),
         # Get notifications when the connection goes down
         Process.monitor(conn.pid),
         # We link the connection to this process, that way if we die the connection dies too
         # This is useful since unacked messages are requeued only after the connection is dead
         Process.link(conn.pid),
         {:ok, chan} <- Channel.open(conn),
         {:ok, _consumer_tag} <- Basic.consume(chan, @queue) do
      {:ok, chan}

    else
      {:error, reason} ->
        Logger.warn("RabbitMQ Connection error: " <> inspect(reason))
        maybe_retry(retry)
      :error ->
        Logger.warn("Unknown RabbitMQ connection error")
        maybe_retry(retry)
    end
  end

  defp maybe_retry(retry) do
    if retry do
      :timer.sleep(@connection_backoff)
      rabbitmq_connect(retry)
    else
      {:ok, nil}
    end
  end

  # Server callbacks

  # Confirmation sent by the broker after registering this process as a consumer
  def handle_info({:basic_consume_ok, %{consumer_tag: _consumer_tag}}, chan) do
    {:noreply, chan}
  end

  # Sent by the broker when the consumer is unexpectedly cancelled (such as after a queue deletion)
  def handle_info({:basic_cancel, %{consumer_tag: _consumer_tag}}, chan) do
    {:stop, :normal, chan}
  end

  # Confirmation sent by the broker to the consumer process after a Basic.cancel
  def handle_info({:basic_cancel_ok, %{consumer_tag: _consumer_tag}}, chan) do
    {:noreply, chan}
  end

  def handle_info({:basic_deliver, payload, meta}, chan) do
    # We process the message asynchronously
    spawn_link fn -> consume(chan, meta, payload) end
    {:noreply, chan}
  end

  # This callback should try to reconnect to the server
  def handle_info({:DOWN, _, :process, _pid, _reason}, _chan) do
    {:ok, new_chan} = rabbitmq_connect()
    {:noreply, new_chan}
  end

  defp consume(chan, meta, payload) do
    case IO.puts(inspect(payload)) do
      :ok ->
        Basic.ack(chan, meta.delivery_tag)

      {:ok, reply} ->
        Basic.ack(chan, meta.delivery_tag)
        case meta.reply_to do
          :undefined ->
            Logger.warn("Got a reply but no queue to write it to")

          routing_key ->
            Basic.publish(chan, "", routing_key, reply, [correlation_id: meta.correlation_id])
        end

      # We don't want to keep failing on the same message
      {:error, reason} ->
        Basic.reject(chan, meta.delivery_tag, [requeue: not meta.redelivered])
        # TODO: we want to be notified in some other way of failing messages
        Logger.warn("Message rejected with reason #{inspect(reason)}")
    end
  end
end
