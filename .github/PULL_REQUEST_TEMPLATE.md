## What this changes

## Checklist
- [ ] Builds with `./build.sh` (and `PROFILE=dev ./build.sh` if it touches dev/) from the official CDJ-2000NXS2 1.87 `.UPD`
- [ ] `verify.txt`: all checks passed; `bootcheck.txt`: PASS
- [ ] No Pioneer / AlphaTheta bytes, firmware files, fonts, icons or keys added; nothing extracted from any firmware
- [ ] No CDJ-3000 firmware content; no local paths, IPs or e-mails
- [ ] Every MAIN change that allocates, spawns or hooks is gated on normal boot (`*0x0A35DF3C == 1`)
- [ ] GUI section still at or below the stock size (`build.log`)
- [ ] English only (code comments and docs)
- [ ] Tested on: emulator / real deck (model, setup, what you checked):

## Notes for reviewers
