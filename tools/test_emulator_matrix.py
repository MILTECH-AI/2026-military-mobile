import unittest
from summarize_emulator_matrix import paired_memory, stats


class MatrixTest(unittest.TestCase):
    def test_nearest_rank_and_insufficient_empty(self):
        result = stats(list(range(1, 11)))
        self.assertEqual(result['p50'], 5)
        self.assertEqual(result['p95'], 10)
        self.assertEqual(stats([])['n'], 0)
        self.assertIsNone(stats([])['p95'])

    def test_only_same_window_sum_never_independent_maxima(self):
        def sample(ui, worker):
            return dict(validPair=True, samePhase=True, ui=dict(pssKb=ui),
                        worker=dict(pssKb=worker, threads=2), pairedTotalPssKb=ui+worker,
                        phaseStart='fixture', windowMs=1, midpointSkewMs=.2)
        flow = dict(memory=dict(samples=[sample(100, 500), sample(300, 200)]))
        result = paired_memory(flow)
        self.assertEqual(result['sampledPeakMiB'], 600/1024)
        self.assertNotEqual(result['sampledPeakMiB'], 800/1024)
        flow['memory']['samples'][0]['pairedTotalPssKb'] = 800
        with self.assertRaises(ValueError):
            paired_memory(flow)


if __name__ == '__main__':
    unittest.main()
