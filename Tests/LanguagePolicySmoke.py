import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('policy', ROOT / 'Native/QwenRuntime/language_policy.py')
policy = importlib.util.module_from_spec(spec); spec.loader.exec_module(policy)


class LanguagePolicyTests(unittest.TestCase):
    def test_automatic_english_uses_english_word_alignment(self):
        self.assertEqual(policy.alignment_language('auto', "Don't translate TalkTuck, version 0.17!"), 'English')
    def test_chinese_and_code_switching_keep_bilingual_tokenization(self):
        for text in ['离线转录', '今天 review TalkTuck version 0.17。', '𠀀']:
            self.assertEqual(policy.alignment_language('auto', text), 'Chinese')
    def test_explicit_language_is_respected(self):
        self.assertEqual(policy.alignment_language('en', 'TalkTuck 中文品牌'), 'English')
        self.assertEqual(policy.alignment_language('zh', 'TalkTuck'), 'Chinese')
        self.assertIsNone(policy.recognition_language('auto'))
    def test_cantonese_recognition_uses_cantonese_not_mandarin(self):
        self.assertEqual(policy.recognition_language('yue'), 'Cantonese')
    def test_cantonese_alignment_uses_character_tokenization(self):
        self.assertEqual(policy.alignment_language('yue', '我哋今日開會，用 TalkTuck 記低。'), 'Chinese')
    def test_unknown_language_does_not_silently_fall_back(self):
        with self.assertRaises(ValueError): policy.recognition_language('unsupported')


if __name__ == '__main__': unittest.main()
