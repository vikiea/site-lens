import json
import unittest

import read_android_startup_trace as trace


def record(phase, **extra):
    return trace.PREFIX + json.dumps({'phase': phase, 'kind': 'mark', 'elapsedUs': 10, **extra})


class StartupTraceTests(unittest.TestCase):
    def test_only_fixed_fields_are_accepted_and_other_log_lines_are_not_saved(self):
        rows = trace.parse_events('unrelated URL log\n' + record('appEntry'))
        self.assertEqual(len(rows), 1)
        for line in (record('appEntry', url='https://private.invalid'),
                     record('appEntry', itemCount=True), record('unrecognized'),
                     record([]), record('appEntry', kind=[]),
                     trace.PREFIX + 'not JSON'):
            with self.subTest(line=line), self.assertRaises(ValueError):
                trace.parse_events(line)

    def test_hot_restart_discards_previous_launch_even_with_the_same_pid(self):
        rows = trace.parse_events('\n'.join((record('appEntry'), record('controllerReady'), record('appEntry'))))
        self.assertEqual([row['phase'] for row in rows], ['appEntry'])
        self.assertFalse(trace.observation_complete(rows))

    def test_latest_launch_isolated_before_validating_incompatible_old_records(self):
        for stale in (record('oldVersionPhase'), record('controllerReady', oldField='not retained'), trace.PREFIX + 'broken'):
            with self.subTest(stale=stale):
                rows = trace.parse_events('\n'.join((stale, record('appEntry'), record('controllerReady'))))
                self.assertEqual([row['phase'] for row in rows], ['appEntry', 'controllerReady'])
                with self.assertRaises(ValueError):
                    trace.parse_events('\n'.join((record('appEntry'), stale)))

    def test_invalid_new_entry_cannot_reuse_a_previous_complete_launch(self):
        phases = ('appEntry', 'firstFrameworkFrame', 'persistentStateReady',
                  'savedTabsReady', 'homeMetadataFrameworkFrame', 'controllerReady')
        complete = '\n'.join(record(phase, **({'itemCount': 0} if phase == 'savedTabsReady' else {})) for phase in phases)
        complete += '\n' + trace.PREFIX + json.dumps({
            'phase': 'firstRasterFrame', 'kind': 'frameTiming', 'reportedAtUs': 20,
            'buildUs': 1, 'rasterUs': 2, 'totalUs': 3,
        })
        self.assertTrue(trace.observation_complete(trace.parse_events(complete)))
        for entry in (record('appEntry', itemCount=0), trace.PREFIX + json.dumps({
            'phase': 'appEntry', 'kind': 'span', 'startUs': 0, 'elapsedUs': 10,
            'durationUs': 10, 'succeeded': True,
        })):
            with self.subTest(entry=entry), self.assertRaisesRegex(ValueError, 'boundary'):
                trace.parse_events(complete + '\n' + entry + '\n' + record('bindingReady'))

    def test_existing_tabs_require_the_entry_frame_and_a_real_raster_timing(self):
        phases = ('appEntry', 'firstFrameworkFrame', 'persistentStateReady',
                  'savedTabsReady', 'homeMetadataFrameworkFrame', 'controllerReady')
        rows = trace.parse_events('\n'.join(record(phase, **({'itemCount': 1} if phase == 'savedTabsReady' else {})) for phase in phases))
        self.assertFalse(trace.observation_complete(rows))
        rows.append({'phase': 'firstRasterFrame', 'kind': 'frameTiming', 'reportedAtUs': 20,
                     'buildUs': 1, 'rasterUs': 2, 'totalUs': 3})
        self.assertFalse(trace.observation_complete(rows))
        rows.extend(trace.parse_events(record('resumeEntryFrameworkFrame', itemCount=1)))
        self.assertTrue(trace.observation_complete(rows))
        without_count = [dict(row) for row in rows]
        next(row for row in without_count if row['phase'] == 'savedTabsReady').pop('itemCount')
        self.assertFalse(trace.observation_complete(without_count))

    def test_no_tabs_do_not_require_a_nonexistent_entry_and_failed_spans_remain_visible(self):
        phases = ('appEntry', 'firstFrameworkFrame', 'persistentStateReady',
                  'savedTabsReady', 'homeMetadataFrameworkFrame', 'controllerReady')
        rows = trace.parse_events('\n'.join(record(phase, **({'itemCount': 0} if phase == 'savedTabsReady' else {})) for phase in phases))
        rows.append({'phase': 'firstRasterFrame', 'kind': 'frameTiming', 'reportedAtUs': 20,
                     'buildUs': 1, 'rasterUs': 2, 'totalUs': 3})
        rows.append({'phase': 'nativeDownloadReconcile', 'kind': 'span', 'startUs': 1,
                     'elapsedUs': 11, 'durationUs': 10, 'succeeded': False})
        self.assertTrue(trace.observation_complete(rows))
        self.assertFalse(trace.summarize(rows)['spansByDurationMs'][0]['succeeded'])


if __name__ == '__main__':
    unittest.main()
