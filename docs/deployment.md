# Deployment

The consultant is a compose profile in the service repository, and it can also run as a
standalone container with the same environment.

## The service side

Register the agent key once, in the service container:

```bash
docker compose run --rm --no-deps service \
  bin/rails 'agent:register_operator[consultant,consultant@example.test]'
```

Put the key in the deployment's environment as `CONSULTANT_KEY`; the compose file maps it to
`AGENTS_KEY` inside the consultant container. Grant it `model_access` with `bin/rails
'model_access:grant[consultant@example.test]'`; without the grant the key cannot fetch a provider
secret and a task fails rather than running on an unknown credential. The account the key belongs to
must be unpaused, and a project's policy must be on and consenting before the walk asks it anything.

## The model side

Provider keys belong to the account and live in the service's encrypted vault (`/admin/model-access`).
After claiming a task, the consultant fetches only the providers its effective chain names, writes a
per-task `opencode.json` referencing environment variables, and removes the directory when the task
ends. A deployment-wide imported credential is the fallback for accounts with no key of their own.
No `opencode auth login` state is required, and the run's empty XDG directories mean a stale one in
`consultant_home` is not used.

The image installs `opencode` unless it is built with `--build-arg WITH_AGENT=0`. A build
without it is still a valid client: it refuses a task with a sentence rather than running a
missing binary.

## The container

The deployment's posture is part of the contract:

- no `DATABASE_URL`, `DB_PASSWORD`, `ADMIN_TOKEN`, GitHub App key or walker volume;
- no Docker socket;
- only `consultant_home` mounted;
- `read_only: true`, `cap_drop: [ALL]`, `no-new-privileges`, a memory limit and a pid limit;
- the service URL on the private compose network, not the public hostname.

A consultant that inherited one of those credentials would be a second service with a model in
it; the service's `test/contracts/consultant/deploy_config_test.rb` asserts the wiring.

## Upgrading

The state, records and mirrors live in the volume, not the image. Replacing the image keeps
them. A new prompt version is part of the client's provenance; a task answered by an old prompt
still names the old version in its record.

## Rollback

Pin the previous image tag and restart the container. Do not delete `consultant_home`: it holds
the records that explain what the model spent and what it proposed.
