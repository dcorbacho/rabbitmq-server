## The contents of this file are subject to the Mozilla Public License
## Version 1.1 (the "License"); you may not use this file except in
## compliance with the License. You may obtain a copy of the License
## at http://www.mozilla.org/MPL/
##
## Software distributed under the License is distributed on an "AS IS"
## basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
## the License for the specific language governing rights and
## limitations under the License.
##
## The Original Code is RabbitMQ.
##
## The Initial Developer of the Original Code is GoPivotal, Inc.
## Copyright (c) 2007-2016 Pivotal Software, Inc.  All rights reserved.


defmodule RabbitMQCtl do
  alias RabbitMQ.CLI.Distribution,  as: Distribution
  alias RabbitMQ.CLI.StandardCodes, as: StandardCodes

  alias RabbitMQ.CLI.Ctl.Commands.HelpCommand, as: HelpCommand

  import RabbitMQ.CLI.Ctl.Helpers
  import  RabbitMQ.CLI.Ctl.Parser
  import RabbitMQ.CLI.ExitCodes

  def main(["--auto-complete", "./rabbitmqctl " <> str]) do
    auto_complete(str)
  end
  def main(["--auto-complete", "rabbitmqctl " <> str]) do
    auto_complete(str)
  end
  def main(unparsed_command) do
    {parsed_cmd, options, invalid} = parse(unparsed_command)
    case {is_command?(parsed_cmd), invalid} do
      ## No such command
      {false, _}  ->
        HelpCommand.all_usage() |> handle_exit(exit_usage);
      ## Invalid options
      {_, [_|_]}  ->
        print_standard_messages({:bad_option, invalid}, unparsed_command)
        |> handle_exit
      ## Command valid
      {true, []}  ->
        effective_options = options |> merge_defaults_defaults |> normalize_node
        Distribution.start(effective_options)

        effective_options
        |> run_command(parsed_cmd)
        |> StandardCodes.map_to_standard_code
        |> print_standard_messages(unparsed_command)
        |> handle_exit
    end
  end

  def auto_complete(str) do
    AutoComplete.complete(str)
    |> Stream.map(&IO.puts/1) |> Stream.run
    exit_program(exit_ok)
  end

  def merge_defaults_defaults(%{} = options) do
    options
    |> merge_defaults_node
    |> merge_defaults_timeout
    |> merge_defaults_longnames
  end

  defp merge_defaults_node(%{} = opts), do: Map.merge(%{node: get_rabbit_hostname}, opts)

  defp merge_defaults_timeout(%{} = opts), do: Map.merge(%{timeout: :infinity}, opts)

  defp merge_defaults_longnames(%{} = opts), do: Map.merge(%{longnames: false}, opts)

  defp normalize_node(%{node: node} = opts) do
    Map.merge(opts, %{node: parse_node(node)})
  end

  defp maybe_connect_to_rabbitmq("help", _), do: nil
  defp maybe_connect_to_rabbitmq(_, node) do
    connect_to_rabbitmq(node)
  end

  defp run_command(_, []), do: HelpCommand.all_usage()
  defp run_command(options, [command_name | arguments]) do
    with_command(command_name,
        fn(command) ->
            case invalid_flags(command, options) do
              [] ->
                case command.validate(arguments, options) do
                  :ok ->
                    {arguments, options} = command.merge_defaults(arguments, options)
                    print_banner(command, arguments, options)
                    maybe_connect_to_rabbitmq(command_name, options[:node])
                    execute_command(command, arguments, options)
                  err -> err
                end
              result  ->  {:bad_option, result}
            end
        end)
  end

  defp with_command(command_name, fun) do
    command = commands[command_name]
    fun.(command)
  end

  defp print_banner(command, args, opts) do
    case command.banner(args, opts) do
     nil -> nil
     banner -> IO.inspect banner
    end
  end

  defp execute_command(command, arguments, options) do
    command.run(arguments, options)
  end

  defp print_standard_messages({:badrpc, :nodedown} = result, unparsed_command) do
    {_, options, _} = parse(unparsed_command)

    IO.puts "Error: unable to connect to node '#{options[:node]}': nodedown"
    result
  end

  defp print_standard_messages({:badrpc, :timeout} = result, unparsed_command) do
    {_, options, _} = parse(unparsed_command)

    IO.puts "Error: {timeout, #{options[:timeout]}}"
    result
  end

  defp print_standard_messages({:too_many_args, _} = result, unparsed_command) do
    {[cmd | _], _, _} = parse(unparsed_command)

    IO.puts "Error: too many arguments."
    IO.puts "Given:\n\t#{unparsed_command |> Enum.join(" ")}"
    HelpCommand.run([cmd], %{})
    result
  end

  defp print_standard_messages({:not_enough_args, _} = result, unparsed_command) do
    {[cmd | _], _, _} = parse(unparsed_command)

    IO.puts "Error: not enough arguments."
    IO.puts "Given:\n\t#{unparsed_command |> Enum.join(" ")}"
    HelpCommand.run([cmd], %{})

    result
  end

  defp print_standard_messages({:refused, user, _, _} = result, _) do
    IO.puts "Error: failed to authenticate user \"#{user}\""
    result
  end

  defp print_standard_messages(
    {failed_command,
     {:mnesia_unexpectedly_running, node_name}} = result, _)
  when
    failed_command == :reset_failed or
    failed_command == :join_cluster_failed
  do
    IO.puts "Mnesia is still running on node #{node_name}."
    IO.puts "Please stop RabbitMQ with rabbitmqctl stop_app first."
    result
  end

  defp print_standard_messages({:error, :process_not_running} = result, _) do
    IO.puts "Error: process is not running."
    result
  end

  defp print_standard_messages({:error, {:garbage_in_pid_file, _}} = result, _) do
    IO.puts "Error: garbage in pid file."
    result
  end

  defp print_standard_messages({:error, {:could_not_read_pid, err}} = result, _) do
    IO.puts "Error: could not read pid. Detail: #{err}"
    result
  end

  defp print_standard_messages({:healthcheck_failed, message} = result, _) do
    IO.puts "Error: healthcheck failed. Message: #{message}"
    result
  end

  defp print_standard_messages({:bad_option, opt} = result, unparsed_command) do
    case parse(unparsed_command) do
      {[cmd | _], _, _} ->
        IO.puts "Error: invalid options for this command."
        IO.puts "Given:\n\t#{unparsed_command |> Enum.join(" ")}"
        HelpCommand.run([cmd], %{})
        result;
      _ ->
        IO.puts "Error: invalid options"
        IO.inspect opt
        HelpCommand.all_usage()
        result
    end
  end

  defp print_standard_messages({:validation_failure, err_detail} = result, unparsed_command) do
    {[command_name | _], _, _} = parse(unparsed_command)
    err = format_validation_error(err_detail) # TODO format the error better
    IO.puts "Error: #{err}"
    IO.puts "Given:\n\t#{unparsed_command |> Enum.join(" ")}"

    case is_command?(command_name) do
      true  ->
        command = commands[command_name]
        HelpCommand.print_base_usage(command)
      false ->
        HelpCommand.all_usage()
        exit_usage
    end

    result
  end

  defp print_standard_messages(result, _) do
    result
  end

  defp format_validation_error(:not_enough_args), do: "not enough arguments."
  defp format_validation_error({:not_enough_args, detail}), do: "not enough arguments. #{detail}"
  defp format_validation_error(:too_many_args), do: "too many arguments."
  defp format_validation_error({:too_many_args, detail}), do: "too many arguments. #{detail}"
  defp format_validation_error(:bad_argument), do: "Bad argument."
  defp format_validation_error({:bad_argument, detail}), do: "Bad argument. #{detail}"
  defp format_validation_error(err), do: inspect err

  defp handle_exit({:validation_failure, :not_enough_args}), do: exit_program(exit_usage)
  defp handle_exit({:validation_failure, :too_many_args}), do: exit_program(exit_usage)
  defp handle_exit({:validation_failure, {:not_enough_args, _}}), do: exit_program(exit_usage)
  defp handle_exit({:validation_failure, {:too_many_args, _}}), do: exit_program(exit_usage)
  defp handle_exit({:validation_failure, {:bad_argument, _}}), do: exit_program(exit_dataerr)
  defp handle_exit({:validation_failure, :bad_argument}), do: exit_program(exit_dataerr)
  defp handle_exit({:validation_failure, _}), do: exit_program(exit_usage)
  defp handle_exit({:bad_option, _} = _err), do: exit_program(exit_usage)
  defp handle_exit({:badrpc, :timeout}), do: exit_program(exit_tempfail)
  defp handle_exit({:badrpc, :nodedown}), do: exit_program(exit_unavailable)
  defp handle_exit({:refused, _, _, _}), do: exit_program(exit_dataerr)
  defp handle_exit({:healthcheck_failed, _}), do: exit_program(exit_software)
  defp handle_exit({:join_cluster_failed, _}), do: exit_program(exit_software)
  defp handle_exit({:reset_failed, _}), do: exit_program(exit_software)
  defp handle_exit({:error, _}), do: exit_program(exit_software)
  defp handle_exit(true), do: handle_exit(:ok, exit_ok)
  defp handle_exit(:ok), do: handle_exit(:ok, exit_ok)
  defp handle_exit({:ok, result}), do: handle_exit({:ok, result}, exit_ok)
  defp handle_exit(result) when is_list(result), do: handle_exit({:ok, result}, exit_ok)
  defp handle_exit(:ok, code), do: exit_program(code)
  defp handle_exit({:ok, result}, code) do
    case Enumerable.impl_for(result) do
      nil -> IO.inspect result;
      _   -> result |> Stream.map(&IO.inspect/1) |> Stream.run
    end
    exit_program(code)
  end

  defp invalid_flags(command, opts) do
    Map.keys(opts) -- (command.flags ++ global_flags)
  end

  defp exit_program(code) do
    :net_kernel.stop
    exit({:shutdown, code})
  end
end
