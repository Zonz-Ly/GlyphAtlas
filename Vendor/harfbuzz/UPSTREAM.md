HarfBuzz 14.5.0

Official release: https://github.com/harfbuzz/harfbuzz/releases/tag/14.5.0
Archive SHA-256: b7132e148358a45185c9feafd049dbaf243649d3c44414b3534d9c95d18592b9

Vendored source, statically linked. The CoreText shaper is disabled; GSUB, morx/mort, GPOS and AAT positioning are enabled.
License: COPYING (Old MIT), plus src/ms-use/COPYING (MIT) for the Universal Shaping Engine. Both notices are packaged with the app. No runtime download or external installation.


Release build policy: compile the upstream `src/harfbuzz.cc` amalgamation as one translation unit with `-Oz -flto -ffunction-sections -fdata-sections`, hidden visibility and hidden inline visibility. The app also uses `-Oz -flto`; the linker uses `-dead_strip` and `-x` (remove local symbols). Link maps remain in `.build/bin/GlyphAtlas-<arch>.map` for inspection. No extra shaping capabilities were disabled to obtain the size reduction.
