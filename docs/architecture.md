# Architecture

The consultant is a small loop around a model process. It has no database, no Rails, no Docker
socket and no admin token.

## The loop

```text
control  -> paused? sleep
claim    -> lease up to N tasks with one agent key
task     -> read the question, the evidence and the project files
prompt   -> write the prompt to scratch, run `opencode`
validate -> a typed proposal, or a `cannot`/`maybe` with needs
post     -> propose an answer/profile/annotation, or complete with a `needs_human`
complete -> record the model and token usage
```

A task is a row with a lease token and a deadline. A heartbeat extends it; a release returns it
without spending an attempt. A retryable failure (provider timeout, `5xx`) queues the task again
with a backoff. A permanent failure (a refused effect, a test path, malformed JSON) marks it
`needs_human` and leaves the question open.

The loop is bounded. `--once` is the probe and the CI check: one control read and one claim, so
a deployment with a broken key says so instead of retrying silently for ever.

## The components

| File | What it decides |
|---|---|
| `lib/agents_fyi/consultant/config.rb` | The deployment's knobs, read once; the required URL and key, the model chain, the task kinds, the home. |
| `lib/agents_fyi/consultant/client.rb` | The one HTTP client: control, claim, heartbeat, complete, fail, release, decisions, runs, profile proposals, reviews, usage. |
| `lib/agents_fyi/consultant/prompt.rb` | The prompt text and the untrusted-content markers around report bodies and repository files. |
| `lib/agents_fyi/consultant/validator.rb` | The boundary: what a model may propose and what it must refuse. |
| `lib/agents_fyi/consultant/repository.rb` | The shallow, read-only public mirror, and `git show` for one file. |
| `lib/agents_fyi/consultant/runner.rb` | Starts `opencode`, passes the prompt by file, parses the JSON and the token usage. |
| `lib/agents_fyi/consultant/loop.rb` | The lease lifecycle and the task dispatch. |
| `lib/agents_fyi/consultant/cli.rb` | `--once`, `--cycles`, `--tasks` and the exit status. |

## The trust boundaries

- **The service is authoritative.** The client proposes; it never accepts, applies, verifies or
  writes a rule. `Upgrade::AgentPolicy` decides whether an account may auto-accept, and a person
  accepts in the site admin or the project's portal.
- **The validator refuses before a request leaves the process.** A whole-file `file` effect, a
  test/CI/dependency/boot/database/credential path and a delete are refused even when the model
  asks for them. `skip` and `expect` rule kinds are refused because they change the walk rather
  than the application.
- **The model is not trusted with the corpus.** Report bodies and repository files are data.
  They travel inside untrusted-content markers, and a prompt that tells the model to follow an
  instruction inside one is an attack.
- **The container is the credential boundary.** The agent key is in the client's environment;
  the provider credential is in the mounted home. Neither is in an image layer, and the
  container has no route to the database, the admin token or the walker's volume.
- **A review is a second agent, not a second container.** `reviewer.md` is a different prompt
  and, optionally, a different model. The service refuses a review whose provenance names the
  proposer's agent.

## Records

Every task writes `records/<task_id>.json` in the mounted home: the prompt hash, output hash,
model, result, error and the provider's token buckets. The prompt text is not stored in the
service; the local record stores only the hash. A task the validator or the service refuses still
records its spend, because the model call already happened and the account's total must include
it.
