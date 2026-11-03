# Vorbis test vectors

These files are made for Chorus from synthetic signals (sines, noise, impulses, a square wave and silence). They hold no third party audio. They are released under CC0.

Each `.ogg` was encoded with libvorbis 1.3.7 through FFmpeg 9.0.1, from an `aevalsrc` signal, with:

```
ffmpeg -f lavfi -i "aevalsrc=exprs=<expr>:s=<rate>:d=<seconds>" -ac <channels> \
  -c:a libvorbis -q:a <quality> -map_metadata -1 -fflags +bitexact \
  -serial_offset <serial> -page_duration 20000 <name>.ogg
```

Each `.f32` is the libvorbis decode (`ffmpeg -c:a libvorbis -i <name>.ogg -f f32le`), interleaved little endian f32, with only every 32nd frame kept (frames 0, 32, 64 and so on).

| File | Rate | Channels | Quality | Frames | Signal |
| --- | --- | --- | --- | --- | --- |
| mono8k | 8000 | 1 | 0 | 8000 | 300 Hz sine and noise |
| stereo44 | 44100 | 2 | 4 | 44100 | two sines and noise per channel |
| noise48 | 48000 | 2 | 10 | 24000 | white noise |
| surround48 | 48000 | 6 | 3 | 24000 | one sine per channel, in Vorbis order |
| impulse22 | 22050 | 1 | -1 | 22050 | impulse train every 0.125 s |
| short44 | 44100 | 2 | 4 | 100 | two sines (no reference, shorter than one block) |
| silence44 | 44100 | 2 | 4 | 22050 | silence |
| square32 | 32000 | 2 | 6 | 16000 | full scale square waves |
| chain | 44100, 22050 | 2, 1 | 2 | 22050 + 11025 | two links, references in linka.f32 and linkb.f32 |
