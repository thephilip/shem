defmodule Shem.SeedTools.GraphifyQuery do
  @moduledoc """
  Deterministic graph ops over graphify's graph.json (find / neighbors / path /
  god_nodes). Not the LLM-driven semantic query — the agent does token expansion,
  this does the graph math.
  """
  @external_resource __ENV__.file
  @source File.read!(__ENV__.file)

  def run(%{"op" => op} = args) do
    case load_graph() do
      {:ok, graph} -> dispatch(op, args, graph)
      :error -> %{"error" => "no graph; run /graphify ."}
    end
  end

  defp load_graph do
    dir = Application.get_env(:shem, :graphify_dir, "graphify-out")
    path = Path.join(dir, "graph.json")

    with {:ok, body} <- File.read(path),
         {:ok, json} <- Jason.decode(body) do
      {:ok, json}
    else
      _ -> :error
    end
  end

  defp dispatch("find", %{"q" => q}, %{"nodes" => nodes}) do
    ql = String.downcase(q)
    ids = for n <- nodes, String.contains?(String.downcase(n["label"] || ""), ql), do: n["id"]
    %{"ids" => ids}
  end

  defp dispatch("neighbors", %{"id" => id}, graph) do
    labels = label_map(graph)

    neighbors =
      for l <- links(graph), l["source"] == id or l["target"] == id do
        other = if l["source"] == id, do: l["target"], else: l["source"]
        %{"id" => other, "label" => labels[other], "relation" => l["relation"]}
      end

    %{"neighbors" => neighbors}
  end

  defp dispatch("path", %{"from" => from, "to" => to}, graph) do
    %{"path" => bfs(from, to, graph)}
  end

  defp dispatch("god_nodes", args, graph) do
    n = Map.get(args, "n", 5)
    labels = label_map(graph)

    god =
      links(graph)
      |> Enum.flat_map(fn l -> [l["source"], l["target"]] end)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_id, deg} -> -deg end)
      |> Enum.take(n)
      |> Enum.map(fn {id, deg} -> %{"id" => id, "label" => labels[id], "degree" => deg} end)

    %{"god_nodes" => god}
  end

  defp dispatch(op, _args, _graph), do: %{"error" => "unknown op: #{op}"}

  defp links(%{"links" => links}), do: links
  defp links(_), do: []

  defp label_map(%{"nodes" => nodes}), do: Map.new(nodes, fn n -> {n["id"], n["label"]} end)
  defp label_map(_), do: %{}

  defp bfs(from, to, graph) do
    adj = build_adj(graph)
    do_bfs([[from]], to, adj, MapSet.new([from]))
  end

  defp do_bfs([], _to, _adj, _seen), do: nil

  defp do_bfs([[node | _] = path | rest], to, adj, seen) do
    if node == to do
      Enum.reverse(path)
    else
      nbrs = Map.get(adj, node, []) |> Enum.reject(&MapSet.member?(seen, &1))
      new_paths = Enum.map(nbrs, fn nb -> [nb | path] end)
      new_seen = Enum.reduce(nbrs, seen, fn nb, acc -> MapSet.put(acc, nb) end)
      do_bfs(rest ++ new_paths, to, adj, new_seen)
    end
  end

  defp build_adj(graph) do
    Enum.reduce(links(graph), %{}, fn l, acc ->
      s = l["source"]
      t = l["target"]

      acc
      |> Map.update(s, [t], &[t | &1])
      |> Map.update(t, [s], &[s | &1])
    end)
  end

  def tool do
    %Shem.Tool{
      id: "graphify_query",
      name: "GraphifyQuery",
      runtime: {:beam, __MODULE__},
      source: @source,
      test_source: "",
      input_schema: %{"op" => %{"type" => "string"}},
      graduated_at: ~U[2026-06-22 00:00:00Z],
      metadata: %{"description" => "Query the graphify knowledge graph: find, neighbors, path, god_nodes."}
    }
  end
end
