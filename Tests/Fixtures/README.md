# Original substitution fixtures

These fonts are generated specifically for this project by `../make-gsub-fixtures.py`; glyph outlines are rectangles, not copies of installed fonts. Installed Hiragino Sans, LucidaSubmono, Zapfino and Futura fonts are read in place by optional tests and are not redistributed here.

Normal CLI checks use the committed binaries and Python's standard library. Regeneration needs fontTools >= 4.60.2:

```sh
python3 Tests/make-gsub-fixtures.py
```

GSUB formats are assembled explicitly to avoid a feature compiler silently selecting a different format. morx/mort fixtures cover every legal subtable type (0, 1, 2, 4, 5). Three intentionally malformed GSUB tables verify safe failure. Font timestamps are fixed for reproducibility. See `cases.json` and `aat-cases.json` for expected output sequences.

For a visible one-to-many example, open `multiple.ttf`, type `a`, then select `test` (`a.alt / b.alt`, GIDs 18 and 20). The selected result contains two adjacent rectangles. `shared-output-ligatures.ttf` tests two source spans that deliberately produce the same GID as the last input character.
