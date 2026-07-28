defmodule Sxf.GitHub.IssuePoller do
  @moduledoc """
  One-shot, bounded GitHub issue polling for the M3 scratch repository.

  The poller fetches and validates the complete bounded provider view before writing any durable
  observation. It never schedules itself, sleeps, dispatches work, or mutates GitHub.
  """

  alias Sxf.GitHub.AppAuth
  alias Sxf.GitHub.Client
  alias Sxf.GitHub.Client.Failure
  alias Sxf.ProjectRegistry
  alias Sxf.Tasks

  @owner "kool1160"
  @repository "sxf-m3-scratch"
  @per_page 100
  @default_max_pages 10
  @default_max_observations 500
  @max_title_bytes 500
  @max_body_bytes 65_536
  @max_labels 100

  @required_options [
    :repository_external_id,
    :app_id,
    :installation_id,
    :actor_id,
    :private_key_resolver,
    :transport,
    :now_fn,
    :correlation_id_fn
  ]

  @doc """
  Executes one bounded provider read and normalizes all valid eligible observations.
  """
  def poll_once(opts) when is_list(opts) do
    with :ok <- validate_options(opts),
         {:ok, registration} <- lookup_registration(opts),
         {:ok, token} <- mint_token(registration, opts),
         {:ok, repo_response} <-
           Client.get_repository(
             token,
             registration.repository.external_id,
             client_opts(opts)
           ),
         :ok <- verify_repository(repo_response.body, registration.repository),
         {:ok, fetched} <- fetch_all_issues(token, registration.repository, opts),
         {:ok, summary} <- normalize_observations(fetched, registration.repository, opts) do
      {:ok,
       summary
       |> Map.put(:repository, %{
         provider: "github",
         external_id: registration.repository.external_id,
         owner: registration.repository.owner,
         name: registration.repository.name
       })
       |> Map.put(
         :provider_request_ids,
         Enum.uniq(
           token.provider_request_ids ++
             repo_response.provider_request_ids ++ fetched.provider_request_ids
         )
       )
       |> Map.put(:rate_limit, fetched.rate_limit)}
    end
  end

  def poll_once(_opts), do: {:error, %Failure{kind: :invalid_poll_options}}

  @doc """
  Produces the deterministic semantic SHA-256 used by durable issue normalization.
  """
  def canonical_payload_sha256(observation) when is_map(observation) do
    observation
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp validate_options(opts) do
    missing = Enum.find(@required_options, &is_nil(Keyword.get(opts, &1)))
    max_pages = Keyword.get(opts, :max_pages, @default_max_pages)
    max_observations = Keyword.get(opts, :max_observations, @default_max_observations)

    cond do
      not is_nil(missing) ->
        {:error, %Failure{kind: {:missing_poll_option, missing}}}

      Keyword.get(opts, :provider, "github") != "github" ->
        {:error, %Failure{kind: :unsupported_provider}}

      not positive_bound?(max_pages) ->
        {:error, %Failure{kind: :invalid_page_limit}}

      not positive_bound?(max_observations) ->
        {:error, %Failure{kind: :invalid_observation_limit}}

      true ->
        :ok
    end
  end

  defp lookup_registration(opts) do
    case ProjectRegistry.lookup_repository("github", opts[:repository_external_id]) do
      {:ok, result} ->
        cond do
          result.project.status != "active" ->
            {:error, %Failure{kind: :repository_archived}}

          result.repository.provider != "github" ->
            {:error, %Failure{kind: :unsupported_provider}}

          result.repository.owner != @owner or result.repository.name != @repository ->
            {:error, %Failure{kind: :repository_not_approved}}

          incomplete_registration?(result.repository, result.manifest) ->
            {:error, %Failure{kind: :registration_incomplete}}

          true ->
            {:ok, result}
        end

      {:error, :registration_not_found} ->
        {:error, %Failure{kind: :registration_not_found}}

      {:error, reason} ->
        {:error, %Failure{kind: reason}}
    end
  end

  defp mint_token(registration, opts) do
    auth_opts =
      opts
      |> Keyword.take([
        :app_id,
        :installation_id,
        :private_key_resolver,
        :transport,
        :now_fn
      ])
      |> Keyword.put(:repository_id, registration.repository.external_id)

    case AppAuth.mint_installation_token(auth_opts) do
      {:ok, token} -> {:ok, token}
      {:error, %Failure{} = failure} -> {:error, failure}
      {:error, reason} -> {:error, %Failure{kind: reason}}
    end
  end

  defp verify_repository(body, repository) when is_map(body) do
    owner =
      case body["owner"] do
        value when is_map(value) -> value["login"]
        _other -> nil
      end

    cond do
      not same_repository_id?(body["id"], repository.external_id) ->
        {:error, %Failure{kind: :repository_identity_mismatch}}

      owner != repository.owner or body["name"] != repository.name ->
        {:error, %Failure{kind: :repository_name_mismatch}}

      body["archived"] == true ->
        {:error, %Failure{kind: :repository_archived}}

      true ->
        :ok
    end
  end

  defp verify_repository(_body, _repository),
    do: {:error, %Failure{kind: :malformed_repository_response}}

  defp fetch_all_issues(token, repository, opts) do
    max_pages = Keyword.get(opts, :max_pages, @default_max_pages)
    max_observations = Keyword.get(opts, :max_observations, @default_max_observations)

    fetch_page(token, repository, opts, %{
      page: 1,
      max_pages: max_pages,
      max_observations: max_observations,
      pages: [],
      observations_seen: 0,
      provider_request_ids: [],
      rate_limit: %{}
    })
  end

  defp fetch_page(token, repository, opts, state) do
    with {:ok, response} <-
           Client.list_issues(
             token,
             repository.owner,
             repository.name,
             state.page,
             @per_page,
             client_opts(opts)
           ),
         true <- is_list(response.body) do
      observations_seen = state.observations_seen + length(response.body)
      has_next = next_page?(response.headers)

      cond do
        length(response.body) > @per_page ->
          {:error, %Failure{kind: :provider_page_size_exceeded}}

        observations_seen > state.max_observations ->
          {:error, %Failure{kind: :observation_limit_exceeded}}

        has_next and state.page >= state.max_pages ->
          {:error, %Failure{kind: :pagination_limit_exceeded}}

        true ->
          next_state = %{
            state
            | page: state.page + 1,
              pages: [response.body | state.pages],
              observations_seen: observations_seen,
              provider_request_ids: state.provider_request_ids ++ response.provider_request_ids,
              rate_limit: response.rate_limit
          }

          if has_next do
            fetch_page(token, repository, opts, next_state)
          else
            {:ok,
             %{
               pages_fetched: state.page,
               observations_seen: observations_seen,
               issues: next_state.pages |> Enum.reverse() |> List.flatten(),
               provider_request_ids: next_state.provider_request_ids,
               rate_limit: next_state.rate_limit
             }}
          end
      end
    else
      false -> {:error, %Failure{kind: :malformed_issues_response}}
      {:error, %Failure{} = failure} -> {:error, failure}
    end
  end

  defp normalize_observations(fetched, repository, opts) do
    {eligible, rejected} =
      fetched.issues
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {issue, index}, {accepted, failures} ->
        case canonical_observation(issue, repository) do
          {:ok, observation} -> {[observation | accepted], failures}
          :ineligible -> {accepted, failures}
          {:error, code} -> {accepted, [%{index: index, code: code} | failures]}
        end
      end)

    eligible =
      Enum.sort_by(eligible, fn observation ->
        {DateTime.to_unix(observation.updated_at, :microsecond), observation.issue_external_id}
      end)

    initial = %{
      pages_fetched: fetched.pages_fetched,
      observations_seen: fetched.observations_seen,
      issues_accepted: 0,
      tasks_created: 0,
      observations_replayed: 0,
      normalization_conflicts: 0,
      rejected_malformed_observations: Enum.reverse(rejected),
      retry_at: nil
    }

    with {:ok, commands} <- normalization_commands(eligible, opts) do
      Enum.reduce_while(commands, {:ok, initial}, fn attrs, {:ok, summary} ->
        case Tasks.normalize_external_issue(attrs) do
          {:ok, result} ->
            summary =
              summary
              |> Map.update!(:issues_accepted, &(&1 + 1))
              |> Map.update!(
                :tasks_created,
                &(&1 + if(result.task_created? and not result.idempotent?, do: 1, else: 0))
              )
              |> Map.update!(
                :observations_replayed,
                &(&1 + if(result.idempotent?, do: 1, else: 0))
              )

            {:cont, {:ok, summary}}

          {:error, :idempotency_conflict} ->
            {:cont,
             {:ok,
              summary
              |> Map.update!(:issues_accepted, &(&1 + 1))
              |> Map.update!(:normalization_conflicts, &(&1 + 1))}}

          {:error, {:invalid_command_field, _field}} ->
            rejection = %{
              issue_external_id: attrs.issue_external_id,
              code: :normalization_rejected
            }

            {:cont,
             {:ok,
              Map.update!(
                summary,
                :rejected_malformed_observations,
                &(&1 ++ [rejection])
              )}}

          {:error, reason} ->
            {:halt, {:error, %Failure{kind: {:durable_normalization_failed, reason}}}}
        end
      end)
    end
  end

  defp normalization_commands(observations, opts) do
    Enum.reduce_while(observations, {:ok, []}, fn observation, {:ok, commands} ->
      case normalization_attrs(observation, opts) do
        {:ok, attrs} -> {:cont, {:ok, [attrs | commands]}}
        {:error, %Failure{} = failure} -> {:halt, {:error, failure}}
      end
    end)
    |> case do
      {:ok, commands} -> {:ok, Enum.reverse(commands)}
      error -> error
    end
  end

  defp canonical_observation(issue, repository) when is_map(issue) do
    cond do
      Map.has_key?(issue, "pull_request") ->
        :ineligible

      issue["state"] == "closed" ->
        :ineligible

      issue["state"] != "open" ->
        {:error, :invalid_state}

      not is_list(issue["labels"]) ->
        {:error, :invalid_labels}

      not exact_ready_label?(issue["labels"]) ->
        :ineligible

      true ->
        build_observation(issue, repository)
    end
  end

  defp canonical_observation(_issue, _repository), do: {:error, :issue_not_an_object}

  defp build_observation(issue, repository) do
    with {:ok, issue_external_id} <- positive_id(issue["id"], :invalid_issue_id),
         {:ok, issue_number} <- positive_integer(issue["number"], :invalid_issue_number),
         {:ok, updated_at} <- parse_updated_at(issue["updated_at"]),
         {:ok, title} <- bounded_string(issue["title"], @max_title_bytes, false, :invalid_title),
         {:ok, body} <- issue_body(issue["body"]),
         {:ok, labels} <- canonical_labels(issue["labels"]),
         {:ok, metadata} <-
           issue_metadata(issue, repository, issue_number, labels) do
      semantic = %{
        "provider" => "github",
        "repository_external_id" => repository.external_id,
        "issue_external_id" => issue_external_id,
        "source_version" => issue["updated_at"],
        "title" => title,
        "body" => body,
        "metadata" => metadata
      }

      {:ok,
       %{
         issue_external_id: issue_external_id,
         source_version: issue["updated_at"],
         updated_at: updated_at,
         title: title,
         body: body,
         metadata: metadata,
         payload_sha256: canonical_payload_sha256(semantic)
       }}
    end
  end

  defp issue_metadata(issue, repository, issue_number, labels) do
    with {:ok, html_url} <- optional_bounded_string(issue["html_url"], 2_048, :invalid_html_url),
         {:ok, api_url} <- optional_bounded_string(issue["url"], 2_048, :invalid_api_url),
         {:ok, author} <- canonical_author(issue["user"]) do
      {:ok,
       %{
         "issue_number" => issue_number,
         "repository" => %{"owner" => repository.owner, "name" => repository.name},
         "html_url" => html_url,
         "api_url" => api_url,
         "labels" => labels,
         "state" => "open",
         "author" => author
       }}
    end
  end

  defp canonical_labels(labels) when is_list(labels) and length(labels) <= @max_labels do
    labels
    |> Enum.reduce_while({:ok, []}, fn
      %{"name" => name} = label, {:ok, acc} ->
        with {:ok, name} <- bounded_string(name, 255, false, :invalid_label),
             {:ok, color} <-
               optional_bounded_string(label["color"], 32, :invalid_label_color),
             {:ok, description} <-
               optional_bounded_string(label["description"], 1_024, :invalid_label_description) do
          {:cont,
           {:ok,
            [
              %{"name" => name, "color" => color, "description" => description}
              | acc
            ]}}
        else
          {:error, code} -> {:halt, {:error, code}}
        end

      name, {:ok, acc} when is_binary(name) ->
        case bounded_string(name, 255, false, :invalid_label) do
          {:ok, name} ->
            {:cont, {:ok, [%{"name" => name, "color" => nil, "description" => nil} | acc]}}

          {:error, code} ->
            {:halt, {:error, code}}
        end

      _label, _acc ->
        {:halt, {:error, :invalid_label}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.sort_by(normalized, & &1["name"])}
      error -> error
    end
  end

  defp canonical_labels(_labels), do: {:error, :invalid_labels}

  defp canonical_author(nil), do: {:ok, nil}

  defp canonical_author(author) when is_map(author) do
    with {:ok, id} <- optional_positive_id(author["id"], :invalid_author_id),
         {:ok, login} <- optional_bounded_string(author["login"], 255, :invalid_author_login),
         {:ok, display_url} <-
           optional_bounded_string(author["html_url"], 2_048, :invalid_author_url) do
      {:ok, %{"id" => id, "login" => login, "html_url" => display_url}}
    end
  end

  defp canonical_author(_author), do: {:error, :invalid_author}

  defp normalization_attrs(observation, opts) do
    with {:ok, received_at} <- trusted_now(opts),
         {:ok, correlation_id} <- correlation_id(opts) do
      {:ok,
       %{
         provider: "github",
         repository_external_id: opts[:repository_external_id],
         issue_external_id: observation.issue_external_id,
         source_version: observation.source_version,
         payload_sha256: observation.payload_sha256,
         title: observation.title,
         body: observation.body,
         actor_id: opts[:actor_id],
         received_at: received_at,
         correlation_id: correlation_id,
         metadata: observation.metadata
       }}
    end
  end

  defp exact_ready_label?(labels) when is_list(labels) do
    Enum.any?(labels, fn
      %{"name" => "sxf:ready"} -> true
      "sxf:ready" -> true
      _other -> false
    end)
  end

  defp exact_ready_label?(_labels), do: false

  defp issue_body(nil), do: {:ok, ""}
  defp issue_body(value), do: bounded_string(value, @max_body_bytes, true, :invalid_body)

  defp bounded_string(value, max_bytes, allow_empty?, code)
       when is_binary(value) and byte_size(value) <= max_bytes do
    if String.valid?(value) and (allow_empty? or String.trim(value) != ""),
      do: {:ok, value},
      else: {:error, code}
  end

  defp bounded_string(_value, _max_bytes, _allow_empty?, code), do: {:error, code}

  defp optional_bounded_string(nil, _max_bytes, _code), do: {:ok, nil}

  defp optional_bounded_string(value, max_bytes, code),
    do: bounded_string(value, max_bytes, true, code)

  defp parse_updated_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _other -> {:error, :invalid_updated_at}
    end
  end

  defp parse_updated_at(_value), do: {:error, :invalid_updated_at}

  defp positive_id(value, code) do
    with {:ok, integer} <- positive_integer(value, code) do
      {:ok, Integer.to_string(integer)}
    end
  end

  defp optional_positive_id(nil, _code), do: {:ok, nil}
  defp optional_positive_id(value, code), do: positive_id(value, code)

  defp positive_integer(value, _code) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value, code) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _other -> {:error, code}
    end
  end

  defp positive_integer(_value, code), do: {:error, code}

  defp same_repository_id?(provider_id, durable_id) do
    case {positive_integer(provider_id, :invalid), positive_integer(durable_id, :invalid)} do
      {{:ok, left}, {:ok, right}} -> left == right
      _other -> false
    end
  end

  defp next_page?(headers) when is_map(headers) do
    case Map.get(headers, "link") do
      value when is_binary(value) ->
        value
        |> String.split(",")
        |> Enum.any?(&String.contains?(&1, ~s(rel="next")))

      _other ->
        false
    end
  end

  defp next_page?(_headers), do: false

  defp trusted_now(opts) do
    case opts[:now_fn].() do
      %DateTime{} = now -> {:ok, DateTime.truncate(now, :microsecond)}
      _other -> {:error, %Failure{kind: :invalid_trusted_time}}
    end
  rescue
    _exception -> {:error, %Failure{kind: :invalid_trusted_time}}
  catch
    _kind, _reason -> {:error, %Failure{kind: :invalid_trusted_time}}
  end

  defp correlation_id(opts) do
    case opts[:correlation_id_fn].() do
      value when is_binary(value) ->
        if Sxf.Identifiers.valid?(value),
          do: {:ok, value},
          else: {:error, %Failure{kind: :invalid_correlation_id}}

      _other ->
        {:error, %Failure{kind: :invalid_correlation_id}}
    end
  rescue
    _exception -> {:error, %Failure{kind: :invalid_correlation_id}}
  catch
    _kind, _reason -> {:error, %Failure{kind: :invalid_correlation_id}}
  end

  defp incomplete_registration?(repository, manifest) do
    Enum.any?(
      [
        repository.external_id,
        repository.owner,
        repository.name,
        repository.default_branch,
        repository.manifest_schema_version
      ],
      &(not valid_registration_string?(&1))
    ) or
      not is_map(repository.normalized_manifest) or
      not is_map(manifest) or
      not valid_registration_string?(manifest["schemaVersion"])
  end

  defp client_opts(opts), do: Keyword.take(opts, [:transport, :now_fn])
  defp positive_bound?(value), do: is_integer(value) and value > 0

  defp valid_registration_string?(value) do
    is_binary(value) and String.valid?(value) and String.trim(value) != ""
  end
end
