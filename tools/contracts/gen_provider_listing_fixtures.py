#!/usr/bin/env python3
"""provider-listing-limits-v1 reference: context windows from OpenWebUI / OpenAI-compatible model listings.

The app assumed 8 192 tokens for every OpenWebUI / OpenAI-compatible model because only Ollama's
/api/show was read. Many servers already advertise the window in the model listing the app fetches
for discovery (vLLM `max_model_len`, OpenRouter/Together `context_length`, LM Studio
`max_context_length`, Groq `context_window`, LiteLLM `max_input_tokens`, OpenWebUI custom model
`info.params.num_ctx` and the proxied upstream item under `openai`). Normative text:
docs/contracts/provider-listing-limits-v1.md. Swift `ProviderLimitPolicy.contextWindow(fromModelListing:model:)`
/ `automatic(..., listed:)` and C# `ProviderLimitPolicy.ContextWindowFromModelListing` / `Automatic(..., listed)`
must reproduce every case. Standard library only.
"""

import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = 'Tests/fixtures/contracts/provider-listing-limits-v1.json'

DEFAULT_RUNTIME = 8192
DEFAULT_OUTPUT = 1024
LISTED_RUNTIME_CAP = 32768
LISTING_TYPES = ('openwebui', 'openai_compatible')

# Ordered: the first path holding a valid integer wins; invalid values are skipped.
KEY_PATHS = [
    ['context_length'], ['max_model_len'], ['max_context_length'], ['context_window'], ['max_input_tokens'],
    ['top_provider', 'context_length'], ['info', 'params', 'num_ctx'],
    ['openai', 'context_length'], ['openai', 'max_model_len'], ['openai', 'max_context_length'],
    ['openai', 'context_window'], ['openai', 'max_input_tokens'],
]


def valid_window(value):
    return isinstance(value, int) and not isinstance(value, bool) and 2 <= value <= 2 ** 31 - 1


def window_from_item(item):
    for path in KEY_PATHS:
        value = item
        for key in path:
            value = value.get(key) if isinstance(value, dict) else None
        if valid_window(value):
            return value
    return None


def window_from_listing(text, model):
    """None when unknown; raises ValueError for malformed JSON (callers treat any failure as unknown)."""
    root = json.loads(text)
    data = root.get('data') if isinstance(root, dict) else None
    if not isinstance(data, list):
        return None
    for item in data:
        if isinstance(item, dict) and item.get('id') == model:
            return window_from_item(item)
    return None


def automatic(ptype, window, listed):
    """folder-rag-v1 limits (provider-limits-v1) plus the listed-window rule for remote listing types."""
    if listed and window is not None and ptype in LISTING_TYPES:
        runtime = min(window, LISTED_RUNTIME_CAP)
    else:
        runtime = min(DEFAULT_RUNTIME, window if window is not None else DEFAULT_RUNTIME)
    return {'contextWindow': window, 'runtimeContext': runtime, 'maxOutputTokens': min(DEFAULT_OUTPUT, runtime - 1),
            'source': 'auto', 'isAssumed': window is None}


def item(model, **fields):
    return dict({'id': model, 'object': 'model', 'owned_by': 'unit'}, **fields)


M = 'example-org/Example-Chat-3.5-128B'

CASES = [
    ('vllm-max-model-len', 'openai_compatible', M, {'object': 'list', 'data': [item('other', max_model_len=4096),
                                                                               item(M, max_model_len=131072)]}),
    ('openrouter-context-length', 'openai_compatible', M, {'data': [item(M, context_length=65536,
                                                                         top_provider={'context_length': 32768})]}),
    ('lmstudio-max-context-length', 'openai_compatible', M, {'data': [item(M, max_context_length=16384)]}),
    ('groq-context-window', 'openai_compatible', M, {'data': [item(M, context_window=8192)]}),
    ('litellm-max-input-tokens', 'openai_compatible', M, {'data': [item(M, max_input_tokens=200000)]}),
    ('openrouter-top-provider-only', 'openai_compatible', M, {'data': [item(M, top_provider={'context_length': 40960})]}),
    ('openwebui-num-ctx', 'openwebui', M, {'data': [item(M, name='Example Chat', info={'params': {'num_ctx': 24576}},
                                                         openai={'id': M, 'max_model_len': 131072})]}),
    ('openwebui-proxied-upstream', 'openwebui', M, {'data': [item(M, name='Example Chat', connection_type='external',
                                                                  openai={'id': M, 'object': 'model', 'max_model_len': 131072})]}),
    ('openwebui-ollama-no-metadata', 'openwebui', 'llama3:8b', {'data': [item('llama3:8b', name='llama3',
                                                                              ollama={'name': 'llama3:8b', 'details': {}})]}),
    ('small-window-below-default', 'openai_compatible', M, {'data': [item(M, max_model_len=4096)]}),
    ('tiny-window', 'openai_compatible', M, {'data': [item(M, max_model_len=512)]}),
    ('invalid-values-skipped', 'openai_compatible', M, {'data': [item(M, context_length=True, max_model_len=131072.5,
                                                                      max_context_length='32768', context_window=1,
                                                                      max_input_tokens=2 ** 31, info={'params': {'num_ctx': 12288}})]}),
    ('exact-id-only', 'openai_compatible', M, {'data': [item(M.lower(), max_model_len=131072), item(M + ':latest', max_model_len=4096)]}),
    ('first-matching-item', 'openai_compatible', M, {'data': [item(M), item(M, max_model_len=131072)]}),
    ('no-data-array', 'openai_compatible', M, {'models': [item(M, max_model_len=131072)]}),
    ('data-not-list', 'openwebui', M, {'data': {'id': M, 'max_model_len': 131072}}),
    ('top-level-array', 'openai_compatible', M, [item(M, max_model_len=131072)]),
    ('openai-type-not-listed', 'openai', 'gpt-4.1', {'data': [item('gpt-4.1', context_length=1047576)]}),
]

MALFORMED = [
    ('malformed-json', 'openai_compatible', M, '{"data": ['),
]


def build():
    cases = []
    for name, ptype, model, listing in CASES:
        text = json.dumps(listing, ensure_ascii=False, sort_keys=True)
        window = window_from_listing(text, model) if ptype in LISTING_TYPES else None
        cases.append({'name': name, 'type': ptype, 'model': model, 'listing': text,
                      'expected': {'window': window, 'limits': automatic(ptype, window, listed=True)}})
    for name, ptype, model, text in MALFORMED:
        try:
            window_from_listing(text, model)
            raise AssertionError('malformed listing parsed: ' + name)
        except ValueError:
            pass
        cases.append({'name': name, 'type': ptype, 'model': model, 'listing': text,
                      'expected': {'error': 'decoding', 'limits': automatic(ptype, None, listed=True)}})
    # The frozen provider-limits-v1 policy is unchanged for unlisted windows (Ollama show, known OpenAI table).
    assert automatic('ollama', 32768, listed=False)['runtimeContext'] == 8192
    assert automatic('openai', 128000, listed=False)['runtimeContext'] == 8192
    return {'contract': 'provider-listing-limits', 'version': 1, 'listedRuntimeCap': LISTED_RUNTIME_CAP,
            'listingTypes': list(LISTING_TYPES), 'keyPaths': KEY_PATHS, 'cases': cases}


def render(fixture):
    return (json.dumps(fixture, ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False) + '\n').encode('utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Compare generated bytes without writing.')
    args = parser.parse_args()
    path, data = ROOT / OUTPUT, render(build())
    if args.check:
        if not path.is_file() or path.read_bytes() != data:
            print('out of date: ' + OUTPUT)
            return 1
        print('ok')
        return 0
    path.write_bytes(data)
    print('wrote ' + OUTPUT)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
