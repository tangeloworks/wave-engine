# Contributing

Bug reports, small fixes, examples and documentation corrections are welcome.
Keep changes focused. Discuss a large API change in an issue before spending
time on it, and keep existing project APIs working where possible.

For a bug report, include your operating system, LÖVE version, graphics card
if rendering is involved, the error text, and a small project that reproduces
the problem. State what you expected to see and what happened. Use public
assets or generated geometry, and do not attach credentials.

Before opening a pull request, run the regression suites with
`RBX_TEST=1 love .` (and `RBX_TEST=graphics love .` for rendering changes),
then run the affected showcase with LÖVE 11.5 and resize its window. For
rendering changes, include a screenshot and describe how you checked it. For
performance work, record the scene, hardware and measurements before and
after the change.

Keep code examples in the README consistent with the API. Describe how to
reproduce a bug and how you checked the fix. New assets need a recorded source
and redistribution license, added to [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
Preserve vendored license texts. Contributions to engine code use the
repository's MIT license; third-party material keeps its own license.

Be considerate when reviewing or discussing changes. There is no promised
response time or support schedule.
