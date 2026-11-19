# Cueline user guide

Cueline is a custom firmware UI for the Pioneer CDJ-2000NXS2, inspired by the CDJ-3000. It is unofficial and not
affiliated with or endorsed by Pioneer DJ / AlphaTheta. Product names are used only to describe the gear Cueline
works with.

This guide describes the normal **RELEASE** build. It explains every Cueline feature and how to use it on the deck.
For installing, going back to stock and troubleshooting, see `FAQ.md`. For everything Cueline does not do yet, see
`KNOWN_LIMITS.md`.

## How to read this guide

Some features need extra gear. They are marked like this:

| Tag | Meaning |
|---|---|
| **[needs Pro DJ Link]** | The deck must be connected to other players or a mixer with LAN cables (LINK). |
| **[needs DJM-A9]** | You need a DJM-A9 mixer with its LINK CUE headphone function, on Pro DJ Link. |
| **[needs CDJ-3000]** | Only works when a CDJ-3000 is on the same Pro DJ Link. |
| **[needs rekordbox analysis]** | The track must be analysed and exported with rekordbox. |
| **(emulator only)** | Checked in our test emulator, not yet on a real deck. |
| **(not yet confirmed on the deck)** | Built and present, but no dedicated test on real hardware yet. |

---

## 1. The screens

All screens follow the CDJ-3000 layout, scaled to the NXS2's 800 x 480 touch screen.

### 1.1 Player screen

This is the main screen while you play.

- **Header (top).** The source, the track title, the artwork, the key and the track length. It also has tiles,
  among them **KEY SHIFT** (see section 4).
- **Detail waveform (middle).** The scrolling waveform with the playhead. The playhead is red while playing, white
  when paused and yellow in SLIP.
- **Pads under the waveform.** CDJ-3000-style BEAT LOOP and BEAT JUMP pads. When the loop pads are open, the
  waveform shrinks to half height.
- **Right column.** A BPM box with a MASTER tab and BEAT SYNC, the tempo % and the tempo range, MT (MASTER TEMPO)
  and a KEY box.
- **Deck bar.** Status boxes for SINGLE, AUTO CUE, REV / VINYL, QUANTIZE and A.HOT CUE (red = ON, white =
  rekordbox SETTING, hidden = OFF).
- **Player number.** It blinks while the deck is still agreeing its number with the other players.
- **Overview strip (bottom).** The whole track. See section 3.8.
- **Clean track loads.** "Loading..." stays on screen until the new track's header, numbers, waveform and overview
  are all ready. Then they appear together, in one frame. (emulator only)
- **Tracks without rekordbox analysis** play normally, but show no waveform, overview or beat grid. This is the
  same as on the CDJ-3000.

### 1.2 BROWSE screen

- A **category icon rail** on the left. Tap an icon to open that category.
- A **header** with back, the list title, PREVIEW and INFO.
- **Column headers.** Tap one to sort by that column.
- **Track rows.** Each row shows a mini waveform, a small artwork thumbnail, the title, BPM and KEY.
- **Deck strip.** A thin strip along the bottom of every non-player screen shows the loaded track.

Touch works like on the CDJ-3000:

- A tap selects a row **when you lift your finger**.
- **Drag** to scroll. **Flick** and the list keeps moving for a moment.
- The row under your finger is highlighted.
- The selected row has a **LOAD** button. Tap it to load the track.

Row colours tell you about each track:

| Row looks like | Meaning |
|---|---|
| Green triangle and green title | The track loaded on this deck |
| Green | Played on this deck in this session |
| Dark green | Previewed in this session |
| Bright green with a moving line | Being previewed right now |
| Dimmed green | Loaded on another deck |
| Green cell in the KEY column | Key compatible with the tempo master [needs Pro DJ Link] |

**Letter jump.** Turn the rotary selector fast and the list jumps to the next first letter. The letter shows in a
box. It stays fast even on very large lists.

**Other browse pages** in the CDJ-3000 layout:

- **TRACK FILTER**: BPM range, a Camelot key grid, rating, colour and MY TAG.
- **MY TAG**: categories combined with AND / OR.
- **SEARCH** results.
- **TAG LIST** rows with a mini waveform, BPM and KEY.
- **Pop-ups**: SORT, LIST MENU, TAG LIST MENU and the LOAD PREVIOUS TRACK pane.

### 1.3 SOURCE list (LINK key)

Press **LINK** to open the SOURCE list.

- The deck's own SD and USB come first.
- Then there is one row for every medium on the LINK. [needs Pro DJ Link]
- Each row has a player-number box, a LINK tag and a medium icon.
- The pane on the right shows the selected medium's songs, playlists, date and used / free space.

While a medium is in use, the **LINK** and **USB** key lamps stay lit instead of blinking. (The LINK lamp: emulator
only.)

### 1.4 INFO page

The INFO page shows the selected track's details in the CDJ-3000 layout, with a large artwork. It has a **LOAD**
button too.

### 1.5 SHORT CUT page

Press **SHORTCUT** to open it. Tap a tile to change a setting:

- WAVEFORM / PHASE / 4 BARS (the phase meter style, see section 5.2)
- HOT CUE AUTO LOAD
- QUANTIZE
- WAVEFORM COLOR
- POSITION (where the playhead sits)
- LCD brightness and JOG brightness (with < and >)
- BEAT JUMP value (1 to 64 beats)
- MY SETTINGS

### 1.6 MENU and UTILITY

- In BROWSE, **MENU/UTILITY** opens the list menus (SORT, LIST MENU and so on) as CDJ-3000 pop-ups.
- **Hold MENU/UTILITY** to open UTILITY, as on the official firmware.

UTILITY is sorted into the six CDJ-3000 categories: **DJ SETTING, DISPLAY (LCD), DISPLAY (INDICATOR), PRO DJ LINK,
SYSTEM** and **INFO**. Tap a category tile on the left to jump there. Options are shown as a radio-button list.

Every setting that Cueline adds or changes shows a short **help text** under the list when you select it. Section 2
lists them all.

### 1.7 Speed and look

- The player, MENU, SHORT CUT and INFO screens run at **60 frames per second** in our emulator. (Real-deck numbers
  for the newest code are still to be measured.)
- Closing a screen no longer flashes the stock screen.
- Frames are built off-screen, so the panel does not flicker.
- A credit line sits under the version number on the boot screen.

### 1.8 Font and icons

- **Cueline Sans** is our own UI font (SIL Open Font License). Its digits all have the same width, so the BPM and
  time do not jitter as they change.
- Cueline uses **our own 3000-style icons**.

### 1.9 Languages

- The menus are available in **English and Spanish only**: UTILITY > LANGUAGE offers ENGLISH / ESPAÑOL.
- The other menu languages, and the Chinese and Korean fonts, were removed. This frees space in the firmware for
  the new features.
- With ESPAÑOL, the names of the UTILITY items stay in English.
- **If you need another menu language, stay on the official firmware.**

---

## 2. UTILITY settings added or changed by Cueline

Hold **MENU/UTILITY** to open UTILITY. The text in quotes is the help text the deck shows under the list.

"Saved" means the value survives power-off. Some values are saved in the HISTORY NAME record. They are only kept
when your **HISTORY NAME is 29 characters or fewer** (see `KNOWN_LIMITS.md`).

### 2.1 DJ SETTING

| Item | Options | Default | Saved |
|---|---|---|---|
| HOT CUE COLOR | OFF / ON | as on the official firmware (stock item) | yes |
| KEY SHIFT | OFF / ON | OFF | yes (HISTORY NAME) |
| KEY SYNC BUTTON | OFF / ON | OFF | yes (HISTORY NAME) |

**HOT CUE COLOR** is a stock item that Cueline now follows on screen.
> "On: hot cues in their rekordbox colours.
> Off: every hot cue in the default green (CDJ-3000 style)."

**KEY SHIFT** turns our key shift on. See section 4.
> "Shifts the key in semitones without changing the tempo.
> Set it with the KEY SHIFT tile on the player screen."

**KEY SYNC BUTTON** turns the HOT CUE D/H pad into a KEY SYNC key. See section 4.4.
> "Uses the HOT CUE D/H pad as KEY SYNC (CDJ-3000 style).
> Off: no key match - Blue: keys match - White: KEY SYNC on.
> Hot cues: pads 1-3 = A/D, B/E, C/F."

### 2.2 DISPLAY (LCD)

| Item | Options | Default | Saved |
|---|---|---|---|
| LANGUAGE | ENGLISH / ESPAÑOL | (stock) | yes |
| LIGHT MODE | OFF / LIGHT / FULL | OFF | yes |
| BPM DECIMALS | OFF / ON | OFF | yes |
| WAVEFORM COLOR | 3BAND / RGB / BLUE | 3BAND | yes |
| WAVEFORM CURRENT POSITION | CENTER / LEFT | CENTER | yes |
| WAVEFORM | FULL / HALF | FULL | yes (HISTORY NAME) |
| KEY FORMAT | CLASSIC / ALPHANUMERIC | ALPHANUMERIC | yes (HISTORY NAME) |
| BEAT NUMBERS | OFF / ON | ON | **no** (temporary row, ON at every boot) |
| GRID ADJUST | OFF / ON | ON | **no** (temporary row, ON at every boot) |

**LIGHT MODE** is a day theme for bright rooms. It is our own addition, not a CDJ-3000 feature.
> "Light: dark waveforms on a light band.
> Full: the whole screen in light colours (daylight)."

**BPM DECIMALS**
> "On: the BPM shows two decimals (128.00).
> Off: one decimal, as the CDJ-3000."

**WAVEFORM COLOR**
> "The detail and overview waveform colours:
> 3BAND (low / mid / high), RGB or BLUE."

**WAVEFORM CURRENT POSITION**
> "Where the playhead sits in the detail waveform:
> CENTER, or LEFT to see more of what comes next."

**WAVEFORM** (FULL / HALF)
> "The overview and browse mini waveforms' shape:
> Full: mirrored around the centre line (CDJ-3000).
> Half: drawn up from the bottom (3BAND overview always)."

**KEY FORMAT**
> "How every key is shown (player, browse, INFO, KEY SHIFT):
> Alphanumeric: 8A, 12B - Classic: Am, F#, Eb (as rekordbox)."

**BEAT NUMBERS** (temporary row, not saved)
> "On: beat numbers over the detail waveform's grid,
> counting to the next bar (CDJ-3000 style)."

**GRID ADJUST** (temporary row, not saved)
> "On: the waveform grid follows the beat grid offset
> set with GRID ADJUST (hold PUSH on the player)."

### 2.3 PRO DJ LINK

| Item | Options | Default | Saved |
|---|---|---|---|
| PLAYER No. | AUTO / 1 / 2 / 3 / 4 / 5 / 6 | AUTO (stock) | yes |

> "The player number on Pro DJ Link (AUTO, 1-6).
> Players 5 and 6 need another deck that supports them."

### 2.4 INFO

| Item | Options | Default | Saved |
|---|---|---|---|
| BUILD | read-only | shows `Cueline-1.92 c5e8e0f3` | - |
| LINK KEY STATUS | OFF / ON | ON | no (ON at every boot) |
| KEY SYNC | OFF / ON | ON | no (ON at every boot) |
| LINK CUE | OFF / PREVIEW / CUE / BOTH | BOTH | no (BOTH at every boot) |
| MASTER WAVE NFS | OFF / ON | ON | no (ON at every boot) |
| MASTER WAVEFORM | OFF / ON | ON | no (ON at every boot) |
| HW BAND LAYER | OFF / ON | ON | no (ON at every boot) |
| LINK ROW PREVIEW | OFF / ON | ON | no (ON at every boot) |

**BUILD** shows which Cueline build is installed. Write it down when you report a problem.
> "This firmware's build: tag and source hash.
> Quote it with every report (BUILDS.tsv: its UPD)."

In the DEV build, the rows after VERSION No. are **kill switches** (**The kill switches are shown in the DEV build only**; the RELEASE build keeps every feature ON and does not show these rows.) Each one turns a single Cueline feature back to the stock
behaviour, right away. They are not saved: everything is ON again at the next power-on. See section 8.

**LINK KEY STATUS**
> "Kill switch. On: our status packet carries the
> CDJ-3000 key fields (KEY SYNC between our decks).
> Off: the stock packet."

**KEY SYNC**
> "Kill switch. Off: no new KEY SYNC (tile or pad);
> one running ends. The KEY SYNC BUTTON pads are stock."

**LINK CUE**
> "Kill switch. Off: no Link Cue preview / Touch Cue
> stream to the mixer. Both: everything on."

PREVIEW keeps only the browse-row and INFO preview. CUE keeps only Touch Cue on the playing track.

**MASTER WAVE NFS**
> "Kill switch. Off: the master's waveform is not read
> over LINK (NFS) when its database has none."

Note: this fallback route exists, but we have not yet seen it deliver a waveform. Leaving the row ON does no harm.

**MASTER WAVEFORM**
> "Kill switch. Off: the phase meter WAVEFORM view
> shows the master's beat grid only."

**HW BAND LAYER**
> "Kill switch. Off: the waveform band is drawn in
> software (no hardware scroll layer)."

**LINK ROW PREVIEW**
> "Kill switch. Off: no touch preview of the rows
> of another player's media (own media still works)."

### 2.5 Settings you no longer see

These official items are hidden because Cueline keeps them always on, as on the CDJ-3000:

- **MODS**, **WAV 32-BIT**: always on.
- **LINK CUE**: always BOTH at power-on. It comes back only as a kill switch under INFO.

---

## 3. Waveforms

### 3.1 Detail waveform

The detail waveform runs on the display's hardware layer. It scrolls smoothly in 1-pixel steps at 60 frames per
second. [needs rekordbox analysis]

- **Beat grid** ticks are drawn in the waveform. Downbeats are red.
- The playhead sits in the CENTER or on the LEFT (UTILITY > WAVEFORM CURRENT POSITION, or the POSITION tile in
  SHORT CUT).
- The detail waveform is always drawn mirrored around its centre line, as on the CDJ-3000.

### 3.2 Zoom levels

There are **six zoom levels**, the same as on the CDJ-3000. On the player screen, turn the rotary selector to zoom
in and out. To reach the sixth and closest level, keep turning past the official firmware's closest zoom. The first
turn back out leaves it.

### 3.3 Colour modes

Choose with UTILITY > WAVEFORM COLOR or the WAVEFORM COLOR tile in SHORT CUT. All three use CDJ-3000 colours, for
both the detail and the overview waveform.

| Mode | Look |
|---|---|
| 3BAND | low / mid / high in separate colours |
| RGB | colour by frequency |
| BLUE | the classic blue waveform |

The deck always asks for the colour waveform data, whatever colour is stored on your stick.

3BAND needs the rekordbox 3-band data. If a track does not have it, the RGB look is used instead.

### 3.4 WAVEFORM FULL / HALF

UTILITY > DISPLAY (LCD) > **WAVEFORM** sets the shape of the **overview strip** and of the **mini waveforms in the
browse rows**. The default is **FULL**.

- **FULL**: mirrored around the centre line, as on the CDJ-3000.
- **HALF**: drawn up from the bottom.
- In **3BAND**, the overview is always drawn from the bottom, as on the CDJ-3000.
- The detail waveform does not change: it is always the mirrored (full) waveform.

This setting is saved only with a HISTORY NAME of 29 characters or fewer.

### 3.5 Cue, loop and memory markers

- Hot cues, memory cues and loops show in their **rekordbox colours**.
- The comment of the next cue shows in the waveform.
- Both were checked in the emulator with test tracks only. (emulator only)
- **HOT CUE COLOR** (UTILITY > DJ SETTING): ON shows hot cues in their rekordbox colours. OFF shows them all in the
  default green, as on the CDJ-3000.

### 3.6 Loops

- The active loop is shaded in the waveform.
- Its length, in beats, shows under the playhead.

### 3.7 Slip ghost

While **SLIP** is on, a blue marker in the detail waveform and the overview shows where the track really is.

### 3.8 Overview strip

- Hot-cue badges, memory-cue triangles, a minute ruler, and a darker colour for the part already played.
- **Tap** the strip to jump there.
- While a track plays, a finger on the strip marks the point you are previewing (see Touch Cue, section 6.2).

### 3.9 Beat numbers (temporary)

Under the detail waveform, numbers show how many beats away the next beats are, for example 4 or 8 beats ahead of
the playhead. This is the same idea as on the CDJ-3000.

- Turn them off with UTILITY > DISPLAY (LCD) > **BEAT NUMBERS**.
- **Temporary row, not saved.** It is ON again at every power-on.

### 3.10 GRID ADJUST (display, temporary)

When you shift the beat grid with the official **GRID ADJUST** (hold PUSH on the player screen), the grid drawn in
the waveform follows the shift.

- This is **display only**. The deck's own beat grid, used for SYNC and QUANTIZE, does not move.
- UTILITY > DISPLAY (LCD) > **GRID ADJUST** OFF makes the drawn grid ignore the shift.
- **Temporary row, not saved.** It is ON again at every power-on.

### 3.11 MASTER PLAYER label

When this deck becomes the tempo master, a **MASTER PLAYER** label shows at the playhead for a moment.
[needs Pro DJ Link]

---

## 4. Key

### 4.1 KEY FORMAT

UTILITY > DISPLAY (LCD) > **KEY FORMAT** chooses how keys are written everywhere in the UI: the player, browse, INFO,
the KEY SHIFT panel, the KEY list and the filter.

| Option | Example |
|---|---|
| ALPHANUMERIC (default) | 8A, 12B (Camelot style) |
| CLASSIC | Am, F#, Eb (as in rekordbox) |

Saved only with a HISTORY NAME of 29 characters or fewer.

### 4.2 Key colours

- The **KEY box** turns green when your key fits the master's key. [needs Pro DJ Link]
- In browse, compatible keys get a **green cell** in the KEY column. [needs Pro DJ Link]
- With MASTER TEMPO **off**, moving the tempo fader also changes the pitch. The key you actually hear then shows in
  **grey**.
- A key changed with KEY SHIFT shows in **orange**.

### 4.3 KEY SHIFT

KEY SHIFT changes the key in semitone steps, from -12 to +12, without changing the tempo. It uses **our own key
shift engine**.

**Status:** our own engine runs on the real decks; its sound quality has not been judged yet.

How to use it:

1. Turn on UTILITY > DJ SETTING > **KEY SHIFT** (ON).
2. On the player screen, tap the **KEY SHIFT** tile in the header. The KEY SHIFT panel opens in place of the pads.
3. Tap **-1** or **+1** to shift one semitone down or up. Each tile shows the key you will get.
4. The middle tile shows the current shift. Tap **RESET** to go back to the original key.
5. Tap the header tile again to close the panel.

How it works with MASTER TEMPO (as on the CDJ-3000):

- **MASTER TEMPO on:** the key you hear is the original key plus the shift.
- **MASTER TEMPO off:** the tempo fader's pitch is added too. So the key you hear is the original key, plus the
  fader's pitch, plus the shift.

Things to know:

- About 23 ms of extra latency while a shift is active.
- Large shifts can sound "phasey".
- The shift keeps running while you scratch.
- Very fast double taps on -1 / +1 can be missed. Tap at a normal pace.
- Turning KEY SHIFT OFF in UTILITY sets the shift back to 0 and closes the panel.

### 4.4 KEY SYNC

KEY SYNC shifts your key to match the tempo master's key with one tap. [needs Pro DJ Link] [needs KEY SHIFT ON]

How to use it:

1. Make sure UTILITY > **KEY SHIFT** is ON and a track is loaded.
2. Another deck must be the tempo master, with a track whose key is known.
3. Open the KEY SHIFT panel and tap **KEY SYNC**.

What happens:

- Your key moves to the nearest match: the same key as the master, or one Camelot step either way. The shift is at
  most 2 semitones.
- **MASTER TEMPO is turned on** for you, so the tempo fader no longer changes the key.
- The deck keeps following the master. A blue **K.SYNC** badge shows where MT is normally shown.
- If KEY SYNC cannot work (no key, or no master), the tile flashes white and nothing changes.

KEY SYNC ends when:

- you load a new track on this deck (MASTER TEMPO goes back to how it was);
- you turn KEY SHIFT OFF;
- you turn MASTER TEMPO off;
- you tap -1, +1 or RESET (the current shift is kept).

Which masters work:

- **NXS2 masters** (running Cueline or the official firmware). The master's key is read from the LINK status and from
  the master's database. The key matching was tested on real decks. With our own KEY SHIFT engine it is checked in
  the emulator only.
- **CDJ-3000 masters.** The key is read from the CDJ-3000's status, including its own KEY SHIFT.
  [needs CDJ-3000] (emulator only: tested against a CDJ-3000 emulator, not a real CDJ-3000)

### 4.5 KEY SYNC BUTTON (pad D/H)

With UTILITY > DJ SETTING > **KEY SYNC BUTTON** ON, the **HOT CUE D/H** pad works like the CDJ-3000's KEY SYNC key.

- Press the pad to turn KEY SYNC on or off (the same as the KEY SYNC tile).
- The pad lamp tells you the state:

| Lamp | Meaning |
|---|---|
| Off | Your key does not match the master's |
| Blue | The keys match |
| White | KEY SYNC is on |
| Blinking | The press was refused (for example KEY SHIFT is OFF) |

- While this setting is ON, **hot cues D and H cannot be used from that pad**.
- OFF (the default) is the official behaviour: the pad is a normal hot cue pad.
- The exact lamp colour on a real deck is not yet confirmed.

---

## 5. Tempo and sync

### 5.1 Tempo takeover

After you turn **SYNC** off, the deck keeps playing at the synced tempo, as on the official firmware. Your tempo
fader is probably at another position. Cueline helps you pick the tempo up:

- The fader's own BPM shows in **grey**.
- An **arrow** next to it shows which way to move the tempo fader.
- Move the fader that way until it meets the playing tempo.

SYNC itself works as on the official firmware.

### 5.2 Phase meter: PHASE / WAVEFORM / 4 BARS

Tap the phase meter to switch between three styles. You can also use the WAVEFORM / PHASE / 4 BARS tile in SHORT
CUT. Your choice is saved.

| Style | Shows |
|---|---|
| PHASE | CDJ-3000-style phase bars |
| WAVEFORM | The tempo master's own detail waveform (see below) |
| 4 BARS | The classic NXS2 meter |

The master's beats need Pro DJ Link. [needs Pro DJ Link]

### 5.3 The phase meter WAVEFORM view

In the WAVEFORM style, the phase meter shows the **tempo master's own detail waveform**, fetched over Pro DJ Link.
You can line up the beats by eye against the master.

- Works with an **NXS2 master**. [needs Pro DJ Link]
- With a **CDJ-3000 master playing from SD**, there is no waveform yet. Only its beat grid is shown.
- If this view causes trouble, turn UTILITY > INFO > **MASTER WAVEFORM** OFF. The view then shows the master's beat
  grid only.

### 5.4 Cue countdowns

The bars and beats left until the next cue are shown for your deck, and for the master, in CDJ-3000 colours. The
master's countdown needs Pro DJ Link. [needs Pro DJ Link]

### 5.5 BEAT JUMP and BEAT LOOP

- Set the **BEAT JUMP value** from 1 to 64 beats in SHORT CUT. It is saved across power-off (with a HISTORY NAME
  of 29 characters or fewer).
- CDJ-3000-style **BEAT LOOP** and **BEAT JUMP** pads sit under the waveform.
- Whole beats only. There is no 1/2-beat jump.

### 5.6 Players 5 and 6

UTILITY > PRO DJ LINK > **PLAYER No.** offers AUTO and 1 to 6.

- Players 5 and 6 need other gear on the LINK that supports them. [needs Pro DJ Link]
- A deck with the official NXS2 firmware will not share its media with players 5 or 6.

---

### Known behaviour (same as stock CDJ-2000NXS2 1.87)
Cueline does not change how MASTER and SYNC hand over the tempo master. These handoffs come from the stock
firmware; we checked them against an unmodified 1.87:
- **Two decks playing:** pressing **MASTER** on the deck that is already the tempo master hands master to the other
  playing deck. With the decks stopped, the deck stays master.
- **Pausing the master** hands master to a deck that is still playing.
- **Loading a track on a lone deck** makes it the master.

## 6. Link Cue and audio

### 6.1 Link Cue

Hear a track in your headphones before you load it, through the DJM-A9's **LINK CUE**.
[needs DJM-A9] [needs Pro DJ Link]

1. Connect the deck and the DJM-A9 with Pro DJ Link.
2. In BROWSE, **hold your finger on a row's mini waveform**.
3. The track plays from that point on the mixer's LINK CUE headphones. Move your finger to move the point.
4. Lift your finger to stop.

- Works from the deck's own USB / SD, and from other players' media over LINK.
- Formats: **MP3, FLAC and WAV** (16, 24 and 32-bit).
- **AIFF and M4A** files stay silent.
- To turn off only the preview of other players' media, use UTILITY > INFO > **LINK ROW PREVIEW** OFF.

### 6.2 Touch Cue

While a track plays, put a finger on the **overview strip**. The loaded track plays from that point on the
DJM-A9's LINK CUE. The main output is not touched. [needs DJM-A9] [needs Pro DJ Link]
(not yet confirmed on the deck)

### 6.3 WAV 32-bit

The deck plays **32-bit WAV** files, both integer and float. The official firmware refuses these files. It is
always on.

---

## 7. Build ID

UTILITY > INFO > **BUILD** shows the installed build's tag and source hash, for example:

```
Cueline-1.92 c5e8e0f3
```

Check it after every install. Quote it in every bug report.

---

## 8. Kill switches and the NOMODS file

If a Cueline feature misbehaves during a set, you can turn it back to the official behaviour without reflashing.

> **The kill switches are shown in the DEV build only**; the RELEASE build keeps every feature ON and does not show these rows.

**Kill switches** are the rows at the end of UTILITY > INFO, after VERSION No.:

| Row | When OFF |
|---|---|
| LINK KEY STATUS | The deck sends the official status packet, without the CDJ-3000 key fields |
| KEY SYNC | No new KEY SYNC; a running one ends; the D/H pad is a normal hot cue pad |
| LINK CUE | No Link Cue and no Touch Cue (PREVIEW or CUE keeps only one of them) |
| MASTER WAVE NFS | The master's waveform is not looked up over LINK as a fallback |
| MASTER WAVEFORM | The phase meter WAVEFORM view shows the master's beat grid only |
| HW BAND LAYER | The detail waveform is drawn in software instead of on the hardware layer |
| LINK ROW PREVIEW | No touch preview of other players' media (your own media still works) |

- They work **at once**.
- They are **not saved**. Everything is ON again at the next power-on.

**NOMODS file.** Put an empty file named `NOMODS` at the root of your USB stick or SD card. The deck then turns off
Link Cue and the browse-row preview, without reflashing. Remove the file to get them back.

---

## 9. What the RELEASE build does not include

The normal (RELEASE) build has **no BLACK BOX recorder, no logs and no network commander**. It keeps no logs of your
sets.

These tools exist only in the **DEV build**, for contributors who help us find hard bugs. See `dev/README.md` in the
repository. Only install a DEV build if a contributor asks you to.

---

## 10. Going back to stock

Disconnect the Pro DJ Link (LAN) cable first: while LINK is active the player does not allow DUPLICATION > DEFAULT. Then UTILITY > PRO DJ LINK > DUPLICATION > **DEFAULT**, then install the official 1.87 update. Full steps and the reasons
are in `FAQ.md` and in `back_to_stock.txt`.
