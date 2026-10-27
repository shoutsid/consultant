# Contributing

This repository is **proprietary**. It is public so operators and reviewers can read the
client, not because it is open source. See [LICENSE](LICENSE).

## Before you write code

Open an issue first and describe the change. Contributions are accepted only by prior
arrangement with the copyright holder. Do not send a pull request that adds a feature, a
dependency or a large refactor without that conversation; it may be declined for reasons that
have nothing to do with the quality of the code.

Opening an issue or a pull request does not grant a licence to use the repository, and does not
transfer ownership of your contribution. Any contribution that is accepted is subject to a
separate written agreement with the copyright holder.

## What is welcome

- A reproducible bug report with the command, the version, the operating system and a redacted
  log or record description.
- A correction to documentation that is wrong about the current behaviour.
- A test that demonstrates a real failure, with the smallest reproduction you can find.
- A focused fix, discussed first.

## Development

You need Ruby 3.3 or newer. There is no Gemfile and no `bundle install`.

```bash
git clone git@github.com:shoutsid/consultant.git
cd consultant
ruby -Ilib -Itest test/all_test.rb
```

A single file:

```bash
ruby -Ilib -Itest test/loop_test.rb
```

The suite needs no network, no Docker daemon and no service. If a change needs one of those to
test, it likely belongs in the service's cross-repository contract suite, not here. See
[Development](docs/development.md) for the split.

The image can be built without the model binary:

```bash
docker build --build-arg WITH_AGENT=0 -t agents-consultant .
```

## Design rules

- **No new runtime dependencies.** The client is deliberately stdlib-only: the container that
  holds a model credential must not also carry a database driver, a Rails application or a
  convenience gem.
- **The service is the authority.** The client proposes; it never accepts, applies or verifies.
  `Upgrade::AgentPolicy`, the task lease and the review rules live in the service.
- **The validator is the boundary.** A whole-file `file` effect, a test/CI/dependency/credential
  write and a command that needs execution are refused before a request leaves the process.
- **A record is evidence, not a transcript.** The prompt text is not stored in the service, and
  the local record holds hashes and token counts rather than secrets.
- **Cross-repository agreements live in the service's contract suite.** Do not add a local copy
  of the service's compose file, its enums or its policy.
- **Do not skip a test to make the suite green.** If an agreement needs both repositories, move
  it to the service's contract suite; if it can be stated here, state it here.

## Style

- Two-space indentation, frozen string literals, no trailing whitespace.
- Comments explain **why**, not what the code already says.
- Errors say what the caller should do next, in one sentence, with the count or the limit named.
- Tests are named as sentences, and a test that documents a deliberate refusal says so.

## Pull requests

- One concern per change.
- Add or update a test that would fail without the change.
- Update the docs when a mode, a flag, a default, a refusal or a state file changes.
- Do not add a secret, a token or a private repository's source to a fixture.
- Describe how you tested it, including the Ruby version and whether a model or a service was
  involved.

## Security

Do not open a public issue for a vulnerability. See [SECURITY.md](SECURITY.md).

## Conduct

By participating, you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).
