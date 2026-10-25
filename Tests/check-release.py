#!/usr/bin/env python3
"""Check actual linked release images, independently of header/build defines."""
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
selectors = (
    b"hasFeatureVariations\0",
    b"featureSpecifications\0",
    b"shapeText:features:script:language:branch:\0",
)
for arch in ("arm64", "x86_64"):
    binary = ROOT / ".build" / "bin" / ("GlyphAtlas-" + arch)
    data = binary.read_bytes()
    for selector in selectors:
        assert selector not in data, (binary, selector)
cli = (ROOT / ".build" / "gsub-cli").read_bytes()
for selector in selectors[1:]:
    assert selector in cli, ("missing CLI test interface", selector)
print("OK: test selectors present in CLI, absent from both release architectures")
