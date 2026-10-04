# Bundled demo clips

Drop ElevenLabs `.mp3` clips here to bundle them into the app — they
resolve keyless, so a recorded demo scene plays real audio on a judge's
device without `ELEVENLABS_API_KEY` or network.

Filename convention: `md5("<text>|<duration_seconds_or_0>|<loop>").mp3`
— the exact filename the on-device `sfx_cache` uses, so after a live
run you can copy files verbatim from the app's documents directory
(`sfx_cache/`) into this folder. Compute manually:

```
echo -n "campfire crackling|6|true" | md5
```

The recorded scene specs live in `lib/src/director/demo_pack.dart`.
