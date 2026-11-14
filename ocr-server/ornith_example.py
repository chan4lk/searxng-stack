"""Ornith (OpenAI API) + Surya 2 OCR as a tool. Python holds the files; the model only names them."""
import base64, json, os, sys
import requests
from openai import OpenAI

OCR_URL = "http://mac-studio.tail3caa2f.ts.net:8893/v1/ocr"
client = OpenAI(base_url=os.environ["OPENAI_BASE_URL"], api_key=os.environ["OPENAI_API_KEY"])
MODEL = os.environ.get("OPENAI_MODEL", "Ornith-1.5-35B-A3B")

files = {f"doc{i}": p for i, p in enumerate(sys.argv[1:], 1)}  # file_id -> local path

TOOLS = [{"type": "function", "function": {
    "name": "ocr_document",
    "description": "OCR an attached PDF or image (any language incl. Sinhala/Tamil) and return its text per page.",
    "parameters": {"type": "object", "required": ["file_id"], "properties": {
        "file_id": {"type": "string", "enum": list(files)},
        "pages": {"type": "string", "description": 'PDF pages, e.g. "1-3,5"; default all'},
        "format": {"type": "string", "enum": ["text", "html"]}}}}}]


def ocr_document(file_id, pages=None, format="text"):
    b64 = base64.b64encode(open(files[file_id], "rb").read()).decode()
    body = {"file": b64, "format": format, **({"pages": pages} if pages else {})}
    r = requests.post(OCR_URL, json=body, timeout=3600)
    r.raise_for_status()
    return "\n\n".join(f"===== PAGE {p['page']} =====\n{p['text']}" for p in r.json()["pages"])


messages = [{"role": "user", "content":
             f"Attached files: {', '.join(f'{k} ({os.path.basename(v)})' for k, v in files.items())}. "
             "Extract the key data from each as JSON (dates, names, numbers, totals)."}]
while True:
    msg = client.chat.completions.create(model=MODEL, messages=messages, tools=TOOLS).choices[0].message
    messages.append(msg)
    if not msg.tool_calls:
        print(msg.content)
        break
    for call in msg.tool_calls:
        args = json.loads(call.function.arguments)
        print(f"-> ocr_document({args})", file=sys.stderr)
        messages.append({"role": "tool", "tool_call_id": call.id, "content": ocr_document(**args)})
