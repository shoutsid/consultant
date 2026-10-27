# Changelog

All notable behaviour changes are recorded here. The client follows semantic versioning for
its image and its command line.

## [Unreleased]

### Changed

- The project is **Agents**. The client is `agents-consultant`, the namespace is
  `Agents::Consultant`, the environment variables use the `AGENTS_` prefix, and the image tags use
  `agents-consultant`. The old names are not read or accepted. The prompt changes with the rename,
  so the proposer is `consultant-prompt-6` and the reviewer is `reviewer-prompt-2`.

### Added

- `present` mode: the lead of a delivered pull request, written from the run's fact sheet, the
  deterministic body and the project's accepted review guide. It returns a summary and typed
  review-focus anchors; the service checks them, and the walker applies the validated block only
  while the pull request still holds the body it wrote.
- The standalone client repository, extracted from the service's `lib/consultant` tree.
- The compose-wiring assertions moved to the service's cross-repository contract suite, so this
  repository's suite runs in a checkout that contains only itself.
- Standalone documentation, issue and pull-request templates, and a CI workflow that runs the
  suite and builds the image without the model binary.
