defmodule Sxf.Evidence.Error do
  @moduledoc "Structured evidence-store failure without artifact bytes or secret-bearing content."

  @enforce_keys [:code, :message]
  defstruct [:code, :message, details: %{}]

  @type t :: %__MODULE__{code: atom(), message: String.t(), details: map()}
end

defmodule Sxf.Evidence do
  @moduledoc """
  Immutable local content-addressed evidence bytes tied to durable evidence references.

  The caller supplies attribution and a byte or file source. SHA-256, byte size, storage identity,
  and finalization are derived by this boundary and cannot be supplied as authority.
  """

  import Ecto.Query

  alias Sxf.Evidence.Error
  alias Sxf.Repo

  alias Sxf.Tasks.{
    Actor,
    EvidenceReference,
    Task,
    TaskAttempt
  }

  @chunk_size 64 * 1024
  @hex_sha256 ~r/\A[0-9a-f]{64}\z/
  @required_attrs ~w(
    task_id producer_actor_id kind media_type finalized_at correlation_id idempotency_key redacted
  )a
  @optional_attrs ~w(id attempt_id metadata)a

  @type source :: binary() | {:bytes, binary()} | {:file, Path.t()}

  @spec put(map(), source()) :: {:ok, map()} | {:error, Error.t()}
  def put(attrs, source) when is_map(attrs) do
    safely(fn -> do_put(attrs, source) end)
  end

  def put(_attrs, _source), do: error(:invalid_attributes, "evidence attributes must be a map")

  defp do_put(attrs, source) do
    with {:ok, attrs} <- validate_attrs(attrs),
         :ok <- validate_ownership(attrs),
         {:ok, staged} <- stage(source) do
      try do
        persist(attrs, staged)
      after
        File.rm(staged.temporary_path)
      end
    end
  end

  @spec get(Ecto.UUID.t()) :: {:ok, map()} | {:error, Error.t()}
  def get(evidence_id) do
    safely(fn -> do_get(evidence_id) end)
  end

  defp do_get(evidence_id) do
    with {:ok, reference} <- fetch_reference(evidence_id),
         :ok <- validate_reference_identity(reference),
         {:ok, path} <- reference_path(reference),
         :ok <- regular_file(path),
         {:ok, bytes} <- read_bytes(path),
         actual = %{sha256: sha256(bytes), byte_size: byte_size(bytes)},
         :ok <- compare_reference(reference, actual) do
      verification = verification_result(reference, actual)
      {:ok, %{reference: reference, bytes: bytes, verification: verification}}
    end
  end

  @spec verify(Ecto.UUID.t()) :: {:ok, map()} | {:error, Error.t()}
  def verify(evidence_id) do
    safely(fn -> do_verify(evidence_id) end)
  end

  defp do_verify(evidence_id) do
    with {:ok, reference} <- fetch_reference(evidence_id) do
      verify_reference(reference)
    end
  end

  @doc false
  @spec verify_reference(EvidenceReference.t()) :: {:ok, map()} | {:error, Error.t()}
  def verify_reference(%EvidenceReference{} = reference) do
    with :ok <- validate_reference_identity(reference),
         {:ok, path} <- reference_path(reference),
         :ok <- regular_file(path),
         {:ok, actual} <- hash_file(path),
         :ok <- compare_reference(reference, actual) do
      {:ok, verification_result(reference, actual)}
    end
  end

  @spec audit() :: {:ok, map()} | {:error, Error.t()}
  def audit do
    safely(&do_audit/0)
  end

  defp do_audit do
    references = Repo.all(from evidence in EvidenceReference, order_by: evidence.id)

    results =
      Enum.map(references, fn reference ->
        case verify_reference(reference) do
          {:ok, result} -> result
          {:error, error} -> %{evidence_id: reference.id, status: error.code}
        end
      end)

    with {:ok, stored_paths} <- stored_blob_paths() do
      referenced_paths =
        references
        |> Enum.map(&reference_path/1)
        |> Enum.flat_map(fn
          {:ok, path} -> [Path.expand(path)]
          _ -> []
        end)
        |> MapSet.new()

      orphans =
        stored_paths
        |> Enum.map(&Path.expand/1)
        |> Enum.reject(&MapSet.member?(referenced_paths, &1))
        |> Enum.map(&Path.relative_to(&1, store_root()))
        |> Enum.sort()

      grouped = Enum.group_by(results, & &1.status)

      {:ok,
       %{
         references: length(references),
         verified: grouped |> Map.get(:verified, []) |> Enum.map(& &1.evidence_id),
         missing: grouped |> Map.get(:missing_blob, []) |> Enum.map(& &1.evidence_id),
         corrupt:
           grouped
           |> Map.take([:content_hash_mismatch, :byte_size_mismatch, :invalid_blob_type])
           |> Map.values()
           |> List.flatten()
           |> Enum.map(& &1.evidence_id)
           |> Enum.sort(),
         invalid:
           grouped
           |> Map.drop([
             :verified,
             :missing_blob,
             :content_hash_mismatch,
             :byte_size_mismatch,
             :invalid_blob_type
           ])
           |> Map.values()
           |> List.flatten()
           |> Enum.map(& &1.evidence_id)
           |> Enum.sort(),
         orphaned: orphans
       }}
    end
  end

  defp validate_attrs(attrs) do
    missing = Enum.reject(@required_attrs, &Map.has_key?(attrs, &1))
    unsupported = Map.keys(attrs) -- (@required_attrs ++ @optional_attrs)

    cond do
      missing != [] ->
        error(:missing_attributes, "required evidence attributes are missing", %{fields: missing})

      unsupported != [] ->
        error(:unsupported_attributes, "unsupported evidence attributes were supplied", %{
          fields: Enum.sort(unsupported)
        })

      not Sxf.Identifiers.valid?(attrs.task_id) ->
        error(:invalid_task_id, "task_id must be a canonical UUID")

      Map.get(attrs, :id) && not Sxf.Identifiers.valid?(attrs.id) ->
        error(:invalid_evidence_id, "id must be a canonical UUID")

      not Sxf.Identifiers.valid?(attrs.producer_actor_id) ->
        error(:invalid_actor_id, "producer_actor_id must be a canonical UUID")

      Map.get(attrs, :attempt_id) && not Sxf.Identifiers.valid?(attrs.attempt_id) ->
        error(:invalid_attempt_id, "attempt_id must be a canonical UUID")

      not Sxf.Identifiers.valid?(attrs.correlation_id) ->
        error(:invalid_correlation_id, "correlation_id must be a canonical UUID")

      not valid_string?(attrs.kind, 100) ->
        error(:invalid_kind, "kind must be a non-empty string of at most 100 bytes")

      not valid_string?(attrs.media_type, 255) ->
        error(:invalid_media_type, "media_type must be a non-empty string of at most 255 bytes")

      not valid_string?(attrs.idempotency_key, 255) ->
        error(
          :invalid_idempotency_key,
          "idempotency_key must be a non-empty string of at most 255 bytes"
        )

      not match?(%DateTime{time_zone: "Etc/UTC"}, attrs.finalized_at) ->
        error(:invalid_finalized_at, "finalized_at must be a UTC DateTime")

      attrs.redacted != true ->
        error(:unredacted_evidence, "evidence must be redacted before finalization")

      not valid_metadata?(Map.get(attrs, :metadata, %{})) ->
        error(:invalid_metadata, "metadata must be a JSON object of at most 64 KiB")

      true ->
        {:ok,
         %{
           id: Map.get(attrs, :id),
           task_id: attrs.task_id,
           attempt_id: Map.get(attrs, :attempt_id),
           producer_actor_id: attrs.producer_actor_id,
           kind: attrs.kind,
           media_type: attrs.media_type,
           finalized_at: attrs.finalized_at,
           correlation_id: attrs.correlation_id,
           idempotency_key: attrs.idempotency_key,
           redacted: true,
           metadata: Map.get(attrs, :metadata, %{})
         }}
    end
  end

  defp validate_ownership(attrs) do
    cond do
      is_nil(Repo.get(Task, attrs.task_id)) ->
        error(:task_not_found, "task does not exist")

      is_nil(Repo.get(Actor, attrs.producer_actor_id)) ->
        error(:actor_not_found, "producer actor does not exist")

      attrs.attempt_id ->
        case Repo.get(TaskAttempt, attrs.attempt_id) do
          %TaskAttempt{task_id: task_id} when task_id == attrs.task_id -> :ok
          %TaskAttempt{} -> error(:attempt_task_mismatch, "attempt belongs to another task")
          nil -> error(:attempt_not_found, "attempt does not exist")
        end

      true ->
        :ok
    end
  end

  defp stage(source) do
    temporary_directory = Path.join(store_root(), "tmp")

    with :ok <- mkdir(temporary_directory) do
      temporary_path =
        Path.join(temporary_directory, "put-#{Sxf.Identifiers.generate()}.partial")

      case write_source(source, temporary_path, max_bytes()) do
        {:ok, digest} ->
          {:ok, Map.put(digest, :temporary_path, temporary_path)}

        {:error, _} = result ->
          File.rm(temporary_path)
          result
      end
    end
  end

  defp write_source(source, path, maximum) when is_binary(source),
    do: write_source({:bytes, source}, path, maximum)

  defp write_source({:bytes, bytes}, path, maximum) when is_binary(bytes) do
    if byte_size(bytes) > maximum do
      error(:evidence_too_large, "evidence exceeds the configured byte limit", %{
        maximum: maximum
      })
    else
      case File.open(path, [:write, :binary, :exclusive], fn output ->
             with :ok <- IO.binwrite(output, bytes),
                  :ok <- :file.sync(output) do
               {:ok,
                %{
                  sha256: sha256(bytes),
                  byte_size: byte_size(bytes)
                }}
             end
           end) do
        {:ok, {:ok, %{sha256: _, byte_size: _}} = result} -> result
        {:ok, {:error, %Error{}} = result} -> result
        {:error, reason} -> filesystem_error(:write_failed, "evidence staging failed", reason)
      end
    end
  end

  defp write_source({:file, source_path}, destination_path, maximum)
       when is_binary(source_path) do
    with :ok <- regular_source_file(source_path),
         {:ok, input} <- open_file(source_path, [:read, :binary], :source_read_failed),
         {:ok, output} <-
           open_file(destination_path, [:write, :binary, :exclusive], :write_failed) do
      try do
        copy_and_hash(input, output, :crypto.hash_init(:sha256), 0, maximum)
      after
        File.close(input)
        File.close(output)
      end
    end
  end

  defp write_source(_source, _path, _maximum),
    do: error(:invalid_source, "source must be bytes or a regular file")

  defp copy_and_hash(input, output, hash_state, size, maximum) do
    case IO.binread(input, @chunk_size) do
      :eof ->
        with :ok <- :file.sync(output) do
          {:ok,
           %{
             sha256: hash_state |> :crypto.hash_final() |> Base.encode16(case: :lower),
             byte_size: size
           }}
        end

      {:error, reason} ->
        filesystem_error(:source_read_failed, "evidence source could not be read", reason)

      bytes ->
        new_size = size + byte_size(bytes)

        if new_size > maximum do
          error(:evidence_too_large, "evidence exceeds the configured byte limit", %{
            maximum: maximum
          })
        else
          case IO.binwrite(output, bytes) do
            :ok ->
              copy_and_hash(
                input,
                output,
                :crypto.hash_update(hash_state, bytes),
                new_size,
                maximum
              )

            {:error, reason} ->
              filesystem_error(:write_failed, "evidence staging failed", reason)
          end
        end
    end
  end

  defp persist(attrs, staged) do
    fingerprint =
      request_fingerprint(attrs, staged.sha256, staged.byte_size)

    transact_persist(attrs, staged, fingerprint, 1)
  end

  defp transact_persist(attrs, staged, fingerprint, lock_retries_remaining) do
    case Repo.transaction(fn ->
           validate_ownership_in_transaction!(attrs)

           case Repo.get_by(EvidenceReference,
                  task_id: attrs.task_id,
                  idempotency_key: attrs.idempotency_key
                ) do
             %EvidenceReference{request_fingerprint: ^fingerprint} = reference ->
               case verify_reference(reference) do
                 {:ok, _} -> %{reference: reference, idempotent?: true}
                 {:error, reason} -> Repo.rollback(reason)
               end

             %EvidenceReference{} ->
               Repo.rollback(:idempotency_conflict)

             nil ->
               with :ok <- ensure_blob(staged) do
                 reference =
                   %EvidenceReference{}
                   |> EvidenceReference.changeset(%{
                     id: attrs.id,
                     task_id: attrs.task_id,
                     attempt_id: attrs.attempt_id,
                     producer_actor_id: attrs.producer_actor_id,
                     kind: attrs.kind,
                     storage_uri: storage_uri(staged.sha256),
                     sha256: staged.sha256,
                     media_type: attrs.media_type,
                     byte_size: staged.byte_size,
                     finalized_at: attrs.finalized_at,
                     correlation_id: attrs.correlation_id,
                     idempotency_key: attrs.idempotency_key,
                     request_fingerprint: fingerprint,
                     redacted: attrs.redacted,
                     metadata: attrs.metadata
                   })
                   |> Repo.insert()
                   |> unwrap_or_rollback()

                 %{reference: reference, idempotent?: false}
               else
                 {:error, reason} -> Repo.rollback(reason)
               end
           end
         end) do
      {:ok, result} -> {:ok, result}
      {:error, :idempotency_conflict} -> error(:idempotency_conflict, "idempotency key conflict")
      {:error, %Error{} = reason} -> {:error, reason}
      {:error, reason} -> database_error(reason)
    end
  rescue
    exception in [DBConnection.ConnectionError, Exqlite.Error] ->
      if lock_retries_remaining > 0 and database_locked?(exception) do
        transact_persist(attrs, staged, fingerprint, lock_retries_remaining - 1)
      else
        database_error(Exception.message(exception))
      end
  end

  defp validate_ownership_in_transaction!(attrs) do
    case validate_ownership(attrs) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp ensure_blob(staged) do
    path = blob_path(staged.sha256)

    with :ok <- mkdir(Path.dirname(path)) do
      cond do
        File.exists?(path) ->
          verify_staged_against_existing(staged, path)

        true ->
          case File.rename(staged.temporary_path, path) do
            :ok ->
              :ok

            {:error, reason} when reason in [:eexist, :eacces] ->
              if File.exists?(path),
                do: verify_staged_against_existing(staged, path),
                else:
                  filesystem_error(
                    :publish_failed,
                    "evidence blob could not be published",
                    reason
                  )

            {:error, reason} ->
              filesystem_error(:publish_failed, "evidence blob could not be published", reason)
          end
      end
    end
  end

  defp verify_staged_against_existing(staged, path) do
    with :ok <- regular_file(path),
         {:ok, actual} <- hash_file(path) do
      if actual.sha256 == staged.sha256 and actual.byte_size == staged.byte_size do
        :ok
      else
        error(
          :content_address_collision,
          "existing content-addressed evidence does not match its address"
        )
      end
    end
  end

  defp fetch_reference(evidence_id) do
    if Sxf.Identifiers.valid?(evidence_id) do
      case Repo.get(EvidenceReference, evidence_id) do
        nil -> error(:evidence_not_found, "evidence reference does not exist")
        reference -> {:ok, reference}
      end
    else
      error(:invalid_evidence_id, "evidence_id must be a canonical UUID")
    end
  end

  defp validate_reference_identity(reference) do
    cond do
      not is_binary(reference.sha256) or not Regex.match?(@hex_sha256, reference.sha256) ->
        error(:invalid_reference, "evidence reference has an invalid SHA-256")

      reference.storage_uri != storage_uri(reference.sha256) ->
        error(:invalid_reference, "evidence storage URI does not match its SHA-256")

      not is_integer(reference.byte_size) or reference.byte_size < 0 ->
        error(:invalid_reference, "evidence reference has an invalid byte size")

      is_nil(reference.finalized_at) ->
        error(:evidence_not_finalized, "evidence reference is not finalized")

      reference.redacted != true ->
        error(:invalid_reference, "evidence reference is not marked redacted")

      not Sxf.Identifiers.valid?(reference.correlation_id) ->
        error(:invalid_reference, "evidence reference has an invalid correlation ID")

      not valid_string?(reference.idempotency_key, 255) ->
        error(:invalid_reference, "evidence reference has an invalid idempotency key")

      not is_binary(reference.request_fingerprint) or
          not Regex.match?(@hex_sha256, reference.request_fingerprint) ->
        error(:invalid_reference, "evidence reference has an invalid request fingerprint")

      true ->
        :ok
    end
  end

  defp reference_path(reference), do: {:ok, blob_path(reference.sha256)}

  defp read_bytes(path) do
    with {:ok, input} <- open_file(path, [:read, :binary], :read_failed) do
      try do
        read_all(input, [], 0)
      after
        File.close(input)
      end
    end
  end

  defp read_all(input, chunks, size) do
    case IO.binread(input, @chunk_size) do
      :eof ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:error, reason} ->
        filesystem_error(:read_failed, "verified evidence could not be read", reason)

      bytes ->
        new_size = size + byte_size(bytes)

        if new_size > max_bytes() do
          error(:blob_too_large, "evidence blob exceeds the limit")
        else
          read_all(input, [bytes | chunks], new_size)
        end
    end
  end

  defp verification_result(reference, actual) do
    %{
      evidence_id: reference.id,
      status: :verified,
      sha256: actual.sha256,
      byte_size: actual.byte_size,
      storage_uri: reference.storage_uri
    }
  end

  defp compare_reference(reference, actual) do
    cond do
      actual.sha256 != reference.sha256 ->
        error(:content_hash_mismatch, "evidence bytes do not match the durable SHA-256")

      actual.byte_size != reference.byte_size ->
        error(:byte_size_mismatch, "evidence bytes do not match the durable byte size")

      true ->
        :ok
    end
  end

  defp hash_file(path) do
    with {:ok, %File.Stat{size: size}} <- File.stat(path),
         true <- size <= max_bytes() || error(:blob_too_large, "evidence blob exceeds the limit"),
         {:ok, input} <- open_file(path, [:read, :binary], :read_failed) do
      try do
        hash_input(input, :crypto.hash_init(:sha256), 0)
      after
        File.close(input)
      end
    else
      {:error, %Error{}} = result ->
        result

      {:error, reason} ->
        filesystem_error(:read_failed, "evidence bytes could not be read", reason)
    end
  end

  defp hash_input(input, hash_state, size) do
    case IO.binread(input, @chunk_size) do
      :eof ->
        {:ok,
         %{
           sha256: hash_state |> :crypto.hash_final() |> Base.encode16(case: :lower),
           byte_size: size
         }}

      {:error, reason} ->
        filesystem_error(:read_failed, "evidence bytes could not be read", reason)

      bytes ->
        hash_input(
          input,
          :crypto.hash_update(hash_state, bytes),
          size + byte_size(bytes)
        )
    end
  end

  defp regular_source_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        :ok

      {:ok, _} ->
        error(:invalid_source, "file source must be a regular file")

      {:error, reason} ->
        filesystem_error(:source_read_failed, "file source is unavailable", reason)
    end
  end

  defp regular_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, _} -> error(:invalid_blob_type, "evidence blob is not a regular file")
      {:error, :enoent} -> error(:missing_blob, "evidence blob is missing")
      {:error, reason} -> filesystem_error(:read_failed, "evidence blob is unavailable", reason)
    end
  end

  defp stored_blob_paths do
    root = Path.join([store_root(), "blobs", "sha256"])

    case File.ls(root) do
      {:ok, prefixes} ->
        prefixes
        |> Enum.sort()
        |> Enum.reduce_while({:ok, []}, fn prefix, {:ok, paths} ->
          prefix_path = Path.join(root, prefix)

          case File.ls(prefix_path) do
            {:ok, names} ->
              regular_paths =
                names
                |> Enum.map(&Path.join(prefix_path, &1))
                |> Enum.filter(fn path ->
                  match?({:ok, %File.Stat{type: :regular}}, File.lstat(path))
                end)

              {:cont, {:ok, paths ++ regular_paths}}

            {:error, reason} ->
              {:halt, filesystem_error(:audit_failed, "evidence inventory failed", reason)}
          end
        end)

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        filesystem_error(:audit_failed, "evidence inventory failed", reason)
    end
  end

  defp open_file(path, modes, code) do
    case File.open(path, modes) do
      {:ok, io} -> {:ok, io}
      {:error, reason} -> filesystem_error(code, "evidence file could not be opened", reason)
    end
  end

  defp mkdir(path) do
    case File.mkdir_p(path) do
      :ok ->
        :ok

      {:error, reason} ->
        filesystem_error(:store_unavailable, "evidence store is unavailable", reason)
    end
  end

  defp blob_path(sha256) do
    Path.join([store_root(), "blobs", "sha256", binary_part(sha256, 0, 2), sha256])
  end

  defp storage_uri(sha256), do: "sha256://#{sha256}"

  defp store_root do
    :sxf_core
    |> Application.fetch_env!(:evidence_store)
    |> Keyword.fetch!(:root)
    |> Path.expand()
  end

  defp max_bytes do
    :sxf_core
    |> Application.fetch_env!(:evidence_store)
    |> Keyword.fetch!(:max_bytes)
  end

  defp request_fingerprint(attrs, sha256, byte_size) do
    %{
      command: :put_evidence,
      evidence_id: attrs.id,
      task_id: attrs.task_id,
      attempt_id: attrs.attempt_id,
      producer_actor_id: attrs.producer_actor_id,
      kind: attrs.kind,
      media_type: attrs.media_type,
      finalized_at: attrs.finalized_at,
      correlation_id: attrs.correlation_id,
      idempotency_key: attrs.idempotency_key,
      redacted: attrs.redacted,
      metadata: attrs.metadata,
      sha256: sha256,
      byte_size: byte_size
    }
    |> :erlang.term_to_binary([:deterministic])
    |> sha256()
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp valid_string?(value, maximum) do
    is_binary(value) and String.valid?(value) and byte_size(value) > 0 and
      byte_size(value) <= maximum and
      String.trim(value) != ""
  end

  defp valid_metadata?(metadata) when is_map(metadata) do
    case Jason.encode(metadata) do
      {:ok, encoded} -> byte_size(encoded) <= 64 * 1024
      {:error, _} -> false
    end
  end

  defp valid_metadata?(_metadata), do: false

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, changeset}), do: Repo.rollback(changeset)

  defp database_locked?(exception) do
    exception
    |> Exception.message()
    |> then(
      &(String.contains?(&1, "database is locked") or
          String.contains?(&1, "database table is locked"))
    )
  end

  defp database_error(_reason),
    do: error(:database_failure, "evidence reference could not be persisted")

  defp safely(fun) do
    fun.()
  rescue
    _error in [DBConnection.ConnectionError, Ecto.ConstraintError, Ecto.QueryError, Exqlite.Error] ->
      database_error(:database_exception)

    error in RuntimeError ->
      if String.starts_with?(error.message, "could not lookup Ecto repo") do
        database_error(:database_unavailable)
      else
        reraise(error, __STACKTRACE__)
      end
  catch
    :exit, _reason -> database_error(:database_exit)
  end

  defp filesystem_error(code, message, reason),
    do: error(code, message, %{reason: to_string(reason)})

  defp error(code, message, details \\ %{}),
    do: {:error, %Error{code: code, message: message, details: details}}
end
