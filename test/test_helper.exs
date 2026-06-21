# :python_integration tests need a container runtime (podman/docker). Excluded by
# default; run with `mix test --only python_integration`.
ExUnit.start(exclude: [:python_integration])
