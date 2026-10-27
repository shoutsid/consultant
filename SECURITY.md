# Security policy

## Supported versions

The latest image tag and the latest commit on `main` are supported. This client is early; a
security fix lands on the latest release and is not backported unless the maintainer says
otherwise in the advisory.

## Reporting a vulnerability

**Do not open a public issue.** Use GitHub's private vulnerability reporting for this repository
if it is enabled (Security → Advisories → Report a vulnerability). If it is not, contact
**@shoutsid** through the private contact methods on their GitHub profile and say that the report
is a security matter.

Please include:

- the image tag or commit;
- the operating system and Ruby version;
- the command, task kind and relevant flags;
- what an attacker can do, and what they need to start with;
- a minimal reproduction, with keys, private repository names and private source redacted.

You will get an acknowledgement as soon as the maintainer sees the report. There is no bug bounty
and no guaranteed response time; this is a small proprietary project.

## Scope

This client **holds a model credential and an agent key** and sends model-authored proposals to
a service. The boundary is the container and the validator, not the model provider.

In scope:

- **The agent key.** A path that reads, logs or transmits `AGENTS_KEY`, or that lets a
  model-authored effect reach the service's admin surface, is a vulnerability.
- **The model credential.** The provider credential lives in the mounted home, not in an image
  layer. A path that writes it into a record, a log, a proposal or an image is in scope.
- **The validator.** A proposal that names a test, CI, dependency, boot, database, credential or
  deletion path, or a whole-file `file` effect, must be refused before it is posted. A bypass is
  in scope.
- **Path handling.** A repository name, a task field or a model response must not make the
  client read or write outside its scratch, records or repository mirror directories.
- **The container posture.** The image runs as uid `10001`; a deployment should use a read-only
  root, dropped capabilities and only the declared volumes. A path that writes outside those
  volumes or gains privileges is in scope.
- **Prompt injection.** Report bodies and repository files are untrusted. A path that follows
  instructions found inside one, rather than treating them as data, is in scope.

Out of scope:

- the model provider's own service, model behaviour or credential handling;
- the service's policy, corpus or admin surface (report those to the service repository);
- a public repository whose content the client mirrors;
- a deployment that runs the container with extra privileges, a Docker socket or a database
  route;
- denial of service from a slow model or a large public repository, unless it defeats a declared
  timeout.

## Safe harbour

Do not test against a deployment you do not own, and do not use a real agent key or provider
credential in a report. A proof of concept against a local service, a disposable public repository
and a fake model is enough.
