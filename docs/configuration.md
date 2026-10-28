# Configuration

The client reads its configuration from the environment once, at start-up. There is no config
file.

## Required

| Variable | Meaning |
|---|---|
| `AGENTS_URL` | The service base URL. On a compose network this is the service name, not the public hostname. |
| `AGENTS_KEY` | An agent key. It is not an admin token and cannot accept, dismiss, promote, run, file or verify. |
| `CONSULTANT_MODEL` | The deployment's fallback model chain, comma- or space-separated and read left to right. A project's policy may name a narrower one. Put the free model first and the paid one after it. |

## The loop

| Variable | Default | Meaning |
|---|---|---|
| `CONSULTANT_INTERVAL` | `300` | Seconds between polls when no task is claimable. |
| `CONSULTANT_CLAIM_LIMIT` | `1` | Tasks per claim, clamped to 1–5. |
| `CONSULTANT_KINDS` | `answer,review,profile,scan,intent,repair,present` | Task kinds this container accepts. |
| `CONSULTANT_TASK_TIMEOUT` | `600` | Seconds one model run may take, clamped to 60–3600. |
| `CONSULTANT_OPENCODE` | `opencode` | The model binary. |
| `CONSULTANT_AGENT` | `consultant` | The OpenCode agent for a proposal. |
| `CONSULTANT_REVIEW_AGENT` | `reviewer` | The agent for a review task. |
| `CONSULTANT_PRESENT_AGENT` | `presenter` | The agent for a pull-request presentation. |
| `CONSULTANT_REVIEW_MODEL` | empty | Optional different chain for a review; empty uses the proposal's chain. |
| `CONSULTANT_HOME` | the process home | State, records, scratch and the public mirrors live below it. |

## Model fallback

`CONSULTANT_MODEL` (and a project's `model` policy, when it names one) is a chain, read left to
right. Put a free model first and the paid model after it:

```text
CONSULTANT_MODEL=opencode/deepseek-v4.1-flash-free,opencode/glm-5.3-flash-free,opencode-go/deepseek-v4.1-flash
```

A retryable model-process error — a usage limit, a rate limit, an unavailable free model, a
provider outage or a timeout — moves to the next model in the chain. A non-retryable error stops at
once, and a validator refusal never spends the paid fallback because the model did answer. The task
lease is heartbeated before each fallback, and the task, record and spend name the model that
actually answered.

## Command line

```text
agents-consultant [--once|--cycles N] [--tasks N]
```

- `--once` — one poll, then exit. This is the probe and the CI check.
- `--cycles N` — poll N times.
- `--tasks N` — stop after N tasks.

Exit status:

| Status | Meaning |
|---|---|
| `0` | The requested cycles/tasks completed. |
| `1` | An unexpected failure (a bug, a filesystem error). |
| `2` | A configuration or service error the caller must fix. |

## Home layout

```text
$CONSULTANT_HOME/
  state/      control state and heartbeats
  records/    one JSON record per task
  scratch/    prompts and model invocations
  repos/      shallow, read-only public mirrors
```

The image sets `CONSULTANT_HOME=/home/consultant` and mounts that as a volume. The entrypoint
writes the two agent files into `~/.config/opencode/agents/` on first boot, without overwriting
an operator's own copy.
