import unittest
from evaluate_rag_utility import score, validated


class UtilityTest(unittest.TestCase):
    def fixture(self):
        q = dict(id='FAKE-Q', question='가상 질문', selectedUnitPolicy='unselected',
                 expectedBehavior='evidence_reference', reviewedAgainstOriginal=True,
                 goldEvidence=[dict(evidenceId='FAKE-E', file='가상.pdf', pdfPage=2)], mustRankFirst=['FAKE-E'])
        packet = dict(questions=[q], sourceCatalog=[dict(evidenceId='FAKE-E', sourceRef=dict(file='가상.pdf', page=2))])
        case = dict(id=q['id'], retrievedIds=['FAKE-E'],
                    retrievedSources=[dict(id='FAKE-E', sourceRef=dict(file='가상.pdf', page=2))],
                    ruleValuesUnchanged=True, summaryCitationIds=['FAKE-E'],
                    automaticGateAccepted=True, generationExecuted=True, summaryMode='extractive_summary',
                    retrievalOnlyMs=10, withSummaryMs=30)
        result = dict(status='passed', design='shared_retrieval_prefix', cases=[case], platform='test-fixture', physicalDevice=False)
        return packet, result

    def test_shared_gold_does_not_imply_human_adoption(self):
        packet, result = self.fixture()
        report = score(validated(packet), result)
        self.assertEqual(report['commonRetrieval']['hitAt5'], 1)
        self.assertEqual(report['automaticGateAdoption'], 1)
        self.assertIsNone(report['humanAdoption']['retrieval_plus_summary']['rate'])
        self.assertEqual(report['latencyMs']['retrieval_plus_summary']['p95'], 30)

    def test_wrong_page_and_missing_case_rejected(self):
        packet, result = self.fixture()
        result['cases'][0]['retrievedSources'][0]['sourceRef']['page'] = 3
        with self.assertRaises(ValueError):
            score(validated(packet), result)
        result['cases'] = []
        with self.assertRaises(ValueError):
            score(validated(packet), result)

    def test_unfilled_is_pending_not_zero_accuracy(self):
        report = score([], dict(status='passed', design='shared_retrieval_prefix', cases=[]))
        self.assertEqual(report['status'], 'awaiting_team_questions')
        self.assertIsNone(report['commonRetrieval']['hitAt5'])
        self.assertIsNone(report['automaticGateAdoption'])


if __name__ == '__main__':
    unittest.main()
