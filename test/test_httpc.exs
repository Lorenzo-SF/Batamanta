defmodule Batamanta.TestHttpc do
  @moduledoc """
  Simple `:httpc` mock for tests without external dependencies.
  """

  def request(:get, {url, _headers}, _http_opts, _opts) do
    url_str = to_string(url)

    cond do
      String.ends_with?(url_str, "OTP-28.0.tar.gz") ->
        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], "fake_tarball_content_28.0"}}

      String.ends_with?(url_str, "OTP-28.1.tar.gz") ->
        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], "fake_tarball_content_28.1"}}

      String.ends_with?(url_str, "OTP-error.tar.gz") ->
        {:ok, {{~c"HTTP/1.1", 404, ~c"Not Found"}, [], ""}}

      String.ends_with?(url_str, "OTP-timeout.tar.gz") ->
        {:error, :timeout}

      true ->
        {:error, :unknown_url}
    end
  end
end
