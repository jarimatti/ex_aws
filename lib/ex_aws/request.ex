defmodule ExAws.Request do
  @moduledoc false

  require Logger

  @type http_status :: pos_integer
  @type success_content :: %{body: binary, headers: [{binary, binary}]}
  @type success_t :: {:ok, success_content}
  @type error_t :: {:error, {:http_error, http_status, binary}}
  @type response_t :: success_t | error_t

  def request(http_method, url, data, headers, config, service) do
    body =
      case data do
        [] -> "{}"
        d when is_binary(d) -> d
        _ -> config[:json_codec].encode!(data)
      end

    request_and_retry(http_method, url, service, config, headers, body, {:attempt, 1})
  end

  def request_and_retry(_method, _url, _service, _config, _headers, _req_body, {:error, reason}),
    do: {:error, reason}

  def request_and_retry(method, url, service, config, headers, req_body, {:attempt, attempt}) do
    full_headers = ExAws.Auth.headers(method, url, service, config, headers, req_body)

    with {:ok, full_headers} <- full_headers do
      safe_url = ExAws.Request.Url.sanitize(url, service)

      if config[:debug_requests] do
        Logger.debug(
          "ExAws: Request URL: #{inspect(safe_url)} HEADERS: #{inspect(full_headers)} BODY: #{inspect(req_body)} ATTEMPT: #{attempt}"
        )
      end

      case do_request(config, method, safe_url, req_body, full_headers, attempt, service) do
        {:ok, %{status_code: status} = resp} when status in 200..299 or status == 304 ->
          {:ok, resp}

        {:ok, %{status_code: status} = _resp} when status == 301 ->
          Logger.warning("ExAws: Received redirect, did you specify the correct region?")
          {:error, {:http_error, status, "redirected"}}

        {:ok, %{status_code: status} = resp} when status in 400..499 ->
          case client_error(resp, config[:json_codec]) do
            {:retry, reason} ->
              request_and_retry(
                method,
                url,
                service,
                config,
                headers,
                req_body,
                attempt_again?(attempt, reason, :client, config)
              )

            {:error, reason} ->
              {:error, reason}
          end

        {:ok, %{status_code: status} = resp} when status >= 500 ->
          body = Map.get(resp, :body)
          reason = {:http_error, status, body}

          request_and_retry(
            method,
            url,
            service,
            config,
            headers,
            req_body,
            attempt_again?(attempt, reason, :server, config)
          )

        {:error, reason_struct} ->
          reason =
            case reason_struct do
              %{reason: reason} -> reason
              [reason: reason] -> reason
            end

          Logger.warning(
            "ExAws: HTTP ERROR: #{inspect(reason)} for URL: #{inspect(safe_url)} ATTEMPT: #{attempt}"
          )

          request_and_retry(
            method,
            url,
            service,
            config,
            headers,
            req_body,
            attempt_again?(attempt, reason, :other, config)
          )
      end
    end
  end

  defp do_request(config, method, safe_url, req_body, full_headers, attempt, service) do
    telemetry_event = Map.get(config, :telemetry_event, [:ex_aws, :request])
    telemetry_options = Map.get(config, :telemetry_options, [])

    telemetry_metadata = %{
      options: telemetry_options,
      attempt: attempt,
      service: service,
      request_body: req_body,
      operation: extract_operation(full_headers)
    }

    :telemetry.span(telemetry_event, telemetry_metadata, fn ->
      result =
        config[:http_client].request(
          method,
          safe_url,
          req_body,
          full_headers,
          Map.get(config, :http_opts, [])
        )
        |> maybe_transform_response()

      stop_metadata =
        case result do
          {:ok, %{status_code: status} = resp} when status in 200..299 or status == 304 ->
            %{result: :ok, response_body: Map.get(resp, :body)}

          error ->
            %{result: :error, error: extract_error(error)}
        end

      telemetry_metadata = Map.merge(telemetry_metadata, stop_metadata)
      {result, telemetry_metadata}
    end)
  end

  defp extract_operation(headers), do: Enum.find_value(headers, &match_operation/1)

  defp match_operation({"x-amz-target", value}), do: value
  defp match_operation({_key, _value}), do: nil

  defp extract_error({:ok, %{body: body}}), do: body
  defp extract_error({:ok, response}), do: response
  defp extract_error({:error, error}), do: error
  defp extract_error(error), do: error

  def client_error(%{status_code: status, body: body} = error, json_codec) do
    case json_codec.decode(body) do
      {:ok, %{"__type" => error_type, "message" => message} = err} ->
        handle_error(error_type, message, status, err)

      # Rather irritatingly, as of 1.15, the local version of DynamoDB returns this with a
      # capital M in "Message"
      {:ok, %{"__type" => error_type, "Message" => message} = err} ->
        handle_error(error_type, message, status, err)

      _ ->
        {:error, {:http_error, status, error}}
    end
  end

  def client_error(%{status_code: status} = error, _) do
    {:error, {:http_error, status, error}}
  end

  def handle_aws_error({"ProvisionedThroughputExceededException" = type, message, _}) do
    {:retry, {type, message}}
  end

  def handle_aws_error({"ThrottlingException" = type, message, _}) do
    {:retry, {type, message}}
  end

  def handle_aws_error({"TooManyRequestsException" = type, message, _}) do
    {:retry, {type, message}}
  end

  def handle_aws_error({type, message, %{"expectedSequenceToken" => expected_sequence_token}}) do
    {:error, {type, message, expected_sequence_token}}
  end

  def handle_aws_error({type, message, err}) do
    # Mark as unhandled, might intereset error_parsers.
    {:error, {:aws_unhandled, type, message, err}}
  end

  # Clear unhandled mark, so Request.request() callers don't see it.
  def default_aws_error({:error, {:aws_unhandled, type, message, _}}) do
    {:error, {type, message}}
  end

  def default_aws_error(result) do
    result
  end

  defp handle_error(error_type, message, status, err) do
    error_type
    |> String.split("#")
    |> case do
      [_, type] -> handle_aws_error({type, message, err})
      [type] -> handle_aws_error({type, message, err})
      _ -> {:error, {:http_error, status, err}}
    end
  end

  def attempt_again?(attempt, reason, error_type, config) do
    max_attempts =
      case error_type do
        :client -> config[:retries][:client_error_max_attempts] || config[:retries][:max_attempts]
        _ -> config[:retries][:max_attempts]
      end

    if attempt >= max_attempts do
      {:error, reason}
    else
      attempt |> backoff(config)
      {:attempt, attempt + 1}
    end
  end

  def backoff(attempt, config) do
    (config[:retries][:base_backoff_in_ms] * :math.pow(2, attempt))
    |> min(config[:retries][:max_backoff_in_ms])
    |> trunc
    |> :rand.uniform()
    |> :timer.sleep()
  end

  def maybe_transform_response({:ok, %{status: status, body: body, headers: headers}}) do
    # Req and Finch use status (rather than status_code) as a key.
    {:ok, %{status_code: status, body: body, headers: headers}}
  end

  def maybe_transform_response(response), do: response
end
