# Plug.Test's default conn host is www.example.com — allow it through
# HostGuard so router tests don't all need a host override.
Application.put_env(:shem, :allowed_hosts, ["www.example.com"])

# :python_integration and :container_integration tests need a container runtime
# (podman/docker). Excluded by default; run with `mix test --only <tag>`.
ExUnit.start(exclude: [:python_integration, :container_integration, :deno, :deno_container, :go_container])
