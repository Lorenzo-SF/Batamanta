# Daemon Mode Configuration for Smoke Test
# Use: MIX_ENV=prod mix batamanta --erts-target <target>

import Config

config :smoke_test,
  execution_mode: :daemon
