# Service API

The client uses one base URL (`AGENTS_FYI_URL`) and one credential (`AGENTS_FYI_KEY`, sent as
`X-API-Key`). Every path below is the service's agent surface; the service's discovery document
is the authority for the current shape.

## The loop

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/upgrades/agent/control` | Whether the account/project is paused, and the budget state. |
| `POST` | `/api/upgrades/agent/tasks/claim` | Lease up to `limit` tasks of the configured kinds. |
| `POST` | `/api/upgrades/agent/tasks/:id/heartbeat` | Extend the lease. |
| `POST` | `/api/upgrades/agent/tasks/:id/complete` | Post the validated result and the token usage. |
| `POST` | `/api/upgrades/agent/tasks/:id/fail` | Report a retryable or permanent failure. |
| `POST` | `/api/upgrades/agent/tasks/:id/release` | Return the task without spending an attempt. |
| `GET` | `/api/upgrades/agent/usage` | The account's spend. |

## The proposal

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/upgrades/decisions/:id` | The question, evidence and options. |
| `GET` | `/api/upgrades/runs/:id` | The failed run a repair task is about. |
| `GET` | `/api/upgrades/projects/:id/resolution` | The answer or rule in force for a project's move. |
| `POST` | `/api/upgrades/decisions/:id/answers` | Propose an answer with a stance, typed effects and provenance. |
| `POST` | `/api/upgrades/projects/:id/profile_proposals` | Propose a profile field with its source. |
| `POST` | `/api/upgrades/decisions/:id/answers/:answer_id/review` | A reviewer's `safe`/`unsafe`/`needs` verdict. |

## Reading the answers

- `401`/`403` — the key is missing, disabled or refused for that act. Do not retry.
- `404` — the task, decision or project is gone; the task is settled, not retried.
- `409` — the lease is stale or another holder has the task. Release or re-read.
- `422` — the body is wrong (a refused effect, a missing field). The validator should have
  caught it; record it as a permanent failure.
- `429` — the service's pace. Wait for the interval in the response and retry.
- `5xx`/timeout — the service is unavailable. Retryable, with a backoff.

A task's `complete` body carries the proposal and the provider's input/output/reasoning/cache
token buckets. A `fail` body carries the same usage; a model call that happened is still spend.

## Task kinds

`answer`, `review`, `profile`, `scan`, `intent`, `repair`. The container's `CONSULTANT_KINDS`
decides which ones it accepts; a task of another kind is not claimed.
