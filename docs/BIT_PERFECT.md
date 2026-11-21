# Measuring bit-perfect playback

A pass means that every sample in the captured reference segment has the
same PCM value, channel order and sample rate as the source. It applies to
the capture point used in the test. The renderer’s displayed sample rate
and exclusive-access status are useful setup checks.

## Generate the reference files

On macOS, run this from the repository root with Python 3 and `afconvert`
available:

```sh
python3 Tools/check_bitperfect.py generate /tmp/musirender-bitperfect
```

The directory must be new. It receives stereo PCM WAV references and their
lossless ALAC copies, at **44.1 kHz / 16 bit** and **96 kHz / 24 bit**. Each
file contains one second of low-level test noise with distinct left and right
samples. Turn down the DAC or amplifier before playing it.

## Capture and compare

1. Serve the ALAC file through the normal UPnP workflow. In MusiRender select
   the output under test and enable **Fixed digital volume**, **Match source
   sample rate** and **Exclusive audio output**.
2. Record the digital signal at the chosen measurement point. Capture both
   channels at the source rate and save an unprocessed stereo WAV. Start
   recording before Play and stop after the entire file has played.
3. Compare it with the PCM reference:

   ```sh
   python3 Tools/check_bitperfect.py compare \
     /tmp/musirender-bitperfect/96000Hz-24bit.wav capture.wav
   ```

The checker finds the reference start using the first 64 frames, then
compares the entire reference. Use `--offset N` to supply a known alignment
in capture frames if the marker itself was altered or occurs more than
once. Signed 16-, 24- and 32-bit WAV and 32- and 64-bit float WAV are
supported. It compares exact sample values across container widths without
resampling or rounding. A failure reports the first differing frame and
channel, or the reason the capture could not be compared.

## Interpreting the capture point

- An ALAC encode/decode round trip validates the reference and the decoder
  used for that check.
- An AVPlayer item’s post-effects audio tap measures the track inside the
  player. In a standalone AVQueuePlayer probe with player output muted, all
  44,100 stereo frames at 16 bit and all 96,000 stereo frames at 24 bit
  matched their references at this tap.
- A Core Audio process tap can measure samples in the host’s audio path.
  macOS requires system audio recording permission for that capture.
- To verify the cable to a MOJO 2 over USB, measure the USB audio payload
  before conversion. The MOJO 2 exposes digital inputs and analog outputs,
  so a headphone or microphone recording cannot verify its digital input
  samples. A loopback on a different digital output applies to that output.
