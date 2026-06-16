# Lineage API / DTO spec

What a real backend would have to serve so the SAS Lineage demo could drop its
in-browser, file-backed data source and talk to a server instead. The demo
already defines the contract in code — this doc is the human-readable version.

- **Wire DTO**: `LineageResponse` and friends in `src/types.ts` (section
  *"Normalized lineage DTO (the Python API contract, §9)"*).
- **Operations seam**: the `LineageSource` interface in
  `src/data/lineageSource.ts`. The file-backed `createFileLineageSource` is the
  stand-in backend; `createApiLineageSource` (sketched at the bottom of that
  file) is the HTTP swap. Callers `await` the same `Promise<LineageResponse>`
  either way, so wiring an API is a one-line factory swap.

## Design principles

- **Normalized id-graph.** Everything references everything else by **id**, not
  by string-key matching. A shared `tables` registry unifies the two grains:
  step lineage (`table@version`) and column lineage (`table.column`).
- **Ids are opaque.** The demo uses human-readable ids (`table@version`,
  `file:lines`, `output<-input`) because it has no DB. A real API MUST hand back
  **stable, server-assigned** ids; consumers must never parse them.
- **Server precomputes everything render-relevant.** Step `type`/`label` are
  computed server-side (it owns the SAS repo). The client never scans SAS or
  classifies code. With an API, raw SAS / JSONL inputs stop being uploaded at
  all — the server owns them.
- **Mutations are server operations.** The client sends intent; the server
  mutates its own copy of the graph and returns the **whole updated graph** plus
  the id of the edge it touched (so the UI can re-select it).

## Endpoints

| Method | Path | Body | Returns |
| ------ | ---- | ---- | ------- |
| `GET`  | `/lineage` | — | `LineageResponse` |
| `POST` | `/lineage/steps` | `AddStepReq` + `head` | `LineageMutation` |
| `POST` | `/lineage/steps/swap` | `SwapStepReq` + `head` | `LineageMutation` |
| `POST` | `/lineage/steps/break` | `BreakStepReq` + `head` | `LineageMutation` |

`head` is the git sha the client currently holds — pass it for optimistic
concurrency; the server owns the authoritative graph and may reject a stale head.

## Core DTO: `LineageResponse`

```jsonc
{
  "schemaVersion": 1,
  "head": "a3e084e",                // git sha the lineage was computed from
  "tables": [ /* LineageTable[] */ ],
  "step":   { /* StepLineageGraph */ },
  "column": { /* ColumnLineageGraph */ }
}
```

### `LineageTable` — shared table registry

```jsonc
{
  "id": "mart.orders_enriched",     // opaque (here: the table name)
  "name": "mart.orders_enriched",
  "lib": "MART",                    // library (the "lib." prefix, uppercased)
  "transient": false                // true for work/scratch tables (work.*)
}
```

### `StepLineageGraph` — table→table transitions (table@version grain)

```jsonc
{
  "nodes": [
    { "id": "work.customers@v1", "tableId": "work.customers", "version": "v1" }
  ],
  "steps": [
    { "id": "customers_load.sas:15-27", "number": 1,
      "type": "PROC", "label": "PROC SQL",
      "source": { "file": "customers_load.sas", "startLine": 15, "endLine": 27 } }
  ],
  "edges": [
    { "id": "e1-raw.cust_master@v1-work.customers@v1",
      "from": "raw.cust_master@v1",   // LineageNode id
      "to": "work.customers@v1",       // LineageNode id
      "stepId": "customers_load.sas:15-27",
      "stale": false }                 // optional
  ]
}
```

- `LineageNode` is a table **at a point in time** (a version). `tableId`
  references the `tables` registry.
- `LineageStep` is a code block that produces tables. `type` is one of
  `PROC | DATA | MACRO | Other`; `label` is the human form (e.g. `"PROC SQL"`).
  Code provenance lives here, on the step — not on the edge.
- `LineageStepEdge` links two nodes and points at the step (`stepId`) that
  produced the transition. Multiple edges may share one step.

### `ColumnLineageGraph` — field→field mappings (table.column grain)

```jsonc
{
  "edges": [
    { "id": "mart.sales_monthly.net_revenue<-mart.orders_enriched.net_amount",
      "to":   { "tableId": "mart.sales_monthly",   "version": "v1", "column": "net_revenue" },
      "from": { "tableId": "mart.orders_enriched", "version": "v1", "column": "net_amount" },
      "transformations": [
        { "type": "DIRECT", "subtype": "AGGREGATION",
          "description": "sum(net_amount) as net_revenue" }
      ],
      "flag": "uncertain"             // optional: "uncertain" | "phantom"
    }
  ]
}
```

- `to`/`from` are `ColumnFieldRef` (`tableId` + `version` + `column`).
- `transformations` describe how the input shapes the output:
  - `type: "DIRECT"` — affects the **value**. Subtypes: `IDENTITY`,
    `TRANSFORMATION`, `AGGREGATION`.
  - `type: "INDIRECT"` — affects **which rows feed in**. Subtypes: `FILTER`,
    `GROUP_BY`, `JOIN`, `WINDOW`, `SORT`, `CONDITIONAL`.
- `flag` is a confidence marker (demo-only lever; a real API would emit it from
  its own confidence scoring or omit it).

## Mutation requests / responses

All three return `LineageMutation`:

```jsonc
{
  "lineage": { /* full updated LineageResponse */ },
  "edgeId": "e5-..."   // edge created/changed (so UI re-selects it); absent for break
}
```

A `CodeRange` is `{ "sasFile", "startLine", "endLine" }` (1-based, inclusive).

| Operation | Request | Server behaviour |
| --------- | ------- | ---------------- |
| **Add step** | `{ from, to, code }` — node ids + `CodeRange` | Resolve/mint the step for that code window (classify its `type`/`label`), add an edge `from→to` pointing at it. |
| **Swap step** | `{ edgeId, from, code }` | Replace `edgeId` with a new edge from a new input node into the **same** target, backed by `code`. Prune any now-orphaned step. |
| **Break step** | `{ edgeId }` | Remove `edgeId`; prune any step no edge references. |

Server-side invariants the demo relies on: step `number`s stay gap-free /
non-drifting, steps with no referencing edge are pruned, and re-classification of
a curated `CodeRange` is authoritative (the client never re-sniffs type).

## Notes for an implementer

- The demo's `buildLineageResponse` derives the `tables` registry from the names
  the graphs reference. A real API can store tables first-class instead.
- The file-backed source ingests two **JSON Lines** files (one step edge / one
  column edge per line, nodes+steps embedded inline and de-duped on parse). That
  format is a transport detail of the stand-in backend — an HTTP API just serves
  the assembled `LineageResponse` JSON and the JSONL files disappear.
- Errors: the source contract throws on rejection so dialogs can surface it; an
  HTTP impl should map non-2xx to a thrown error (`createApiLineageSource` does
  `throw new Error(\`lineage \${res.status}\`)`).
- Out of scope for this contract: connection/folder selection, the analysis
  `issues` list, table definitions, and the LLM column-extraction step are demo
  inputs/fixtures, not part of the lineage graph API.
</content>
</invoke>
