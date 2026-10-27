## Summary

<!-- One or two sentences: what does this change do, and why? -->

## Related issue

<!-- Link the issue this closes, or explain why there is none. -->

## What changed

<!--
  - the mode, prompt, validator rule, record field or deployment knob that moved;
  - the files or components touched;
  - anything a reviewer should look at first.
-->

## How I tested it

<!--
  - the command(s) you ran;
  - the Ruby version, and whether a model or a service was involved;
  - the new or updated test that would fail without this change.
-->

```bash
ruby -Ilib -Itest test/all_test.rb
```

## Checklist

- [ ] I read [CONTRIBUTING.md](https://github.com/shoutsid/consultant/blob/main/CONTRIBUTING.md), and I understand this repository is proprietary and a pull request does not grant a licence.
- [ ] The change is one concern.
- [ ] A test would fail without this change.
- [ ] The suite passes locally: `ruby -Ilib -Itest test/all_test.rb`.
- [ ] No new runtime dependency was added without prior discussion.
- [ ] The docs are updated if a mode, flag, default, refusal or record field changed.
- [ ] No secret, agent key, provider credential or private repository's source is present in a fixture, a record or this pull request.
- [ ] If the agreement needs the service's data or compose file, the test lives in the service's contract suite rather than being skipped here.
