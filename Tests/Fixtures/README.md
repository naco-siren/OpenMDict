# Test fixtures

## `tiny.mdx` / `tiny.mdd`

A 60-entry synthetic English dictionary (plus a 2-file resource archive)
used by the integration suites when `MDICT_TEST_FILE` is not set. All content
is made up for the test suite. Regenerate with:

    python3 Tests/Fixtures/make-fixture.py      # needs: pip install mdict-utils

## `lzo1x/`

Known-answer vectors for the pure-Swift LZO1X decoder: each `<name>.lzo` is
the LZO1X-1 compression of `<name>.raw`, produced once with the reference
`lzo1x_1_compress` from LZO 2.10 (the compressor is not part of this
repository). The inputs are synthetic (pseudo-random bytes, generated text,
zeros, repeated blocks) and together exercise every instruction class of the
format — short and extended literal runs, M1 in both states, M2, M3, M4 with
offsets beyond 16 KiB, extended match lengths and the end-of-stream marker.
