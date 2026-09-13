## What this changes

<!-- What it does and, more usefully, why. If it fixes an issue, "Fixes #123". -->

## Requirement

<!--
The ID from requirement.md this touches, if any — REC-04, NFR-OFF-01, and so
on. If this moves a requirement forward, update its row in
docs/requirements-status.md and say what is still missing.
-->

## Checks

- [ ] `flutter analyze` is clean
- [ ] `flutter test --exclude-tags golden` passes
- [ ] New behaviour has a test; a bug fix has a test that failed before it
- [ ] `python3 tool/licence_audit.py --check` passes *(only if pubspec.yaml changed)*
- [ ] Goldens regenerated and included *(only if the design system changed)*
- [ ] No file reformatted that this change did not otherwise touch

## Anything reviewers should know

<!--
Trade-offs, things you tried that did not work, anything deliberately left out.
A note here saves a review round.
-->
