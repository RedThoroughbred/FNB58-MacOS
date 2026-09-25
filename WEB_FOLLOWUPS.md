# Web dashboard follow-ups (desktop app only — do NOT touch `ios/`)

Scope: the Flask + Socket.IO web app (`app.py`, `device/`, `static/`, `templates/`, `tests/`).
The iOS app in `ios/` is being developed on another branch in parallel; leave it alone.
Run `python -m pytest` (must stay green, 43+ tests) and `node --check static/js/*.js` before every commit.
There is no hardware in CI: `tests/fakes.py` has a `FakeReader`; use it for anything that needs a device.

These are verified findings from a code review (file:line refer to `main` at the time of writing).

## Correctness

1. `static/js/dashboard_pro.js` ~L360: lowering TIMEBASE never shrinks the waveform window — only one old point is dropped per new reading. Trim the buffer to the new window size when the timebase changes.
2. `static/js/dashboard_pro.js` export (`exportHTMLReport`, ~L646-660): exports `dataBuffer` (capped 10k, cleared by CLEAR) instead of the recording, and hard-codes `connection_type: 'usb'`. Export the recorded session (fetch it from `/api/sessions/<file>` after stop, or keep the recording buffer client-side) and send the real connection type from `/api/status`.
3. `static/js/analysis.js` ~L72-76, 143-161: `phaseHistory` grows without bound and the whole timeline DOM is rebuilt on every phase change. Cap history (e.g. 200 entries) and append incrementally.
4. `static/js/analysis.js` ~L207: EFFICIENCY is `90 + Math.random()*8` — fake data shown as measured. Remove the tile or show "n/a" with an explanation (efficiency needs input and output power; a single meter can't measure it).
5. `static/js/spectrum.js` ~L250 and ~L103: THD harmonic bins assume 100 Hz sample rate instead of `sampleRate`; the "wait N seconds" hint assumes 10 Hz. Use the measured rate for both.
6. `static/js/oscilloscope.js` ~L199: tooltip unit check `label.includes('Voltage')` matches none of the channel labels, so voltage tooltips show "A". Match on the actual labels or carry a unit per dataset.
7. `static/js/oscilloscope.js` ~L297-318: frequency estimate counts mean-crossings with no noise threshold, so a clean DC supply shows a fabricated 10-25 Hz. Add hysteresis (e.g. 2% of range) and show "DC" below a minimum amplitude.
8. `static/js/dashboard_pro.js` ~L495: the RUN button calls `toggleFreeze()`, so clicking RUN while running freezes the display. RUN should un-freeze only; FREEZE should freeze only.
9. `static/js/dashboard_pro.js` ~L979-985: `updateActiveTriggerButton` ignores which protocol was triggered, so triggering PD 9V highlights the 9V buttons of QC/AFC/FCP/SCP too. Scope the highlight to the protocol's panel.
10. `templates/settings_pro.html` ~L208-215, 284: `saveThresholds` ignores the HTTP status (a rejected 400 is still reported as "saved"), and `displaySettings` is written to localStorage but never read. Check `response.ok`; either apply display settings on the dashboard or remove the control.
11. `static/js/common.js` ~L34-36 (called from ~L141): `#connection-status` does not exist in `base_pro.html`, producing a caught TypeError on settings/history pages. Guard or add the element.
12. `static/js/history.js`: not loaded by any template (dead code); if kept, its CSV export at ~L329 parses a CSV download as JSON. Delete it or wire it up correctly.
13. `static/css/professional.css` ~L2062 overrides the two-per-row control layout at ~L1777 (phones get 5-6 full-width rows pushing the chart below the fold); at ≤480px the chart is forced to 200px (~L2164) while its container is ≥250px (~L1767), squashing the drawing. Fix both so the phone layout keeps the chart above the fold.

## Housekeeping

14. `Dockerfile`, `docker-compose.yml`, `docker/`, `DOCKER.md`: eventlet was removed from `requirements.txt` (Flask-SocketIO now runs in threading mode with `simple-websocket`); make sure the container still starts (`python start.py`, port 5001) and docs match.
15. The many `*_GUIDE.md` / `*_SUMMARY.md` files at the repo root overlap heavily; consolidate into README + one `docs/` page or delete the stale ones (keep `CLAUDE.md`, `README.md`, `GETTING_STARTED.md`, `DOCKER.md`, `PRIVACY.md`).
16. Add JS unit tests (plain Node, no framework needed, or vitest) for the pure functions in `static/js/dashboard_pro.js` — the energy accumulator (`accumulateEnergy`), timebase trimming, THD bin selection — by moving them into a small module that both the browser and tests can load.

## Definition of done

- Each item is a separate commit with the finding number in the message.
- `python -m pytest` green; `node --check static/js/*.js` clean; pages `/dashboard`, `/settings`, `/history`, `/classic` load with no console errors at 375px and 1280px widths.
- Open one PR against `main` titled "Web dashboard follow-ups" with a checklist of the items above.
