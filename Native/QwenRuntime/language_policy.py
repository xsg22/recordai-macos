"""Language policy shared by offline recognition, alignment and contract tests."""
import re

LANGUAGES = {'zh': 'Chinese', 'yue': 'Cantonese', 'en': 'English', 'ja': 'Japanese', 'auto': None}


def recognition_language(code):
    if code not in LANGUAGES:
        raise ValueError('Unsupported transcription language: ' + str(code))
    return LANGUAGES[code]


def alignment_language(code, text):
    # The aligner uses its Chinese character tokenizer for written Cantonese.
    if code == 'yue':
        return 'Chinese'
    explicit = recognition_language(code)
    if explicit:
        return explicit
    # The Chinese tokenizer supports mixed Latin words. Pure English needs its own word tokenizer.
    return 'Chinese' if re.search(r'[\u3400-\u4dbf\u4e00-\u9fff\U00020000-\U0002fa1f]', text) else 'English'
