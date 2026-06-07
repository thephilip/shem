import Config

# --headless CLI flag or SHEM_NO_TUI=1 disables the TUI
if System.get_env("SHEM_NO_TUI") == "1" or "--headless" in System.argv() do
  config :shem, start_tui: false
end

# SHEM_DATA_DIR overrides DETS file locations — only when explicitly set,
# so test config's trust_store_path is never clobbered.
case System.get_env("SHEM_DATA_DIR") do
  nil ->
    :ok

  data_dir ->
    config :shem,
      trust_store_path: Path.join(data_dir, "trust.dets"),
      preset_store_path: Path.join(data_dir, "preset_store.dets")
end

# Cluster topology — "dns" for Docker/K8s, default "gossip" for bare metal
topology =
  case System.get_env("LIBCLUSTER_STRATEGY", "gossip") do
    "dns" ->
      query = System.get_env("LIBCLUSTER_DNS_QUERY", "shem")

      [
        shem: [
          strategy: Cluster.Strategy.DNSPoll,
          config: [query: query, node_basename: "shem", polling_interval: 5_000]
        ]
      ]

    _ ->
      [
        shem: [
          strategy: Cluster.Strategy.Gossip,
          config: [port: 45892, multicast_addr: "230.1.1.251"]
        ]
      ]
  end

config :libcluster, topologies: topology
