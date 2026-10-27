# Consultant documentation

The consultant is the client that reads a decision an upgrade walk could not make and proposes
what to do about it. It is a caller of the **agents-fyi** service, with its own repository,
runtime and image.

Start with the [README](../README.md). These pages go deeper:

- [Architecture](architecture.md) — the loop, the components and the trust boundaries.
- [Configuration](configuration.md) — environment variables, task kinds and exit statuses.
- [Development](development.md) — the suite, the contract split and the image.
- [Deployment](deployment.md) — the container, the agent key and the model credential.
- [Service API](service-api.md) — the endpoints the client calls and how it reads their answers.
- [Limitations](limitations.md) — what v1 deliberately cannot do.
- [Troubleshooting](troubleshooting.md) — the failures an operator actually hits.

The service's own documentation is the authority for policy, decisions and the corpus. This
repository documents only what the client does with them.
