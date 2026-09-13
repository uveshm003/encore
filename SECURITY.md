# Security policy

## Reporting a vulnerability

**Please do not open a public issue.**

Use GitHub's private reporting — *Security* → *Report a vulnerability* on this
repository — which reaches the maintainers without disclosing anything.

Useful things to include: what an attacker controls, what they get, and the
smallest input that shows it. A crafted audio file that reproduces the problem
is ideal; a description of how to craft one is fine too.

You should get an acknowledgement within a week. If you do not, assume the
message went astray and try again rather than assuming it was ignored.

## What is in scope

Encore is a local application with no server, no account and no network
dependency, which rules out most of the usual categories. What is left is worth
taking seriously:

- **Anything reached by opening a file.** Every import goes through a decoder,
  and decoders parse attacker-controlled bytes. A crafted file that causes
  memory corruption, an out-of-bounds read or write, or arbitrary code
  execution is the most serious thing this project can have. Both the platform
  decoders (AVFoundation, MediaCodec) and the built-in WAV reader count.
- **Anything reached from the share sheet**, since a file can arrive from
  another app without the user picking it. On Android that path copies a
  `content://` URI into the app's cache before decoding.
- **Path traversal** — a file name or project id that escapes the app's own
  storage and reads or writes elsewhere.
- **A network connection.** The release Android build requests no `INTERNET`
  permission, so this should be impossible by construction. If you find code
  that reaches the network on any path, that is a report worth making, whatever
  it was for.
- **Model files.** A neural model is a file the user installs, and ONNX Runtime
  parses it. A malicious model is a real threat if you can get someone to
  install one.

## What is not in scope

- **Lack of sandboxing between projects.** Everything runs as one local app on
  the user's own files with the user's own permissions.
- **Anything requiring the attacker to already have the device unlocked.** The
  project files are plain JSON and WAV on purpose, so they can be backed up and
  inspected. They are not encrypted and are not meant to be.
- **The absence of code signing on a build you made yourself.** The repository
  ships placeholder bundle identifiers and falls back to debug signing; see
  *Before you publish it* in the README.
- **Denial of service from a very large file.** Running out of memory on a
  two-hour recording is a resource limit, and there is a known one — see below.

## Known limitations

Stated here rather than waiting for someone to report them:

- **All of a project's audio is resident in memory.** A project's assets are
  loaded as 32-bit float, so a four-minute stereo stem is about 88 MiB and a
  four-stem project with takes can exceed 500 MB. It is bounded and released
  correctly, so it is not a leak, but it is a real ceiling and the likeliest
  cause of an out-of-memory kill on a phone.
- **Encore does not verify what a model file contains** beyond handing it to
  ONNX Runtime. Install models you trust.

## Disclosure

Report privately, give us a reasonable window to fix it, and we will credit you
in the release notes unless you would rather we did not.
