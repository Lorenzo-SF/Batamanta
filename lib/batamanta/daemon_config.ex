defmodule Batamanta.DaemonConfig do
  @moduledoc """
  Configures the BEAM daemon mode.

  When `daemon: [enabled: true, ...]` is set in the consumer project's
  `batamanta:` mix config, the resulting binary will carry a small Erlang
  daemon application plus its Unix-domain-socket client embedded in the
  Rust wrapper.

  ## Shape

      %Batamanta.DaemonConfig{
        enabled: boolean(),
        var: String.t(),          # env var name the wrapper reads at runtime
        default_ms: non_neg_integer(),  # TTL if env var unset (0 = feature off)
        user_app: String.t(),     # OTP application name to load per request
        request_timeout_ms: pos_integer()
      }

  ## Defaults

      %Batamanta.DaemonConfig{
        enabled: false,
        var: "BATAMANTA_BEAM_ALIVE",
        default_ms: 0,
        user_app: nil,                  # derived from Mix project at build time
        request_timeout_ms: 60_000
      }

  ## Backward compatibility

  If `enabled: false` the wrapper never even reads the env var. If
  `enabled: true` but the env var is unset / empty / "0", the wrapper
  falls back to the legacy single-shot path (exec `<app>.run`).

  See `rfcs/0008-beam-alive-mode.md` for the full design rationale.
  """

  @default_var "BATAMANTA_BEAM_ALIVE"
  @default_default_ms 0
  @default_request_timeout_ms 60_000
  @max_default_ms 86_400_000  # 24h cap

  @type t :: %__MODULE__{
          enabled: boolean(),
          var: String.t(),
          default_ms: non_neg_integer(),
          user_app: String.t() | nil,
          request_timeout_ms: pos_integer()
        }

  defstruct enabled: false,
            var: @default_var,
            default_ms: @default_default_ms,
            user_app: nil,
            request_timeout_ms: @default_request_timeout_ms

  @doc """
  Builds a struct from the `daemon:` block of the mix config.

  `nil` or empty list → defaults (feature off).

  Raises `ArgumentError` on invalid input.
  """
  @spec from_config(keyword() | nil) :: t()
  def from_config(nil), do: %__MODULE__{} |> validate!()

  def from_config(opts) when is_list(opts) do
    %__MODULE__{
      enabled: Keyword.get(opts, :enabled, false),
      var: Keyword.get(opts, :var, @default_var) |> to_string(),
      default_ms: Keyword.get(opts, :default_ms, @default_default_ms),
      user_app:
        case Keyword.get(opts, :user_app) do
          nil -> nil
          atom when is_atom(atom) -> Atom.to_string(atom)
          bin when is_binary(bin) -> bin
        end,
      request_timeout_ms:
        Keyword.get(opts, :request_timeout_ms, @default_request_timeout_ms)
    }
    |> validate!()
  end

  @doc """
  Resolves the user_app at build time by inspecting Mix.Project.config().
  Falls back to the application's `:app` key when `:user_app` is nil.
  """
  @spec with_resolved_user_app(t()) :: t()
  def with_resolved_user_app(%__MODULE__{user_app: app} = cfg) when is_binary(app), do: cfg

  def with_resolved_user_app(%__MODULE__{} = cfg) do
    project_app =
      try do
        Mix.Project.config()[:app] |> to_string()
      rescue
        _ -> nil
      end

    %__MODULE__{cfg | user_app: project_app} |> validate!()
  end

  @doc """
  Returns true when the feature is active at build time.
  """
  @spec enabled?(t()) :: boolean()
  def enabled?(%__MODULE__{enabled: e}), do: e

  @doc """
  Validates the configuration in place. Raises ArgumentError on bad input.
  Idempotent.
  """
  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = cfg) do
    validate_enabled(cfg.enabled)
    validate_var(cfg.var)
    validate_default_ms(cfg.default_ms)
    validate_request_timeout(cfg.request_timeout_ms)
    validate_user_app(cfg.user_app)
    cfg
  end

  @doc """
  Env vars that the Rust wrapper picks up at build time via `build.rs`.

  When `enabled: false`, only `BATAMANTA_BEAM_ALIVE_ENABLED=0` is emitted so
  the wrapper can short-circuit without touching the env at runtime.
  """
  @spec to_env_vars(t()) :: [{String.t(), String.t()}]
  def to_env_vars(%__MODULE__{enabled: false}) do
    [{"BATAMANTA_BEAM_ALIVE_ENABLED", "0"}]
  end

  def to_env_vars(%__MODULE__{} = cfg) do
    [
      {"BATAMANTA_BEAM_ALIVE_ENABLED", "1"},
      {"BATAMANTA_BEAM_ALIVE_VAR", cfg.var},
      {"BATAMANTA_BEAM_ALIVE_DEFAULT_MS", Integer.to_string(cfg.default_ms)},
      {"BATAMANTA_DAEMON_USER_APP", cfg.user_app || ""},
      {"BATAMANTA_DAEMON_REQUEST_TIMEOUT_MS", Integer.to_string(cfg.request_timeout_ms)},
      {"BATAMANTA_DAEMON_CLI_MODULE", cli_module_default(cfg)}
    ]
  end

  # If the user didn't override `cli_module`, default to `<UserApp>.CLI`,
  # mirroring the convention used by `Batamanta.RunScript`.
  defp cli_module_default(%__MODULE__{user_app: nil}), do: ""
  defp cli_module_default(%__MODULE__{user_app: app}) do
    app |> Macro.camelize() |> Kernel.<>(".CLI")
  end

  # ---------------------------------------------------------------------------
  # Private validators
  # ---------------------------------------------------------------------------

  defp validate_enabled(v) when is_boolean(v), do: :ok

  defp validate_enabled(v) do
    raise ArgumentError,
          "batamanta.daemon.enabled must be a boolean, got: #{inspect(v)}"
  end

  defp validate_var(v) when is_binary(v) and byte_size(v) > 0, do: :ok

  defp validate_var(v) do
    raise ArgumentError,
          "batamanta.daemon.var must be a non-empty string, got: #{inspect(v)}"
  end

  defp validate_default_ms(v)
       when is_integer(v) and v >= 0 and v <= @max_default_ms, do: :ok

  defp validate_default_ms(v) do
    raise ArgumentError,
          "batamanta.daemon.default_ms must be 0..#{@max_default_ms} (24h), got: #{inspect(v)}"
  end

  defp validate_request_timeout(v) when is_integer(v) and v > 0 and v <= @max_default_ms, do: :ok

  defp validate_request_timeout(v) do
    raise ArgumentError,
          "batamanta.daemon.request_timeout_ms must be 1..#{@max_default_ms}, got: #{inspect(v)}"
  end

  defp validate_user_app(nil), do: :ok
  defp validate_user_app(v) when is_binary(v) and byte_size(v) > 0, do: :ok

  defp validate_user_app(v) do
    raise ArgumentError,
          "batamanta.daemon.user_app must be a non-empty atom/string or nil, got: #{inspect(v)}"
  end

  @doc false
  def __max_default_ms__, do: @max_default_ms
end
