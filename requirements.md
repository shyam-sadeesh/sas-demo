# SAS Lineage Analysis Tool — Demo Requirements

A web tool that reads SAS code from a git branch, produces step-level and column-level lineage, and writes the curated lineage back to the same branch in one commit at the end. This document specifies the demo: a self-contained HTML/React build with no real backend, driven by a control pane that lets a presenter steer every branch of the flow.

---

## 1. User flow

The flow is linear with one explicit decision point. Each stage is a distinct screen. There is **a single commit at the very end** that writes both files.

### 1.1 Connect to repository
User supplies a git remote URL and branch name. Credentials are picked up from the ambient environment (SSH key on disk, or an env-provided PAT). No auth-method dropdown — keep the form to URL + branch. The tool reports connection success and the resolved branch HEAD.

### 1.2 Specify source folders
Within the connected branch, the user nominates three folders:
- **SAS code** — `.sas` files to analyse
- **Table definitions** — CSVs listing every known table, column, and column type
- **Connection details** — Oracle `.ora` file(s) describing database connections referenced by the SAS code

### 1.3 Initial completeness check
The tool scans the SAS code and reports both volume and gaps. The screen has three regions:

- **Scan summary tiles** — files scanned, lines of code, macros referenced, steps identified. Always shown.
- **Gap summary tiles** — one per gap category, coloured green at zero and warn-orange when non-zero. Categories: missing `%include` targets, missing macros, unbound `libname` references (Oracle libnames whose `path=` doesn't appear in any `.ora` file), and tables referenced in code but missing from the table-definition CSV.
- **Issues table** — every actual issue across categories with: severity, category, the missing item, and the source location (file + line). The tiles are the at-a-glance; the table is the detail.

This is the only decision point in the flow.

### 1.4 Decision: proceed or stop
- **Stop** → the tool returns to the connection screen. No state retained beyond what's in the branch; user fixes the repo and reconnects.
- **Proceed** → continue to lineage generation.

### 1.5 Step lineage view *(was "table lineage")*
The tool builds a directed graph of **step lineage** — table lineage that allows for in-place updates to the same table. SAS frequently iterates on a WORK table across multiple steps. Each in-place update produces a new version of the table; in the graph each `(table, version)` is its own node, so there are no cycles.

The view is split:

- **Left rail** (collapsible) — node count, search box, the list of `(table, version)` nodes, "Show" toggles (upstream / downstream / work nodes), and a **step-type colour key** (PROC / DATA step / MACRO / Other).
- **Centre** — graph canvas. Nodes are `(table, version)` pairs displayed with a sub-label showing library + `@version`. Work nodes (typically `WORK.*`) render with a dashed border and tinted fill so they're visually distinct from persisted tables. Edges are SAS steps that produced the downstream version from the upstream one(s); they are coloured by step type using the rail's key and labelled with the step number.
- **Right pane** (collapsible) — the SAS file that produced the selected target, with the relevant block of code highlighted. Header shows file path, step number, step type, and `target @version`.

Both side panes can be collapsed via a `«` / `»` affordance in their headers.

All edge operations are entered via **right-click on the edge** to open a context menu with: *View code*, *Edit step*, *Add new step…*, *Break step (remove edge)*. No toolbar buttons for these actions.

- **Break step** — remove the lineage edge. The two nodes stay; only the relationship goes. If column lineage already references this edge, those entries are marked stale. **No intermediate table is inserted.**
- **Add new step…** — opens a dialog with *From* dropdown, *To* dropdown (both list every `(table, version)` node), and an *Identified code step* dropdown listing every SAS code block the analyser detected as producing a table. A code-preview pane shows the SAS for the currently selected block. The user never types file paths or line numbers.
- **Edit step** — change which identified code block backs an existing edge, using the same dropdown + preview.

If the analyser missed a code block the user expects, the fix is to update the SAS in the repo and reconnect.

### 1.6 Specify columns for column lineage
The user picks one or more columns (across one or more tables) to trace at column level. Multi-select tree: table → columns.

### 1.7 LLM-assisted column lineage
The tool calls an LLM with: the selected columns, the step lineage already produced, and the SAS code for each step in scope. The LLM returns column-level lineage in **OpenLineage column-lineage** format. The user sees a progress indicator while this runs.

### 1.8 Column lineage view
Same split layout as 1.5 — both panes collapsible — but:

- Nodes are columns (qualified `table.column`), grouped visually by their parent table
- Edges carry **two pieces of metadata**: `type` (`DIRECT` or `INDIRECT`) and `subtype`. **Direct** contributors shape the output value — `IDENTITY`, `TRANSFORMATION`, `AGGREGATION`. **Indirect** contributors shape which rows feed in — `FILTER`, `GROUP_BY`, `JOIN`, `WINDOW`, `SORT`, `CONDITIONAL`. Both are recorded in the OpenLineage payload.
- Direct edges render solid; indirect edges render dashed. A toggle in the left rail lets the user show or hide indirect contributors.
- Clicking an edge opens the code pane (read-only highlighted SAS) and a **structured logic form** that maps to the OpenLineage inputField:
  - Output field (read-only)
  - Input field: `namespace`, `dataset name`, `field`
  - Transformations list (one or more per edge, Add / remove). Each transformation: `type` (direct/indirect segmented control), `subtype` (dropdown scoped to type), `description`, `masking` checkbox.
- **Steps cannot be added or removed** at column level; only an edge's input-field metadata and its transformations can be edited. Structural changes belong in 1.5.

### 1.9 Commit lineage to branch *(single save at the end)*
One screen, one commit. Two files are written together:

- `lineage/step-lineage.csv` — step lineage in the schema below
- `lineage/column-lineage.json` — OpenLineage column-lineage facet

The screen shows two summary cards side by side, one per file. The step lineage card shows: lineage rows, distinct steps, table versions, SAS files referenced, and a step-type mix (PROC × n / DATA × n / …). The column lineage card shows: columns traced, input mappings, direct count, indirect count, and a subtype mix. A single commit-message field, a single *Commit & push* action.

There is **no row-by-row diff** view. The graph in 1.5 and 1.8 is the detail; this screen is summary only.

---

## 2. Data model

### 2.1 Step lineage CSV schema
`lineage/step-lineage.csv`:

| Column | Description |
|---|---|
| `source_table` | Qualified source table name (e.g. `work.customers`) |
| `source_table_version` | Source version (e.g. `v1`, `v2`). New persisted tables typically start at `v1`. |
| `target_table` | Qualified target table name |
| `target_table_version` | Target version. In-place updates produce `v2`, `v3`, … on the same `target_table`. |
| `step_number` | Sequential step index (1-based). Multiple rows with the same `step_number` indicate a multi-source step (a join). |
| `sas_file` | File the step lives in (path relative to the SAS folder) |
| `starting_line` | First line of the code block |
| `ending_line` | Last line of the code block |

Because every iteration produces a new `target_table_version`, the graph is a DAG even when the same table name is updated repeatedly.

### 2.2 Column lineage JSON
Standard OpenLineage `ColumnLineageDatasetFacet` (v1.2.0), keyed by output dataset → field → `inputFields[]`. Each `inputField` carries one or more `transformations`, each with `type` (DIRECT/INDIRECT), `subtype`, `description`, `masking`. See `sample-inputs/column-lineage.json`.

---

## 3. Demo control pane

The first screen is a **Demo Control Pane** that lets a presenter steer the flow. It is not part of the real product.

### 3.1 Inputs (file uploads, not text fields)
Rather than asking the presenter to type a repo URL, the demo control pane accepts the real files:

| Input | Form | Notes |
|---|---|---|
| SAS files | Multi-file drop zone | Each file listed with size + line count after upload |
| Table definitions | Single CSV | Replaceable |
| ORA file | Single `.ora` | Replaceable |
| Pre-computed step lineage | Single CSV (optional) | If supplied, the demo can skip computation and jump straight to the explorer |
| Pre-computed column lineage | Single JSON (optional) | Same idea for column lineage |

Repo URL and branch are **not** here — they're collected on the connect screen during the demo flow.

### 3.2 Behaviour controls
- **Gap profile** — `none` / `minor` / `major`. Drives what the initial-analysis screen reports.
- **Default focus** — which `(table, version)` is selected on entry to the step lineage explorer.
- **LLM result quality** — `clean` / `partial` / `noisy`. Drives how confident the column-lineage view looks.
- **Save outcome** — `success` / `conflict`. Drives the commit screen's messaging.
- **Skip to stage** — jump directly to any stage with sensible defaults pre-applied.

A small `DEMO` badge in the top-right of every screen re-opens this pane at any time.

---

## 4. Real-product inputs and outputs

### 4.1 Inputs collected during the flow
- Git remote URL (HTTPS or SSH)
- Branch name
- SAS folder path, table-definitions folder path, ORA folder path (all relative to repo root)

### 4.2 Files expected inside the repo
- `.sas` files in the SAS folder
- `.csv` files in the table-definitions folder, with header `table_name,column_name,column_type`
- `.ora` files describing named connections

### 4.3 Files written back to the repo (single commit)
- `lineage/step-lineage.csv`
- `lineage/column-lineage.json`

---

## 5. JavaScript packages

Assuming React is already in place. Versions are indicative.

### 5.1 Core
- **`@xyflow/react`** (React Flow v12+) — both lineage graphs.
- **`dagre`** or **`elkjs`** — automatic graph layout. `elkjs` gives better hierarchical lineage results but is heavier; `dagre` is fine for the demo.
- **`zustand`** — global state for the multi-step flow.

### 5.2 Code display
- **`@monaco-editor/react`** — line-range highlighting, read-only mode.
- *Lighter alternative:* **`react-syntax-highlighter`** with the `sas` language.

### 5.3 Data
- **`papaparse`** — read the table-definitions CSV and emit `step-lineage.csv`.
- **`zod`** — schema-validate the demo-config, the step-lineage CSV rows, and the OpenLineage payload.

### 5.4 Forms & UI
- **`react-hook-form`** — connection and folder forms.
- **`@radix-ui/react-*`** or **`shadcn/ui`** — dialogs, dropdowns, context menus, toasts.
- **`lucide-react`** — icons.
- **`tailwindcss`** — utility CSS.

### 5.5 Search
- **`fuse.js`** — fuzzy search over the node list in 1.5 and the column tree in 1.6.

### 5.6 File uploads (demo only)
- **`react-dropzone`** — the drop zones in the demo control pane.

### 5.7 Git (real product only)
- **`isomorphic-git`** in-browser or **`simple-git`** on a Node backend. Mocked in the demo.

### 5.8 LLM (real product only)
- **`@anthropic-ai/sdk`** or equivalent. Prompt assembles selected columns + relevant step-lineage slice + SAS for in-scope steps. Output constrained to the OpenLineage column-lineage JSON schema via structured output.

---

## 6. State shape

Single zustand store:

```
demoConfig              // from the control pane (uploads + behaviour)
connection              // url, branch, head, status
folders                 // sasPath, tableDefsPath, oraPath
scanCounts              // filesScanned, linesOfCode, macrosReferenced, stepsIdentified
gaps                    // missingIncludes, missingMacros, missingLibs, missingTables
stage                   // 'connect' | 'folders' | 'analysis' | 'stepLineage' | 'pickColumns' | 'columnLineage' | 'commit'
stepLineage             // nodes (keyed by table+version), edges (rows of the CSV schema)
selectedNode            // (table, version)
selectedStepEdge
identifiedCodeSteps     // list available to the Add-step dialog
columnSelection         // [{ table, column }]
columnLineage           // OpenLineage payload
selectedColumnEdge
collapsed               // { railL: bool, codeR: bool }   pane state for §1.5 and §1.8
```

---

## 7. Out of scope for the demo

- Real git operations
- Real SAS parsing
- Real LLM calls
- Auth flows beyond ambient credentials
- Multi-user collaboration / locking
- Lineage history / versioning of saved files (the commit overwrites)
