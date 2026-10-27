# Support

This is a small, proprietary project. There is no support contract, no service-level agreement
and no guaranteed response time. The documentation is the first line of support, and the issue
tracker is the second.

## Before opening an issue

1. Read the [README](README.md) and the [configuration guide](docs/configuration.md).
2. Read [Troubleshooting](docs/troubleshooting.md); it covers refusals, leases, records and the
   container posture.
3. Search the existing issues.
4. Re-run the command with `--once` and read the control line. A paused service, a missing key
   and an unreadable task are different sentences.

## What to include

- the image tag or commit;
- the operating system and Ruby version;
- the mode, the command and the flags;
- the service URL, **never the agent key**;
- the exit code and the relevant log lines, with secrets and private repository names redacted;
- for a loop, the task id and whether its lease was renewed or released.

## What is not supported

- a deployment's own compose file, proxy, volume layout or secret store;
- a modified image or a fork;
- a model provider outage, quota or policy;
- a service whose policy, corpus or task queue refuses the work;
- a request for a licence, a redistribution right or a support contract.

Licensing questions go to the copyright holder; see [LICENSE](LICENSE). Security reports go
through [SECURITY.md](SECURITY.md), not the issue tracker.
