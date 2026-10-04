#!/usr/bin/env python3
"""Exercise a RUNNING local provider. No fake backend, filesystem tool or shell tool.

The optional probe tool is a real pure identity function over a random nonce.
Results validate this small protocol interaction, not general model/code quality.
"""
from __future__ import annotations
import argparse
import http.client
import json
import os
import secrets
import sys
from typing import Any


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--model", required=True)
    parser.add_argument("--api", choices=("chat", "responses", "messages"), default="responses")
    parser.add_argument("--token-env", default="APPLELOCALAI_TOKEN")
    parser.add_argument("--tools", action="store_true")
    args = parser.parse_args()
    token = os.environ.get(args.token_env)
    if not token:
        parser.error(f"Set {args.token_env}; the credential is not accepted on the command line")
    if not 1024 <= args.port <= 65535:
        parser.error("port must be in 1024...65535")
    paths = {"chat": "/v1/chat/completions", "responses": "/v1/responses", "messages": "/v1/messages"}

    def request(method: str, path: str, payload: Any = None, *, auth: bool = True) -> tuple[int, bytes]:
        conn = http.client.HTTPConnection("127.0.0.1", args.port, timeout=310)
        headers = {"Content-Type": "application/json"}
        if auth:
            headers["Authorization"] = f"Bearer {token}"
        body = None if payload is None else json.dumps(payload, ensure_ascii=False).encode()
        try:
            conn.request(method, path, body=body, headers=headers)
            response = conn.getresponse()
            # A bounded synthetic probe. A runaway response is not silently truncated.
            data = response.read(5 * 1024 * 1024 + 1)
            if len(data) > 5 * 1024 * 1024:
                raise RuntimeError("Probe response exceeded 5 MiB")
            return response.status, data
        finally:
            conn.close()

    status, _ = request("GET", "/health", auth=False)
    if status != 401:
        raise RuntimeError(f"Unauthenticated request was not rejected: {status}")
    status, listing = request("GET", "/v1/models")
    if status != 200 or args.model not in {item["id"] for item in json.loads(listing)["data"]}:
        raise RuntimeError("Requested explicit model profile is not registered")
    base: dict[str, Any] = {"model": args.model, "stream": False}
    key = "input" if args.api == "responses" else "messages"
    user = {"role": "user", "content": "Reply with a short greeting."}
    base[key] = [user]
    if args.api == "messages":
        base["max_tokens"] = 256
    status, data = request("POST", paths[args.api], base)
    if status != 200:
        raise RuntimeError(f"Real generation failed, HTTP {status}: {data.decode(errors='replace')[:800]}")
    body = json.loads(data)
    if "error" in body and body["error"] is not None:
        raise RuntimeError("Generation returned an error object")
    if args.api == "chat":
        text = body["choices"][0]["message"].get("content", "")
    elif args.api == "messages":
        text = "".join(block["text"] for block in body["content"] if block["type"] == "text")
    else:
        text = "".join(part["text"] for item in body["output"] if item["type"] == "message" for part in item["content"] if part["type"] == "output_text")
    if not text.strip():
        raise RuntimeError("Real model did not return nonempty text")

    streaming = {**base, "stream": True}
    status, stream = request("POST", paths[args.api], streaming)
    if status != 200:
        raise RuntimeError(f"Streaming failed, HTTP {status}")
    payloads = []
    done = 0
    for line in stream.decode().splitlines():
        if not line.startswith("data: "):
            continue
        value = line[6:]
        if value == "[DONE]":
            done += 1
        else:
            payloads.append(json.loads(value))
    if any(p.get("error") or p.get("type") in {"error", "response.failed"} for p in payloads):
        raise RuntimeError("Stream contains failure; not a successful terminal")
    if args.api == "responses":
        seq = [p["sequence_number"] for p in payloads]
        if seq != list(range(len(seq))) or sum(p.get("type") == "response.completed" for p in payloads) != 1:
            raise RuntimeError("Responses stream terminal/sequence contract failed")
    elif args.api == "messages":
        if sum(p.get("type") == "message_stop" for p in payloads) != 1:
            raise RuntimeError("Messages did not terminate exactly once")
    elif done != 1:
        raise RuntimeError("Chat stream did not terminate exactly once")

    if args.tools:
        nonce = secrets.token_hex(8)
        schema = {"type": "object", "properties": {"nonce": {"type": "string"}}, "required": ["nonce"], "additionalProperties": False}
        tool = {"name": "identity_probe", "description": "Return the nonce supplied as the nonce argument.", "parameters": schema}
        first = {**base, key: [{"role": "user", "content": f"Call identity_probe with nonce exactly {nonce}. After its result, say PROBE_OK."}]}
        if args.api == "messages":
            first["tools"] = [{"name": tool["name"], "description": tool["description"], "input_schema": schema}]
            first["tool_choice"] = {"type": "tool", "name": tool["name"]}
        elif args.api == "chat":
            first["tools"] = [{"type": "function", "function": tool}]
            first["tool_choice"] = {"type": "function", "function": {"name": tool["name"]}}
        else:
            first["tools"] = [{"type": "function", **tool}]
            first["tool_choice"] = {"type": "function", "name": tool["name"]}
        status, data = request("POST", paths[args.api], first)
        if status != 200:
            raise RuntimeError(f"Tool generation failed, HTTP {status}: {data.decode(errors='replace')[:800]}")
        called = json.loads(data)
        if args.api == "responses":
            calls = [i for i in called["output"] if i["type"] == "function_call"]
            if len(calls) != 1:
                raise RuntimeError("Expected exactly one actual tool call")
            call = calls[0]; arguments = json.loads(call["arguments"]); call_id = call["call_id"]
            continuation = first[key] + called["output"] + [{"type": "function_call_output", "call_id": call_id, "output": json.dumps({"nonce": nonce})}]
        elif args.api == "messages":
            calls = [i for i in called["content"] if i["type"] == "tool_use"]
            if len(calls) != 1:
                raise RuntimeError("Expected exactly one actual tool call")
            call = calls[0]; arguments = call["input"]; call_id = call["id"]
            continuation = first[key] + [{"role": "assistant", "content": called["content"]}, {"role": "user", "content": [{"type": "tool_result", "tool_use_id": call_id, "content": json.dumps({"nonce": nonce})}]}]
        else:
            message = called["choices"][0]["message"]; calls = message.get("tool_calls", [])
            if len(calls) != 1:
                raise RuntimeError("Expected exactly one actual tool call")
            call = {**calls[0]["function"], "id": calls[0]["id"]}; arguments = json.loads(call["arguments"]); call_id = call["id"]
            continuation = first[key] + [message, {"role": "tool", "tool_call_id": call_id, "content": json.dumps({"nonce": nonce})}]
        if not call_id or call["name"] != "identity_probe" or arguments != {"nonce": nonce}:
            raise RuntimeError("Model emitted incorrect tool identity/arguments; the tool was not executed")
        # The probe's actual implementation is identity(nonce) -> nonce. No I/O.
        followup = {**base, key: continuation}
        status, data = request("POST", paths[args.api], followup)
        if status != 200 or "PROBE_OK" not in data.decode():
            raise RuntimeError(f"Native tool-result continuation failed, HTTP {status}")
    print(json.dumps({"status": "PASS", "scope": "live-small-protocol-probe", "api": args.api,
        "model": args.model, "tools": args.tools, "text_bytes": len(text.encode()),
        "not_qualified": ["general coding quality", "cancellation and GPU resource release", "Codex/Claude Code E2E", "PCC distribution entitlement"]}, indent=2))

if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, IndexError, RuntimeError, http.client.HTTPException) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
