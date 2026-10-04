/// Recorded Gemma runs bundled so the app demos end-to-end with no
/// Render endpoint and no ElevenLabs key. Each spec below is the real
/// output shape a `describe` run produces — same fields
/// [SceneDirector.parseSpec] round-trips. Played keyless, every source
/// falls back to its procedural stand-in (`kind`), so radar, meters,
/// motion, and the scene score all still work; with a key the same
/// specs generate real clips via the `sound` text.
///
/// These are demo fixtures — label them "recorded" wherever shown.
const demoScenes = <Map<String, Object?>>[
  {
    'prompt': 'sitting in a cave in front of a fire — kids playing '
        'behind me, then a breeze comes and the fire goes out',
    'recorded': true,
    'spec': {
      'environment': 'cave',
      'sources': [
        {
          'name': 'fire',
          'kind': 'noise',
          'az': 0.0,
          'el': 0.0,
          'dist': 0.9,
          'gain': 0.9,
          'sound': 'campfire crackling',
          'loop': true,
          'duration_s': 6.0,
          'delay_s': 0.0,
          'end_s': 14.0,
        },
        {
          'name': 'kids',
          'kind': 'noise',
          'az': 180.0,
          'el': 0.0,
          'dist': 3.0,
          'gain': 0.7,
          'sound': 'children playing and laughing',
          'loop': true,
          'duration_s': 8.0,
          'delay_s': 0.0,
          'motion': {
            'wander': {
              'anchor_az': 180.0,
              'anchor_el': 0.0,
              'anchor_dist': 3.0,
              'az_span': 80.0,
              'dist_span': 1.5,
              'period_s': 9.0,
            }
          },
        },
        {
          'name': 'breeze',
          'kind': 'rain',
          'az': 0.0,
          'el': 0.0,
          'dist': 2.0,
          'gain': 0.5,
          'sound': 'cold wind gust',
          'loop': true,
          'duration_s': 6.0,
          'delay_s': 8.0,
          'motion': {
            'approach': {
              'from_az': -60.0,
              'from_dist': 8.0,
              'seconds': 10.0,
            }
          },
        },
        {
          'name': 'fire_end',
          'kind': 'noise',
          'az': 0.0,
          'el': 0.0,
          'dist': 0.9,
          'gain': 0.8,
          'sound': 'fire extinguishing hiss',
          'loop': false,
          'duration_s': 2.0,
          'delay_s': 14.0,
        },
      ],
    },
  },
  {
    'prompt': 'rain everywhere, a bee circling my head, thunder '
        'behind me later',
    'recorded': true,
    'spec': {
      'environment': 'rainy afternoon',
      'sources': [
        {
          'name': 'rain',
          'kind': 'rain',
          'az': 0.0,
          'el': 10.0,
          'dist': 2.5,
          'gain': 0.8,
          'sound': 'steady rain on leaves',
          'loop': true,
          'duration_s': 8.0,
          'delay_s': 0.0,
        },
        {
          'name': 'bee',
          'kind': 'bee',
          'az': 0.0,
          'el': 5.0,
          'dist': 0.8,
          'gain': 0.7,
          'sound': 'bee buzzing close',
          'loop': true,
          'duration_s': 4.0,
          'delay_s': 2.0,
          'motion': {
            'orbit': {
              'radius': 0.8,
              'period_s': 6.0,
            }
          },
        },
        {
          'name': 'thunder',
          'kind': 'noise',
          'az': -120.0,
          'el': 20.0,
          'dist': 6.0,
          'gain': 0.9,
          'sound': 'distant thunder rumble',
          'loop': false,
          'duration_s': 3.0,
          'delay_s': 9.0,
        },
      ],
    },
  },
  {
    'prompt': 'waves at my feet, a loon calls far to my left, a gull '
        'crosses overhead',
    'recorded': true,
    'spec': {
      'environment': 'lakeside dusk',
      'sources': [
        {
          'name': 'waves',
          'kind': 'rain',
          'az': 0.0,
          'el': -5.0,
          'dist': 3.0,
          'gain': 0.7,
          'sound': 'ocean waves lapping',
          'loop': true,
          'duration_s': 8.0,
          'delay_s': 0.0,
        },
        {
          'name': 'loon',
          'kind': 'tone',
          'az': 90.0,
          'el': 0.0,
          'dist': 5.0,
          'gain': 0.6,
          'sound': 'loon call across the lake',
          'loop': false,
          'duration_s': 3.0,
          'delay_s': 4.0,
        },
        {
          'name': 'gull',
          'kind': 'bee',
          'az': -90.0,
          'el': 25.0,
          'dist': 4.0,
          'gain': 0.5,
          'sound': 'seagull passing overhead',
          'loop': false,
          'duration_s': 5.0,
          'delay_s': 7.0,
          'motion': {
            'traverse': {
              'from_az': 90.0,
              'to_az': -90.0,
              'dist': 4.0,
              'seconds': 6.0,
            }
          },
        },
      ],
    },
  },
];
