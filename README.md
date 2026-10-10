# Rapoo Audio Control Mac — v1.2

**Project by Andalib Ahmmed Dhrubo. Developed with ChatGPT assistance.**

An unofficial Rapoo VH310 audio control app for Apple Silicon Macs running macOS 14.4 or later, with EQ, virtual surround, microphone monitoring, and room effects.

## Project background

Created with ChatGPT assistance from OpenAI for code generation, adaptation, debugging, and documentation. Project direction and headset testing by Andalib Ahmmed Dhrubo.

The supplied **official Rapoo Windows audio driver/control application package** was used as a reference for the interface and features. Some original interface artwork was extracted from that package. The macOS audio implementation uses native Apple APIs and custom processing; it is not the Windows driver itself and does not reproduce all proprietary Rapoo features.

## Build and run

1. Install Apple Command Line Tools if needed: `xcode-select --install`.
2. Extract the project and open Terminal in its folder.
3. Run `bash Build-on-Mac.command`.
4. The script builds and opens `build/Rapoo Audio Control Mac.app`.
5. Allow the requested macOS audio capture and microphone permissions.

See [README.txt](README.txt) for detailed setup, controls, limitations, and validation.

## Credits and scope

This is an independent, unofficial project, not affiliated with or endorsed by Rapoo or OpenAI. Rapoo trademarks and original artwork remain the property of their respective owners. MIT KEMAR HRTF data is credited to Bill Gardner and Keith Martin, MIT Media Lab, 1994.

See [CREDITS.txt](CREDITS.txt) and [HRTF attribution](Resources/HRTF-attribution.txt). Project attribution does not claim ownership of third-party materials or grant a new license for them.

RGB control is unsupported in this release. Normal system playback uses stereo-derived virtual surround; the app does not install a discrete 7.1 system device or a processed virtual microphone for other apps.
