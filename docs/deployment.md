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
`AGENTS_FYI_KEY` inside the consultant container. The account the key belongs to must be
unpaused, and a project's policy must be on and consenting before the walk asks it anything.

## The model side

The provider credential is not in the image. It lives in the mounted `consultant_home`, so an
operator signs in once:

```bash
docker compose exec consultant opencode auth login
```

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
