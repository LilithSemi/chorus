# Opus test files

These files are made for Chorus from synthetic signals. They hold no third party audio. They are released under CC0.

The signals come from FFmpeg 9.0.1 `aevalsrc`, 16 bit:

- speech: a 140 Hz tone with three harmonics, a pitch glide of 40 Hz at 0.7 Hz, and a 3 Hz syllable envelope.
- speech2: a 210 Hz tone with two harmonics, a pitch glide of 40 Hz at 1 Hz, and a 2.5 Hz envelope.
- music: three sines and a little noise per channel.
- surround: one sine per channel.

## FEC files

These were encoded with libopus 1.6.1 through FFmpeg 9.0.1, with in-band FEC on, so most SILK frames carry LBRR data:

```
ffmpeg -i <in>.wav -c:a libopus -b:a <rate> -application voip -fec 1 -packet_loss 20 \
  -frame_duration 20 -vbr off <name>.opus
```

| File | Channels | Signal | Bitrate | Packets | Packets with LBRR |
| --- | --- | --- | --- | --- | --- |
| fec_mono | 1 | speech, 48000 Hz, 3 s | 24 kbps | 151 | 108 |
| fec_stereo | 2 | speech and speech2, 48000 Hz, 3 s | 32 kbps | 151 | 124 |

## Ogg Opus files

These were encoded with opusenc from opus-tools 0.2 (libopus 1.6.1, libopusenc 0.3), with:

```
opusenc --serial <serial> --comp 10 <args> <name>.wav <name>.opus
```

Each `.f32` is the FFmpeg libopus decode (`ffmpeg -c:a libopus -i <name>.opus -f f32le`), interleaved little endian f32, with only every 32nd frame kept (frames 0, 32, 64 and so on). The frame counts are after pre-skip and end trim. FFmpeg and opusdec give the same counts.

| File | Channels | Input | Args | Frames | Notes |
| --- | --- | --- | --- | --- | --- |
| mono16k | 1 | speech, 16000 Hz, 1.0123 s | `--bitrate 16` | 48591 | input rate 16000 in OpusHead, end trim |
| stereo48 | 2 | music, 48000 Hz, 1 s | `--bitrate 96` | 48000 | |
| surround51 | 6 | surround, 48000 Hz, 0.5 s | `--bitrate 192` | 24000 | family 1, 4 streams, 2 coupled |
| frames60 | 1 | speech, 48000 Hz, 1 s | `--bitrate 24 --framesize 60` | 48000 | 60 ms packets |
| short | 1 | 440 Hz sine, 48000 Hz, 0.002 s | `--bitrate 64` | 96 | shorter than pre-skip, no reference |
| chain | 2, then 1 | music at 44100 Hz, then speech at 8000 Hz, 0.5 s each | `--bitrate 64 --framesize 10`, then `--bitrate 12` | 24000 + 24000 | two links, serials 26 and 27, references in chain_a.f32 and chain_b.f32 |
