RAPOO AUDIO CONTROL MAC — PROJECT BUILD 1.2
Apple Silicon / macOS 14.4+.

AUDIO / MICROPHONE UPDATE 1.2
Virtual 7.1 stereo playback now mixes direct sound with the measured spatial
render and adds +4 dB makeup gain, with linked peak protection and an 80 ms
release. A quiet 440 Hz mono test measures +3.86 dB versus bypass. Loudness
varies with content and limiter activity. 3D processing and discrete WAV /
speaker-test rendering are unchanged. Direct sound stays anchored while
rotation changes the spatial component.
Mic capture starts when the interface is ready, prompting for permission if
needed. Monitoring defaults OFF and can be enabled on the Mic page. Hardware
input controls refresh after startup and once per second when values change;
unsupported hardware controls remain disabled. Recording has been removed.
A gentle 70 Hz high-pass reduces DC and low-frequency handling rumble in the
monitor path. Existing gain, boost, mute and soft limiting remain available.
The VH310 product photo, layout and other controls are retained.

INSTALL / UPDATE
1. Quit the old Rapoo app.
2. Extract this ZIP into a fresh folder.
3. In Terminal type bash and a space, drag Build-on-Mac.command in, then Return.
4. The script builds and opens build/Rapoo Audio Control Mac.app.
5. Replace the old copy in Applications with that newly built app.
If tools are missing, run xcode-select --install.
The Mac build needs no Python, subscription, downloaded library or internet.

VIRTUAL 7.1 — NORMAL MAC PLAYBACK
Play ordinary stereo music, click Start audio and open Virtual7.1.
Click 7ch1-EN ON. The stereo capture is upmixed to seven virtual speakers plus
bass, then rendered to Rapoo headphones using measured MIT KEMAR HRTFs.
- Front left/right: -30/+30 degrees.
- Center: directly in front.
- Side left/right: -90/+90 degrees.
- Back left/right: -150/+150 degrees.
- Bass/LFE: centered, two-pole 120 Hz lowpass; no cinema +10 dB boost.
Narrow / Enlarge decrease / increase stereo-derived surround ambience.
The Upmix strength slider sets that same amount (0–100%).
CW / CCW rotate the seven directional speakers in 15-degree steps. RESET
restores 60% strength and zero rotation, retaining the current ON/OFF state.
Selecting a direction uses the nearest measured 5-degree HRTF and a 30 ms
crossfade. ON/OFF fades over 20 ms. EQ and room effects remain independent.
The earlier 3D WIDTH and two-front-speaker HRTF are overridden while 7.1 is ON.
They become available again when 7.1 is OFF; their saved settings are retained.
Stereo ambience comes from difference content, with delayed rear feeds.
Identical mono inputs do not invent independent rear voices.

SPEAKER TESTS / DISCRETE 7.1
Pause music first. Click any speaker in Virtual7.1 to play an isolated burst;
Bass uses a 65 Hz tone. Tests use the actual eight-channel renderer and the
current rotation. They bypass EQ, room and width for a clear comparison.
8-channel demo plays the bundled 12-second WAV containing one channel at a
time: front left, front right, center, bass, back left, back right, side left,
side right, with 1.5 seconds per channel. This is discrete source audio, not a
pre-spatialized stereo YouTube demo. These are ear-position cues, not a promise
that a generic HRTF will place every sound outside every listener's head.
Open 7.1 WAV plays your own uncompressed eight-channel file through the same
renderer. Supported: PCM16/24/32 and Float32, 44.1/48/88.2/96 kHz, RIFF/WAVE.
Channel order: FL FR C LFE BL BR SL SR. Extensible WAV requires mask 0x63f
and valid bits equal to the container precision. Plain PCM WAV uses that same
explicit assumed channel order. Stereo files, other masks and compressed
formats are rejected. The entire file is not loaded into memory: playback
streams bounded chunks and drains the filter tail before finishing.
Tests/file playback stop the system-audio tap. Stop test/file stops them;
click Start audio to resume normal processing. Upmix strength affects stereo
ambience only, not independent channels from a discrete WAV. Rotation works
in both modes. Other apps' original playback remains audible during tests,
so pause them to avoid competing sound.

SCOPE OF THIS FINAL VERSION
The system tap receives a stereo mix. Normal Mac playback therefore uses
stereo-derived virtual surround; it cannot recover original independent rear,
center or LFE channels once another app has downmixed them.
Discrete eight-channel WAV files and the built-in tests use actual independent
channels. This app does not install an eight-channel virtual system device;
games and media apps cannot select it as a discrete 7.1 output. That would
require a separate virtual audio driver and is outside this final build.
The implementation is independent and is not bit-identical to Rapoo's
proprietary Windows DSP. This is the final requested project package, not a
claim of complete Windows-driver parity or native validation on every Mac.

MIC / EFFECTS / EXISTING FEATURES
Mic: approve microphone access on launch. Capture starts automatically;
Start Mic / Stop Mic allows manual control. Monitor ON routes the processed
mic to the Rapoo headphones at a modest level; Monitor OFF stops sidetone.
Software gain (-24..+12 dB), +12 dB boost, mute, high-pass and limiting affect
this app's monitoring only. There is no virtual processed microphone for
Zoom or Discord. Separate hardware input level/mute affect other apps when
the headset exposes writable controls. Hardware changes are not stored in
profiles and may persist after quitting. Reconnect a missing headset, then
click Start Mic. Input control availability refreshes automatically.
Effect: original room choices, independent ON/OFF and 0–70% strength. These
use Apple room reverb presets inspired by the installer, not identical DSP.
EQ: five bands, four editable slots, EQ-EN and reset.
3D: mid/side WIDTH and two-front-speaker HRTF, available when 7.1 is bypassed.
The existing process tap excludes this app and requests muted original audio,
retaining the earlier fix for doubled playback and fullscreen scaling.
The rounded blue/white Mac icon is retained.

PROFILES
Save/Load stores EQ, room strength/bypass, WIDTH, HRTF, software Mic and
Virtual7.1 enable/strength/rotation. Older profiles load with 7.1 OFF, strength
60%, rotation 0. Loading a profile does not start capture or tests.
Mic monitoring stays OFF. Windows profiles are not supported.

VALIDATION 1.2
Portable binaural, microphone, surround and new surround-loudness C tests
passed on Linux with AddressSanitizer and UndefinedBehaviorSanitizer.
LeakSanitizer was disabled because this environment cannot inspect processes.
Loudness tests cover centered mono, gain and peak bounds at 44.1/48/88.2/96 kHz.
Existing tests cover directional impulses, split-buffer continuity, rotation,
exact bypass, microphone gain/mute/limiting and finite samples.
JavaScript syntax and mocked UI/native bridge tests passed for startup,
monitor toggling, recording removal and hardware input-level refresh.
Build shell syntax and plist parsing passed. This environment has no macOS
SDK or headset; Swift compilation, permissions, real hardware input controls,
monitor audibility/latency and listening quality require testing on your Mac.

OPTIONAL PORTABLE DSP TESTS ON MAC
mkdir -p build
cc -O3 Sources/Surround.c Tests/test_surround.c -o build/test_surround
build/test_surround
cc -O2 Sources/MicDSP.c Tests/test_mic.c -o build/test_mic
build/test_mic
cc -O2 Sources/binaural.c Tests/test_binaural.c -o build/test_binaural
build/test_binaural

DATA ATTRIBUTION
Bill Gardner and Keith Martin, MIT Media Lab, 1994.
HRTF Measurements of a KEMAR Dummy-Head Microphone.
Copyright 1994 MIT Media Laboratory. Data provided free without restrictions
on use provided the authors are cited for research/commercial applications.
https://sound.media.mit.edu/resources/KEMAR.html
Details: Resources/HRTF-attribution.txt and Surround-HRTF-source.json.

Unofficial personal compatibility project using your supplied Rapoo installer.
Firmware/LED, ENC, proprietary FBM, startup/tray parity remain unimplemented.


PROJECT CREDITS

Project by Andalib Ahmmed Dhrubo.
Developed with ChatGPT assistance from OpenAI for code generation, adaptation,
debugging, and documentation, with project direction and headset testing by
Andalib Ahmmed Dhrubo.

SOURCE AND REFERENCE
This unofficial macOS compatibility project was developed using the supplied
official Rapoo Windows audio driver/control application package as a reference.
The Windows application's interface layout and extracted artwork informed the
Mac version. The macOS audio implementation uses native Apple audio APIs and
custom processing; it is not the original Windows driver running on macOS and
does not reproduce every proprietary Rapoo feature or DSP algorithm.

THIRD-PARTY CREDITS
Rapoo names, logos, and original driver artwork belong to their respective
owners. This project is not affiliated with, endorsed by, or supported by Rapoo.
ChatGPT is a tool used in development; OpenAI does not endorse this project.
MIT KEMAR HRTF measurements: Bill Gardner and Keith Martin, MIT Media Lab, 1994.
See Resources/HRTF-attribution.txt for the existing data attribution and terms.
These project credits do not claim ownership of third-party artwork or data,
and do not grant a new license for those materials.
