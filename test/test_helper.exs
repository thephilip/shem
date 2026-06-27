# :python_integration and :container_integration tests need a container runtime
# (podman/docker). Excluded by default; run with `mix test --only <tag>`.
ExUnit.start(exclude: [:python_integration, :container_integration])
