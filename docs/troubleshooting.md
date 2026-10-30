# Troubleshooting

## `AGENTS_URL is required` / `AGENTS_KEY is required`

The client refused at start-up. Set both in the container's environment. On a compose network
the URL is the service name (`http://service:8001`), not the public hostname.

## `401` or `403` on the first control read

The key is missing, disabled or not an agent key. Register the operator in the service and put
the *agent* key in `AGENTS_KEY`. An admin token is not an agent key.

## `the opencode binary is required`

The image was built with `WITH_AGENT=0`, or `CONSULTANT_OPENCODE` names a binary that is not on
`PATH`. A build without the agent is valid for CI and for a deployment that only wants to prove
the key and the loop.

## The model is not authenticated

The provider key belongs to the account. An account administrator connects it at
`/admin/model-access`; the agent key also needs the `model_access` grant
(`bin/rails 'model_access:grant[email]'`). A 409 from `model_access` names the provider with no
usable key; a 403 means the grant is missing. The client fails the task rather than running on an
unknown credential.

## The service says the project is paused

`GET /api/upgrades/agent/control` says so. The account, the project or the consultant profile
may be paused. The client sleeps; it does not retry through a pause.

## The task keeps failing and then becomes `needs_human`

Read the task's record in `records/`. A permanent failure is one the validator or the service
refused (a refused effect, a missing field, malformed JSON). A retryable failure is a timeout or
a `5xx`; the service queues it again with a backoff.

## A review was refused

The service refuses a review whose provenance names the proposer's agent. `CONSULTANT_REVIEW_AGENT`
must differ from `CONSULTANT_AGENT`; the review model may also differ.

## `Argument list too long`

The prompt is written to `scratch/` and passed by file. If a custom wrapper passes it on the
command line, that is the wrapper's bug; the bundled runner does not.

## The container cannot reach the service

The service URL on the compose network is `http://service:8001`; the public hostname goes
through the tunnel and is not what the client uses. Check `AGENTS_URL`, not the browser URL.

## A record is missing

The record is written after the model run. A crash before the run finishes leaves no record; a
crash after it leaves one. Check the container's logs and the volume's permissions.
