# Development

The client is Ruby 3.3 or newer and deliberately stdlib-only. There is no Gemfile, no bundle and
no database.

## The suite

```bash
git clone git@github.com:shoutsid/consultant.git
cd consultant
ruby -Ilib -Itest test/all_test.rb
```

One file:

```bash
ruby -Ilib -Itest test/loop_test.rb
```

The suite installs nothing, reaches no network and starts no service. The model process and the
HTTP client are injected, so the loop's lease lifecycle, the validator and the prompt are tested
without a model call.

## The contract split

This repository proves what the client does with its own artifacts. The agreements that need
both repositories live in the service's `test/contracts/consultant/` suite:

- the service's compose wiring (opt-in profile, no database/admin/walker credential, only its own
  home, read-only, dropped capabilities);
- the vocabulary the validator shares with the service's enums.

Do not copy the service's compose file, its enums or its policy into this repository. If a
change needs both sides to test, add it to the service's contract suite.

## The image

```bash
# The production shape: the model binary is installed.
docker build -t agents-consultant .

# CI and offline: the client starts and refuses with a sentence rather than a missing binary.
docker build --build-arg WITH_AGENT=0 -t agents-consultant:ci .
```

The image runs as uid `10001`, copies the agent files from `/app/agent`, and writes them to the
mounted home on first boot.

## Style

The service's RuboCop run scans this tree when it is checked out as a submodule. In standalone
CI the checks are `ruby -c` over every Ruby file, `bash -n` over the shell scripts, the suite, and
an image build that answers `--help`.

- Two-space indentation, frozen string literals, no trailing whitespace.
- Comments explain **why**, not what the code already says.
- Errors say what the caller should do next, with the count or the limit named.
- Tests are named as sentences, and a test that documents a deliberate refusal says so.
