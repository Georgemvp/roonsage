import { useCallback, useEffect, useState } from "react";
import {
  ReactFlow,
  Background,
  Controls,
  addEdge,
  type Edge,
  type Node,
  type Connection,
  type OnNodesChange,
  type OnEdgesChange,
  applyNodeChanges,
  applyEdgeChanges,
} from "@xyflow/react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";

import "@xyflow/react/dist/style.css";

import { api } from "@/lib/api-client";
import { Card, CardHeader } from "@/components/ui/Card";
import { Button } from "@/components/ui/Button";
import { ShimmerStack } from "@/components/ui/Shimmer";
import { ErrorState } from "@/components/EmptyState";
import { showToast } from "@/lib/bridge";

/*
 * Visual automation builder, modelled after SoulSync's trigger → action → then
 * pattern. Persists to /api/automations/graph (POST) as a JSON document of
 * {nodes, edges, meta}; backend converts that into the legacy trigger/action
 * shape so the existing engine keeps running unchanged.
 *
 * Signal-chaining: an "emit_signal" action node can fan into another graph's
 * "on_signal" trigger node. Backend cycle-detection (signal_chain_depth) caps
 * depth at 5.
 */

type GraphDoc = {
  id: string | null;
  name: string;
  enabled: boolean;
  nodes: Node[];
  edges: Edge[];
};

const PALETTE = {
  trigger: [
    { label: "Op tijdstip", kind: "trigger.schedule" },
    { label: "Bij signaal", kind: "trigger.signal" },
    { label: "Bij worker-event", kind: "trigger.worker_event" },
  ],
  action: [
    { label: "Genereer playlist", kind: "action.generate_playlist" },
    { label: "Speel persona", kind: "action.play_persona" },
    { label: "Stuur notificatie", kind: "action.notify" },
    { label: "Verstuur signaal", kind: "action.emit_signal" },
  ],
} as const;

export function AutomationBuilder() {
  const qc = useQueryClient();
  const { data: graph, isLoading, error } = useQuery<GraphDoc>({
    queryKey: ["automation-graph"],
    queryFn: () => api<GraphDoc>("/automations/graph"),
  });

  const [nodes, setNodes] = useState<Node[]>([]);
  const [edges, setEdges] = useState<Edge[]>([]);
  const [name, setName] = useState("Nieuwe automation");

  // Sync local state when the persisted graph loads.
  useEffect(() => {
    if (graph) {
      setNodes(graph.nodes);
      setEdges(graph.edges);
      setName(graph.name);
    }
  }, [graph]);

  const onNodesChange: OnNodesChange = useCallback(
    (changes) => setNodes((nds) => applyNodeChanges(changes, nds)),
    [],
  );
  const onEdgesChange: OnEdgesChange = useCallback(
    (changes) => setEdges((eds) => applyEdgeChanges(changes, eds)),
    [],
  );
  const onConnect = useCallback(
    (conn: Connection) => setEdges((eds) => addEdge({ ...conn, animated: true }, eds)),
    [],
  );

  const addNode = (kind: string, label: string) => {
    const id = `${kind}-${Date.now()}`;
    setNodes((n) => [
      ...n,
      {
        id,
        type: "default",
        data: { label, kind },
        position: { x: 200 + n.length * 40, y: 100 + n.length * 40 },
      },
    ]);
  };

  const saveMut = useMutation({
    mutationFn: () =>
      api<GraphDoc>("/automations/graph", {
        method: "POST",
        json: { id: graph?.id ?? null, name, enabled: true, nodes, edges },
      }),
    onSuccess: () => {
      showToast("Automation opgeslagen", "success");
      qc.invalidateQueries({ queryKey: ["automation-graph"] });
    },
    onError: (err) => showToast((err as Error).message, "error"),
  });

  if (isLoading) return <ShimmerStack rows={8} />;
  if (error) return <ErrorState description={(error as Error).message} />;

  return (
    <div className="grid grid-cols-1 gap-4 md:grid-cols-[260px_1fr]">
      <Card>
        <CardHeader eyebrow="Naam" title="Automation" />
        <input
          type="text"
          value={name}
          onChange={(e) => setName(e.target.value)}
          className="w-full rounded-md border border-[color:var(--color-border)] bg-white/5 px-2 py-1 text-sm"
        />
        <CardHeader eyebrow="Triggers" title="" />
        <div className="flex flex-col gap-1.5">
          {PALETTE.trigger.map((t) => (
            <Button key={t.kind} variant="ghost" onClick={() => addNode(t.kind, t.label)}>
              + {t.label}
            </Button>
          ))}
        </div>
        <CardHeader eyebrow="Acties" title="" />
        <div className="flex flex-col gap-1.5">
          {PALETTE.action.map((a) => (
            <Button key={a.kind} variant="ghost" onClick={() => addNode(a.kind, a.label)}>
              + {a.label}
            </Button>
          ))}
        </div>
        <Button onClick={() => saveMut.mutate()} disabled={saveMut.isPending}>
          Opslaan
        </Button>
      </Card>

      <Card span={3} className="min-h-[520px] p-0">
        <div style={{ height: "100%", minHeight: 520, borderRadius: 16, overflow: "hidden" }}>
          <ReactFlow
            nodes={nodes}
            edges={edges}
            onNodesChange={onNodesChange}
            onEdgesChange={onEdgesChange}
            onConnect={onConnect}
            fitView
          >
            <Background />
            <Controls />
          </ReactFlow>
        </div>
      </Card>
    </div>
  );
}
