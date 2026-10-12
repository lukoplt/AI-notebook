import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2] / "Tests/fixtures/contracts"
TYPES = ["ollama", "anthropic", "openai", "openai_compatible", "openwebui"]
presets = [
    ("lmstudio", "LM Studio", "http://localhost:1234/v1", "providerPresetLocalHelp"),
    ("openrouter", "OpenRouter", "https://openrouter.ai/api/v1", "providerPresetRemoteHelp"),
    ("vllm", "vLLM", "http://localhost:8000/v1", "providerPresetLocalHelp"),
    ("groq", "Groq", "https://api.groq.com/openai/v1", "providerPresetRemoteHelp"),
    ("mistral", "Mistral", "https://api.mistral.ai/v1", "providerPresetRemoteHelp"),
    ("together", "Together", "https://api.together.ai/v1", "providerPresetRemoteHelp"),
    ("custom", "Custom", "", "providerPresetCustomHelp"),
]
files = {"presets": [dict(name=i, label=n, baseURL=u, helpKey=h,
                           type="openai_compatible") for i, n, u, h in presets]}
files["options"] = [dict(name=t, type=t, runtimeContext=4096, maxOutputTokens=333,
    expected={"options": {"num_ctx": 4096, "num_predict": 333}} if t == "ollama"
             else {"max_tokens": 333}) for t in TYPES]
files["limits"] = [
    dict(name="unknown", type="openai_compatible", model="unlisted", window=None,
         expected=dict(contextWindow=None, runtimeContext=8192, maxOutputTokens=1024, source="auto", isAssumed=True)),
    dict(name="known-openai", type="openai", model="gpt-4o-mini", window=None,
         expected=dict(contextWindow=128000, runtimeContext=8192, maxOutputTokens=1024, source="auto", isAssumed=False)),
    dict(name="known-snapshot", type="openai", model="gpt-4o-mini-2024-07-18", window=None,
         expected=dict(contextWindow=128000, runtimeContext=8192, maxOutputTokens=1024, source="auto", isAssumed=False)),
    dict(name="no-prefix-guess", type="openai", model="gpt-4o-mini-custom", window=None,
         expected=dict(contextWindow=None, runtimeContext=8192, maxOutputTokens=1024, source="auto", isAssumed=True)),
    dict(name="no-compatible-guess", type="openai_compatible", model="gpt-4o-mini", window=None,
         expected=dict(contextWindow=None, runtimeContext=8192, maxOutputTokens=1024, source="auto", isAssumed=True)),
    dict(name="ollama-large", type="ollama", model="m:tag", window=32768,
         show={"model_info":{"general.architecture":"llama", "llama.context_length":32768}},
         expected=dict(contextWindow=32768, runtimeContext=8192, maxOutputTokens=1024, source="auto", isAssumed=False)),
    dict(name="ollama-small", type="ollama", model="m", window=4096,
         show={"model_info":{"general.architecture":"llama", "llama.context_length":4096}},
         expected=dict(contextWindow=4096, runtimeContext=4096, maxOutputTokens=1024, source="auto", isAssumed=False)),
    dict(name="ollama-tiny", type="ollama", model="m", window=512,
         expected=dict(contextWindow=512, runtimeContext=512, maxOutputTokens=511, source="auto", isAssumed=False)),
    dict(name="ollama-no-metadata", type="ollama", model="m", window=None, show={"model_info":{}},
         expected=dict(contextWindow=None, runtimeContext=8192, maxOutputTokens=1024, source="auto", isAssumed=True)),
]
for name, window, runtime, output in [
    ("zero-runtime", None, 0, 1), ("zero-output", None, 4096, 0),
    ("no-input-budget", None, 1024, 1024), ("above-window", 4096, 8192, 1024),
    ("negative-window", -1, 8192, 1024)]:
    files["limits"].append(dict(name=name, type="ollama", model="m", window=window,
        user=dict(runtimeContext=runtime, maxOutputTokens=output), expectedError="invalidLimits"))
probe_rows = [
    ("empty", 200, "validEmpty", "verified", None),
    ("one", 200, "validOne", "verified", None),
    ("not-found", 404, "error", "listingUnsupported", None),
    ("method", 405, "error", "listingUnsupported", None),
    ("not-implemented", 501, "error", "listingUnsupported", None),
    ("unauthorized", 401, "error", "failed", "auth"),
    ("forbidden", 403, "error", "failed", "auth"),
    ("rate-limit", 429, "error", "failed", "http"),
    ("server", 500, "error", "failed", "http"),
    ("malformed", 200, "malformed", "failed", "decoding"),
    ("connection", 0, "transport", "failed", "transport"),
]
files["probe"] = [dict(name=f"{t}-{n}", type=t, statusCode=s, response=r,
    expectedStatus=e, errorCode=c, generationVerified=False)
    for t in TYPES for n, s, r, e, c in probe_rows]
files["routing"] = [
    dict(name="capture-and-rotate", operation="snapshot", type="openai_compatible",
         providerId="p", oldRoot="https://old.example/proxy/v1", newRoot="https://new.example/gw/v1",
         oldKey="key-A", newKey="key-B", oldModel="model:old", newModel="model:new",
         oldContext=4096, newContext=8192, oldOutput=333, newOutput=777,
         expectedAttempts=["old", "old", "new"]),
    *[dict(name=f"privacy-{t}-{op}", operation=op, type=t,
           acknowledged=False, expectedError="consentRequired", expectedRequests=0)
      for t in TYPES if t != "ollama" for op in ["chat", "backgroundEmbed"]],
    *[dict(name=f"unsupported-embed-{t}", operation="embed", type=t,
           acknowledged=True, expectedError="unsupportedEndpoint", expectedRequests=0)
      for t in ["anthropic", "openwebui"]],
    dict(name="missing", operation="chat", type="openai", missing=True,
         expectedError="missingProvider", expectedRequests=0),
    dict(name="disabled", operation="chat", type="openai", enabled=False,
         expectedError="disabledProvider", expectedRequests=0),
    dict(name="custom-ollama", operation="ollamaEndpoints", type="ollama",
         root="http://gpu-box:11434/proxy/ollama", paths=["api/chat", "api/embed", "api/tags", "api/show"]),
]
files["systems"] = [dict(name=t, type=t,
    input=[dict(role="system", content="RULES"), dict(role="system", content="I"),
           dict(role="user", content="q1"), dict(role="assistant", content="a1"),
           dict(role="user", content="Q2")],
    expected=dict(system="RULES\n\nI", messages=[dict(role="user", content="q1"),
        dict(role="assistant", content="a1"), dict(role="user", content="Q2")]) if t == "anthropic"
    else dict(messages=[dict(role="system", content="RULES\n\nI"),
        dict(role="user", content="q1"), dict(role="assistant", content="a1"), dict(role="user", content="Q2")]))
    for t in TYPES]
files["store"] = [
    dict(name="user-survives-auto", providerId="p", model="m:tag", contextWindow=32768,
         runtimeContext=4096, maxOutputTokens=333, source="user", autoRuntime=8192,
         expectedRuntime=4096),
    dict(name="provider-isolation", providerIds=["p", "q"], model="m:tag", runtimes=[4096,8192]),
    dict(name="delete-cascades", providerId="p", model="m", expectedRows=0),
    dict(name="reset-auto", providerId="p", model="m", expectedSource="auto", expectedRuntime=8192),
    dict(name="legacy-openai", type="openai", before="https://api.openai.com/", after="https://api.openai.com/v1"),
    dict(name="legacy-versioned", type="openai_compatible", before="https://gw.example/v1/", after="https://gw.example/v1"),
    dict(name="legacy-prefix", type="openai_compatible", before="https://gw.example/proxy", after="https://gw.example/proxy/v1"),
    dict(name="new-versionless", type="openai_compatible", before="https://gw.example/proxy", after="https://gw.example/proxy"),
]
for name, after_type, after_root, retained in [
    ("root-change", "ollama", "https://new.example/proxy/v1", False),
    ("endpoint-version-change", "ollama", "https://old.example/proxy/v2", False),
    ("type-change", "openai_compatible", "https://old.example/proxy/v1", False),
    ("equivalent-root", "ollama", " https://old.example/proxy/v1/// ", True),
    ("display-only-change", "ollama", "https://old.example/proxy/v1", True),
]:
    files["store"].append(dict(name="limits-" + name, operation="providerUpdate",
        providerId="p", otherProviderId="q", model="m:tag",
        before=dict(type="ollama", baseURL="https://old.example/proxy/v1"),
        after=dict(type=after_type, baseURL=after_root), contextWindow=32768,
        runtimeContext=4096, maxOutputTokens=333, expectedAutoRetained=retained,
        refreshedWindow=2048, expectedRefreshedRuntime=2048))
for new_cache in ["empty", "auto", "user"]:
    files["store"].append(dict(name="limits-inflight-root-change-" + new_cache,
        operation="inflightEndpointChange", providerId="p", model="m:tag",
        oldRoot="https://old.example/proxy/v1", newRoot="https://new.example/proxy/v2",
        oldWindow=32768, newWindow=2048, newCache=new_cache,
        expectedCapturedWindow=2048 if new_cache == "user" else 32768,
        expectedCachedWindow=None if new_cache == "empty" else 2048,
        expectedNewRuntime=2048))
for name, value in [("one", 1), ("zero", 0), ("negative", -1), ("fraction", 1.5),
                    ("boolean", True), ("overflow", 2147483648)]:
    files["limits"].append(dict(name="show-invalid-" + name, type="ollama", model="m", window=None,
        show={"model_info":{"general.architecture":"llama", "llama.context_length":value}},
        expected=dict(contextWindow=None, runtimeContext=8192, maxOutputTokens=1024, source="auto", isAssumed=True)))
files["limits"].append(dict(name="show-other-architecture", type="ollama", model="m", window=None,
    show={"model_info":{"general.architecture":"llama", "bert.context_length":32768}},
    expected=dict(contextWindow=None, runtimeContext=8192, maxOutputTokens=1024, source="auto", isAssumed=True)))
files["errors"] = [dict(name=f"{t}-{name}", type=t, statusCode=status, body=body, expectedError=error)
    for t in TYPES for name, status, body, error in [
        ("context", 400, {"error":{"code":"context_length_exceeded", "message":"too long"}}, "contextTooLong"),
        ("payload", 413, {"error":"request too large"}, "contextTooLong"),
        ("other-bad-request", 400, {"error":{"code":"invalid_model", "message":"unknown model"}}, "http")]]
files["errors"].append(dict(name="anthropic-prompt-too-long", type="anthropic", statusCode=400,
    body={"error":{"type":"invalid_request_error", "message":"prompt is too long: 9000 tokens"}}, expectedError="contextTooLong"))
parser = argparse.ArgumentParser()
parser.add_argument("--check", action="store_true")
args = parser.parse_args()
for suffix, cases in files.items():
    path = ROOT / f"provider-{suffix}-v1.json"
    blob = (json.dumps(dict(contract=f"provider-{suffix}", version=1, cases=cases),
                       ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    if args.check:
        assert path.read_bytes() == blob, f"stale fixture: {path.name}"
    else:
        path.write_bytes(blob)
print("WP2 provider fixtures: 8 files verified" if args.check else "WP2 provider fixtures: 8 files written")
