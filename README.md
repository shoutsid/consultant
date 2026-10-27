# Agents consultant

A client of the service that reads a decision an upgrade walk could not make and proposes what to do
about it. It is **not** a second walker: the deterministic walk is the only thing that applies an
effect, the service is the only thing that stores a decision, and a person is the only one who
accepts a proposal unless an account has explicitly enabled a known-shape auto policy.

## What it is allowed to do

| Act | Consultant | Why |
|---|---|---|
| read a task and its question | yes | the service hands it the question, evidence and options |
| propose an answer or a `maybe`/`cannot` stance | yes | typed effects and provenance, through `Decision::Answers` |
| propose a project-profile field | yes | the account's review queue; `checks` and `env_names` are a person's |
| write the lead of a delivered pull request | yes | a summary and typed review-focus anchors over the record; the service validates them, and it is not an effect |
| record a run | no | a run is the walker's evidence, and the agent key is refused |
| accept, dismiss or withdraw someone else's answer | no | the service refuses an agent key |
| execute a command, run the suite, clone with a write token | no | v1 has no execution; a `needs: command` is a request |
| write a test, CI, dependency, boot, database or credential path | no | the validator and the service both refuse it |
| clone a public repository into its own volume | yes | shallow, read-only, `git show` for files; no worktree |
| read a private repository | no | v1 has no GitHub App token; it answers `cannot` + a question |
| write a whole-file `file` effect | no | whole-file content is the easiest secret/private-code leak |

The container has no `DATABASE_URL`, no database password, no `ADMIN_TOKEN`, no Docker socket and no
mount of the walker's cache or worktree. Its one credential is the agent key; the model provider's
credential lives in the mounted home (`consultant_home`), not in an image layer. The same volume
holds the shallow public mirrors (`repos/`), which are a cache and never evidence.

## Run it

From the service checkout:

```sh
# one key, once, in the service container
docker compose run --rm --no-deps service bin/rails 'agent:register_operator[consultant,consultant@example.test]'

# put the key in .env as CONSULTANT_KEY, then
docker compose --profile consultant up -d consultant
docker compose exec consultant opencode auth login    # the model provider, once
```

`./scripts/dev.sh consultant` runs the suite from the service checkout. This repository's own
suite needs no service, no database, no bundle and no network:

```sh
ruby -Ilib -Itest test/all_test.rb
```

The image can be built without the model binary:

```sh
docker build --build-arg WITH_AGENT=0 -t agents-consultant .
```

## The loop

```
control -> paused? sleep
claim   -> lease up to N tasks with one agent key
task    -> question detail -> prompt -> opencode run -> validate -> post -> complete
```

A lease is a row with a token and a deadline. A heartbeat extends it; a release returns the task
without spending an attempt; a retryable failure (`provider timeout`, `5xx`) queues it again with a
backoff; a permanent failure (a refused effect, a test path, malformed JSON) marks it `needs_human`
and the question stays open. One failed auto-accepted run freezes auto for that question.

Every task writes `records/<task_id>.json`: the prompt hash, output hash, model, result, error and
the provider's token buckets. The prompt text itself is not stored in the service, and the local
record stores only the hash.

**The model's token usage is read from its own session, not estimated.** `opencode run --format json`
gives the session id and the answer; `opencode session export <id>` gives the provider's input,
output, reasoning and cache buckets, and the loop sends them on `complete` and on `fail`. A task the
validator or the service refuses still records its spend: the model call already happened, and the
account's total must include it.

## Modes

| Mode | Answer |
|---|---|
| `answer` | a stance, typed effects and needs for the question, with the project's public files as evidence |
| `profile` | field proposals with a source for each one; the account's review queue |
| `scan` | an advisory annotation (missed / false-positive / not-present) over the public files and the deterministic hit; not an edit |
| `intent` | typed effects compiled from a person's prose, only after the person confirms |
| `repair` | a `patch`/`config` proposal under a human goal; v1 cannot execute, so it says `cannot` when it needs a command |
| `review` | a `safe`/`unsafe`/`needs` verdict on another task's proposal, with concerns and evidence; a different agent and prompt, never the proposer |
| `present` | the lead of a delivered pull request: a summary and typed review-focus anchors over the run record and the project's review guide; not an effect and not a branch change |

The service's `Upgrade::AgentPolicy` is authoritative: a project may narrow its account's policy but
not widen it, the default is `off`, and consent precedes the first task.

`review` is a second agent, not a second container. `CONSULTANT_REVIEW_AGENT` names the reviewer
(the image writes `reviewer.md` beside `consultant.md`), `CONSULTANT_REVIEW_MODEL` optionally names
another model, and the service refuses a review whose provenance names the proposer's agent. The
review prompt is `reviewer-prompt-2`; the proposer is `consultant-prompt-6`. The reviewer reads the
proposal's effects, the failed run's patch and the profile, and a `safe` verdict still only lets the
account's policy accept provisionally — the next run is the verification.

`present` is a third agent, `presenter.md`, with the same no-tools posture. The service validates
every path, commit, decision, check and corpus report the model names against the fact sheet before
the walker may apply the lead; the deterministic body remains when the draft is refused.

## Documentation

- [Documentation index](docs/README.md) — every page below, with a one-line purpose.
- [Architecture](docs/architecture.md) — the loop, its components and the trust boundaries.
- [Configuration](docs/configuration.md) — environment variables, task kinds and exit statuses.
- [Development](docs/development.md) — the suite, the contract split and the image.
- [Deployment](docs/deployment.md) — the container, the agent key and the model credential.
- [Service API](docs/service-api.md) — the endpoints the client calls.
- [Limitations](docs/limitations.md) — what v1 deliberately cannot do.
- [Troubleshooting](docs/troubleshooting.md) — the failures operators actually hit.
- [Changelog](CHANGELOG.md).

## Development

```bash
ruby -Ilib -Itest test/all_test.rb
```

The suite needs no network, no database and no bundle. The client's agreements with the service —
the compose wiring and the vocabulary shared with the service's enums — live in the service's
own contract suite, because only a checkout that holds both sides can test them. See
[Development](docs/development.md).

## Contributing

This is a proprietary repository. Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening an
issue or a pull request; contributions are accepted only by prior arrangement. Security reports
go through [SECURITY.md](SECURITY.md), not a public issue.

## License

Copyright (c) 2026 James Summerill. All rights reserved. No use, copying, modification,
publication, distribution, sublicensing or sale is permitted without prior written permission
from the copyright holder. See [LICENSE](LICENSE).
