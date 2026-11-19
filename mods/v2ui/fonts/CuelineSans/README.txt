Cueline Sans -- our UI face (SIL OFL 1.1, a modified Outfit; see FONTLOG.txt, OFL.txt)

  source-Outfit-wght.ttf   the unmodified OFL source (variable, wght 100..900)
  build_font.py            source -> CuelineSans-Regular.ttf / -Display.ttf (committed outputs)
  CuelineSans-*.ttf        what the build uses:
                             mods/v2ui/fontgen.py --cueline  (V2 UI bitmap fonts, fitted to the UI grid)
                             mods/font3000/font3000.py       (stock GUI latin font, cap 16 px)
Default in DEV and RELEASE. Another (open) TTF can be used as an override:
CDJ_V2_TTF / CDJ_FONT3000_TTF (build.sh --font-ttf); such builds differ from the reference.
