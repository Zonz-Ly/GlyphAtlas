# Original substitution fixtures

These fonts are generated specifically for this project by `../make-gsub-fixtures.py`; glyph outlines are rectangles, not copies of installed fonts. Installed Hiragino Sans, LucidaSubmono, Zapfino and Futura fonts are read in place by optional tests and are not redistributed here.

Normal CLI checks use the committed binaries and Python's standard library. Regeneration needs fontTools >= 4.60.2:

```sh
python3 Tests/make-gsub-fixtures.py
```

GSUB formats are assembled explicitly to avoid a feature compiler silently selecting a different format. morx/mort fixtures cover every legal subtable type (0, 1, 2, 4, 5). Three intentionally malformed GSUB tables verify safe failure. Font timestamps are fixed for reproducibility. See `cases.json` and `aat-cases.json` for expected output sequences.

For a visible one-to-many example, open `multiple.ttf`, type `a`, then select `test` (`a.alt / b.alt`, GIDs 18 and 20). The selected result contains two adjacent rectangles. `shared-output-ligatures.ttf` tests two source spans that deliberately produce the same GID as the last input character.


The self-written branch adds explicit GPOS 1–9 fixtures, PairSet-relative devices,
GDEF variation positioning, actual GPOS FeatureVariations selection, nested
expansion/deletion, all 16 AAT rearrangement verbs in both encodings, and AAT
end-of-text substitution/ligature/insertion actions. `position-cases.json` and
`aat-extra-cases.json` contain independent expected output.

The legacy mort insertion fixture now uses byte offsets from the state table,
with zero meaning no list, as specified by Apple. It does not reuse morx's
extended insertion header or index encoding. Subtables are padded to four bytes
and chain feature lists include the required all-features-off terminator.


`unencoded-neighbor.ttf` exposes unencoded GID 19 as `a`'s aalt. The liga
lookup precedes aalt, so the text query `ab` alone cannot form the ligature.
Selecting GID 19 lets it ligate with adjacent `b` into GID 22. `ca` exercises a
contextual change on the selected GID itself. The morx/mort companion fixtures
use two chains and the same unencoded GID. Example, without a GUI:

```sh
.build/gsub-cli --font Tests/Fixtures/unencoded-neighbor.ttf --text ab --seed 0:1=19 --model
.build/gsub-cli --font Tests/Fixtures/unencoded-neighbor.ttf --text ab --seed 0:1=9,19 --model
```

The second candidate preserves GID 9 alongside the new ligature. Seed ranges
are UTF-16 source ranges, and may cover multiple composed characters.
