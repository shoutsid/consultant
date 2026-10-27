# Limitations

These are deliberate, not missing work.

- **It does not execute.** v1 has no command runner. A proposal that needs a command is a
  `needs: command` request, not an execution; the walker is the only thing that runs an effect.
- **It does not accept, apply or verify.** The service refuses an agent key at the accept,
  dismiss, promote, run, report, verification, flag and mining-queue routes. A person accepts in
  the site admin or the project's portal.
- **It cannot read a private repository.** There is no GitHub App token in the client. It
  answers `cannot` and asks the question that would make the task answerable.
- **It cannot write a whole-file `file` effect.** Whole-file content is the easiest secret and
  private-source leak; the validator refuses it.
- **It refuses test, CI, dependency, boot, database and credential paths.** Those are a person's
  act, even when a model is confident.
- **It refuses `skip` and `expect` rule kinds.** They change what the walk ignores or requires,
  not the application.
- **It has no local queue.** A service outage is retried with a backoff, not stored and replayed.
- **It is single-tenant.** One container has one agent key and one model chain. Separate
  accounts belong in separate containers.
- **The prompt is not stored in the service.** A record holds its hash and the token usage; the
  prompt itself stays in the client's scratch directory.
- **The model can be wrong.** The validator limits the shape of a proposal, not its judgement.
  A review is a second opinion, and the next run is the only verification.
- **A model provider outage is outside the client.** It is reported as a retryable task failure;
  the deployment's provider and quota are not the client's to fix.
