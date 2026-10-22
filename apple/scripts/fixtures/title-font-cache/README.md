These two owned test fonts were generated from scratch with FontTools 4.60.1.
They contain only empty `.notdef`/space glyphs and a simple A: a triangle in
`owned-a.ttf`, a rectangle in `owned-b.ttf`. No external font outlines or font
metadata were copied. Both intentionally use PostScript name
`StreamOwnedCacheFixture-Regular`, with different glyph advances (600/900
units at 1000 units per em), to test replacement under the same identity.

The harness registers them only in its own process and unregisters them on
completion. It does not install fonts or change user/session preferences.
