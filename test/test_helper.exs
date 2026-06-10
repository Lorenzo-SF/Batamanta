Code.require_file("test_httpc.exs", __DIR__)
Code.require_file("support/runner_mock.exs", __DIR__)
ExUnit.start()

# Skip integration tests by default (they require network)
ExUnit.configure(exclude: [:integration])
