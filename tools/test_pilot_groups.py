import unittest
from pilot_groups import build_groups, similar


class GroupTest(unittest.TestCase):
    def test_vehicle_near_text_and_concept_links_are_transitive(self):
        rows = [
            dict(vehicle='DEMO-1', text='가상 엔진 오일필터 점검 후 교환', concepts=[]),
            dict(vehicle='demo 1', text='가상 냉각수 수위 확인', concepts=['FAKE']),
            dict(vehicle='DEMO-2', text='완전히 별개의 가상 전장 내용', concepts=['FAKE']),
            dict(vehicle='DEMO-3', text='가상 엔진 오일필터 점검 뒤 교환', concepts=[]),
            dict(vehicle='', text='별도 제동 부품', concepts=[]),
            dict(vehicle='', text='독립 현가 장치', concepts=[]),
        ]
        groups, pairs, info = build_groups(rows)
        self.assertEqual(len(set(groups[:4])), 1)
        self.assertNotEqual(groups[4], groups[5])
        self.assertIn((0, 3), pairs)
        self.assertEqual(info['missingVehicleRows'], 2)

    def test_empty_text_is_not_a_similar_pair(self):
        self.assertFalse(similar('', ''))


if __name__ == '__main__':
    unittest.main()
