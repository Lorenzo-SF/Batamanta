defmodule Batamanta.KeeperConfig do
  @moduledoc """
  Normaliza y valida el bloque `beam_alive:` del mix config.

  ## Shape normalizado

      %Batamanta.KeeperConfig{
        enabled: boolean(),
        var: String.t(),          # nombre del env var que el wrapper leerá
        default_ms: non_neg_integer()  # TTL por defecto si el env var no está
      }

  ## Defaults (sin config / config vacío)

      %Batamanta.KeeperConfig{
        enabled: false,
        var: "BATAMANTA_BEAM_ALIVE",
        default_ms: 0
      }

  ## Backward compat

  Si el bloque `beam_alive:` está ausente o `enabled: false`, el wrapper
  no mira el env var → comportamiento idéntico al actual.

  Si `enabled: true` pero el env var no está seteado o vale `"0"`, el
  wrapper cae al path legacy (arranca y destruye la BEAM en cada
  invocación).
  """

  @default_var "BATAMANTA_BEAM_ALIVE"
  @default_default_ms 0
  @max_default_ms 86_400_000  # 24h cap, configurable en el futuro

  @type t :: %__MODULE__{
          enabled: boolean(),
          var: String.t(),
          default_ms: non_neg_integer()
        }

  defstruct enabled: false, var: @default_var, default_ms: @default_default_ms

  @doc """
  Construye el struct desde el bloque `beam_alive:` del config.

  `nil` o lista vacía → defaults (feature off).
  Acepta keyword list con keys `:enabled`, `:var`, `:default_ms`.

  Raises `ArgumentError` si la config es inválida.

  ## Examples

      iex> Batamanta.KeeperConfig.from_config(nil)
      %Batamanta.KeeperConfig{enabled: false, var: "BATAMANTA_BEAM_ALIVE", default_ms: 0}

      iex> Batamanta.KeeperConfig.from_config(enabled: true, var: "FOO", default_ms: 5_000)
      %Batamanta.KeeperConfig{enabled: true, var: "FOO", default_ms: 5_000}

  """
  @spec from_config(keyword() | nil) :: t()
  def from_config(nil), do: %__MODULE__{} |> validate!()

  def from_config(opts) when is_list(opts) do
    %__MODULE__{
      enabled: Keyword.get(opts, :enabled, false),
      var: Keyword.get(opts, :var, @default_var) |> to_string(),
      default_ms: Keyword.get(opts, :default_ms, @default_default_ms)
    }
    |> validate!()
  end

  @spec enabled?(t()) :: boolean()
  def enabled?(%__MODULE__{enabled: e}), do: e

  @doc """
  Valida la configuración. Raises ArgumentError si algún campo es inválido.
  Idempotente. Devuelve el struct validado.
  """
  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = cfg) do
    validate_enabled(cfg.enabled)
    validate_var(cfg.var)
    validate_default_ms(cfg.default_ms)
    cfg
  end

  @doc """
  Lista de env vars que el wrapper Rust debe setear al compilar el binario.

  Aunque `enabled: false`, emitimos `BATAMANTA_BEAM_ALIVE_ENABLED=0` para
  que el wrapper pueda ramificar el código de forma compile-time-eficiente
  (sin tocar el env var si ya sabemos que está off).
  """
  @spec to_env_vars(t()) :: [{String.t(), String.t()}]
  def to_env_vars(%__MODULE__{enabled: false}) do
    [{"BATAMANTA_BEAM_ALIVE_ENABLED", "0"}]
  end

  def to_env_vars(%__MODULE__{} = cfg) do
    [
      {"BATAMANTA_BEAM_ALIVE_ENABLED", "1"},
      {"BATAMANTA_BEAM_ALIVE_VAR", cfg.var},
      {"BATAMANTA_BEAM_ALIVE_DEFAULT_MS", Integer.to_string(cfg.default_ms)}
    ]
  end

  # ---------------------------------------------------------------------------
  # Validators (private)
  # ---------------------------------------------------------------------------

  defp validate_enabled(v) when is_boolean(v), do: :ok
  defp validate_enabled(v) do
    raise ArgumentError,
          "batamanta.beam_alive.enabled must be a boolean, got: #{inspect(v)}"
  end

  defp validate_var(v) when is_binary(v) and byte_size(v) > 0, do: :ok
  defp validate_var(v) do
    raise ArgumentError,
          "batamanta.beam_alive.var must be a non-empty string, got: #{inspect(v)}"
  end

  defp validate_default_ms(v)
       when is_integer(v) and v >= 0 and v <= @max_default_ms, do: :ok

  defp validate_default_ms(v) do
    raise ArgumentError,
          "batamanta.beam_alive.default_ms must be 0..#{@max_default_ms} (24h), got: #{inspect(v)}"
  end

  @doc false
  def __max_default_ms__, do: @max_default_ms
end
