defmodule NewRelic.Error.Reporter do
  @moduledoc false

  alias NewRelic.Util
  alias NewRelic.Harvest.Collector

  def report_error(_, [
        {:initial_call, _},
        {:pid, _},
        {:registered_name, _},
        {:error_info, {:exit, {{{%{plug_status: plug_status}, _plug_stack}, _init_call}, _}, _}}
        | _
      ])
      when plug_status < 500 do
    :ignore
  end

  def report_error(:transaction, report) do
    {kind, exception, stacktrace} = parse_error_info(report[:error_info])
    process_name = parse_process_name(report[:registered_name], stacktrace)

    NewRelic.add_attributes(process: process_name)

    NewRelic.Transaction.Reporter.fail(%{
      kind: kind,
      reason: exception,
      stack: stacktrace
    })
  end

  def report_error(:process, report) do
    {kind, exception, stacktrace} = parse_error_info(report[:error_info])

    {exception_type, exception_reason, exception_stacktrace} =
      Util.Error.normalize(kind, exception, stacktrace, report[:initial_call])

    process_name = parse_process_name(report[:registered_name], stacktrace)
    expected = parse_error_expected(exception)
    automatic_attributes = NewRelic.Config.automatic_attributes()

    Collector.ErrorTrace.Harvester.report_error(%NewRelic.Error.Trace{
      timestamp: System.system_time(:millisecond) / 1_000,
      error_type: exception_type,
      message: exception_reason,
      expected: expected,
      stack_trace: exception_stacktrace,
      transaction_name: "OtherTransaction/Elixir/ElixirProcess//#{process_name}",
      user_attributes:
        Map.merge(automatic_attributes, %{
          process: process_name
        })
    })

    Collector.TransactionErrorEvent.Harvester.report_error(%NewRelic.Error.Event{
      timestamp: System.system_time(:millisecond) / 1_000,
      error_class: exception_type,
      error_message: exception_reason,
      expected: expected,
      transaction_name: "OtherTransaction/Elixir/ElixirProcess//#{process_name}",
      user_attributes:
        Map.merge(automatic_attributes, %{
          process: process_name,
          stacktrace: Enum.join(exception_stacktrace, "\n")
        })
    })

    unless expected do
      NewRelic.report_metric({:supportability, :error_event}, error_count: 1)
      NewRelic.report_metric(:error, error_count: 1)
    end
  end

  defp parse_process_name([], [{module, _f, _a, _} | _]), do: inspect(module)
  defp parse_process_name([], _stacktrace), do: "UnknownProcess"
  defp parse_process_name(registered_name, _stacktrace), do: inspect(registered_name)

  defp parse_error_info({kind, {{{exception, stacktrace}, _init_call}, _init_stack}, _proc_stack}) do
    {kind, exception, stacktrace}
  end

  defp parse_error_info({kind, {exception, stacktrace}, _stack}) when is_list(stacktrace) do
    {kind, exception, stacktrace}
  end

  defp parse_error_info({kind, exception, stacktrace}), do: {kind, exception, stacktrace}

  defp parse_error_expected(%{expected: true}), do: true
  defp parse_error_expected(_), do: false
end
