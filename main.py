import os, time, subprocess, threading, logging, json, re, traceback
from kubernetes import client, config, watch
import google.auth
import vertexai
from vertexai.generative_models import GenerativeModel, Tool, FunctionDeclaration, Part, SafetySetting
from slack_bolt import App
from slack_bolt.adapter.socket_mode import SocketModeHandler

logging.basicConfig(level=logging.INFO)

PROJECT_ID = os.getenv("GCP_PROJECT_ID")
LOCATION = os.getenv("GCP_LOCATION", "global")
MODEL_NAME = os.getenv("MODEL_NAME", "gemini-3-flash-preview")
SLACK_BOT_TOKEN = os.getenv("SLACK_BOT_TOKEN")
SLACK_APP_TOKEN = os.getenv("SLACK_APP_TOKEN")
SLACK_COMMAND_NAME = os.getenv("SLACK_COMMAND", "/gke")
SLACK_CHANNEL_ID = os.getenv("SLACK_CHANNEL")

try: config.load_incluster_config()
except: config.load_kube_config()
v1 = client.CoreV1Api()
app_v1 = client.AppsV1Api()

CURRENT_SYSTEM_PROMPT = ""
CURRENT_USER_PROMPT = ""

slack_app = App(token=SLACK_BOT_TOKEN)
pod_states = {}

def log(icon, title, content=""):
    print(f"{icon} [{title}] {content}")

def exec_kubectl(command):
    if not command.strip().startswith("kubectl"): return "Error: Only kubectl allowed."
    if "$(" in command or "`" in command: return "FAILED: Complex shell syntax not allowed."
    try:
        res = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=60)
        if res.returncode == 0: return f"SUCCESS\n{res.stdout.strip()}"
        else: return f"FAILED (Exit Code {res.returncode})\nError: {res.stderr.strip() or res.stdout.strip()}"
    except Exception as e: return f"EXECUTION ERROR: {str(e)}"

def extract_command_from_text(text):
    match = re.search(r'```(?:bash|sh)?\n?(kubectl.*?)```', text, re.DOTALL)
    if match: return match.group(1).strip()
    match = re.search(r'`(kubectl.*?)`', text)
    if match: return match.group(1).strip()
    match = re.search(r'(kubectl\s+set\s+.*)', text)
    if match: return match.group(1).strip()
    return None

def clean_markdown(text):
    return text.replace("**", "")

def get_k8s_events(pod_name, namespace):
    try:
        events = v1.list_namespaced_event(namespace, field_selector=f"involvedObject.name={pod_name}")
        log_lines = []
        for e in sorted(events.items, key=lambda x: x.last_timestamp or x.event_time or "", reverse=True)[:3]:
            if e.type == "Warning": log_lines.append(f"[{e.reason}] {e.message}")
        return "\n".join(log_lines) if log_lines else "특이 이벤트 없음"
    except Exception as e: return f"Error: {e}"

def get_pod_logs(pod_name, namespace, container_name):
    try:
        logs = v1.read_namespaced_pod_log(name=pod_name, namespace=namespace, container=container_name, tail_lines=20)
        return logs if logs else "Logs are empty."
    except Exception as e: return f"Failed to fetch logs: {str(e)}"

def get_pod_context(pod_name, namespace):
    c_name, c_image, owner_kind, owner_name = "unknown", "unknown", "Pod", pod_name
    try:
        pod = v1.read_namespaced_pod(pod_name, namespace)
        c = pod.spec.containers[0]
        c_name, c_image = c.name, c.image
        if pod.metadata.owner_references:
            owner = pod.metadata.owner_references[0]
            if owner.kind == "ReplicaSet":
                rs = app_v1.read_namespaced_replica_set(owner.name, namespace)
                if rs.metadata.owner_references:
                    rs_owner = rs.metadata.owner_references[0]
                    owner_kind, owner_name = rs_owner.kind, rs_owner.name
                else: owner_kind, owner_name = "ReplicaSet", owner.name
            else: owner_kind, owner_name = owner.kind, owner.name
        return c_name, c_image, owner_kind, owner_name
    except: return c_name, c_image, owner_kind, owner_name

def load_system_prompt():
    global CURRENT_SYSTEM_PROMPT
    if CURRENT_SYSTEM_PROMPT: return CURRENT_SYSTEM_PROMPT
    try:
        with open("/etc/ai-prompts/system_prompt.txt", "r") as f:
            CURRENT_SYSTEM_PROMPT = f.read()
            return CURRENT_SYSTEM_PROMPT
    except: return "You are a helpful Kubernetes assistant."

def load_prompt():
    global CURRENT_USER_PROMPT
    if CURRENT_USER_PROMPT: return CURRENT_USER_PROMPT
    try:
        with open("/etc/ai-prompts/user_prompt_template.txt", "r") as f:
            CURRENT_USER_PROMPT = f.read()
            return CURRENT_USER_PROMPT
    except: return "Fix pod {pod} error {error}"

def load_config_list(filename):
    try:
        with open(f"/etc/ai-prompts/{filename}", "r") as f:
            return [l.strip() for l in f.readlines() if l.strip()]
    except: return []

@slack_app.command(SLACK_COMMAND_NAME)
def open_prompt_modal(ack, body, client):
    ack()
    sys_txt = load_system_prompt()
    user_txt = load_prompt()
    client.views_open(
        trigger_id=body["trigger_id"],
        view={
            "type": "modal",
            "callback_id": "prompt_edit_view",
            "title": {"type": "plain_text", "text": "Prompt Settings"},
            "submit": {"type": "plain_text", "text": "Save"},
            "blocks": [
                {"type": "section", "text": {"type": "mrkdwn", "text": "Edit AI Prompts (Live Update)"}},
                {"type": "input", "block_id": "blk_sys", "label": {"type": "plain_text", "text": "System Prompt"}, "element": {"type": "plain_text_input", "action_id": "ipt_sys", "multiline": True, "initial_value": sys_txt}},
                {"type": "input", "block_id": "blk_user", "label": {"type": "plain_text", "text": "User Prompt"}, "element": {"type": "plain_text_input", "action_id": "ipt_user", "multiline": True, "initial_value": user_txt}}
            ]
        }
    )

@slack_app.view("prompt_edit_view")
def handle_prompt_save(ack, body, client, view):
    ack()
    new_sys = view["state"]["values"]["blk_sys"]["ipt_sys"]["value"]
    new_user = view["state"]["values"]["blk_user"]["ipt_user"]["value"]
    global CURRENT_SYSTEM_PROMPT, CURRENT_USER_PROMPT
    CURRENT_SYSTEM_PROMPT = new_sys
    CURRENT_USER_PROMPT = new_user
    try:
        patch_body = {"data": {"system_prompt.txt": new_sys, "user_prompt_template.txt": new_user}}
        v1.patch_namespaced_config_map(name="ai-sre-prompt-config", namespace="default", body=patch_body)
        client.chat_postMessage(channel=SLACK_CHANNEL_ID, text="✅ *Prompts Updated & Saved!*")
    except Exception as e:
        client.chat_postMessage(channel=SLACK_CHANNEL_ID, text=f"⚠️ *Save Failed:* {str(e)}")

def verify_fix(namespace, owner_name):
    time.sleep(3)
    try:
        cmd = f"kubectl get pods -n {namespace} | grep {owner_name}"
        res = subprocess.run(cmd, shell=True, capture_output=True, text=True)
        return res.stdout.strip() if res.stdout else "No pods found (restarting?)"
    except: return "Verification failed"

@slack_app.action("approve_action")
def handle_approval(ack, body, client):
    ack()
    user = body["user"]["username"]
    val_parts = body["actions"][0]["value"].split("|", 2)
    if len(val_parts) != 3: return
    pod_key, owner_name, command = val_parts[0], val_parts[1], val_parts[2]
    
    out = exec_kubectl(command)
    status_icon = "❌ Failed" if "FAILED" in out else "✅ Success"
    result_text = f"```{out[:300]}```"
    
    if "SUCCESS" in out:
        ns = pod_key.split("/")[0]
        verify_out = verify_fix(ns, owner_name)
        if pod_key in pod_states: del pod_states[pod_key]
        blocks = [
            {"type": "section", "text": {"type": "mrkdwn", "text": f"🛠️ *Action*: {status_icon} (By @{user})"}},
            {"type": "section", "text": {"type": "mrkdwn", "text": f"`{command}`"}},
            {"type": "section", "text": {"type": "mrkdwn", "text": f"📋 *Result*:\n{result_text}"}},
            {"type": "section", "text": {"type": "mrkdwn", "text": f"🔍 *상태 검증*\n```{verify_out}```"}}
        ]
    else:
        if pod_key not in pod_states: pod_states[pod_key] = {"fail_count": 0, "last_cmd": "", "last_error": ""}
        pod_states[pod_key]["fail_count"] += 1
        pod_states[pod_key]["last_cmd"] = command
        pod_states[pod_key]["last_error"] = out.replace("\n", " ")[:200]
        blocks = [
            {"type": "section", "text": {"type": "mrkdwn", "text": f"🛠️ *Action*: {status_icon} (By @{user})"}},
            {"type": "section", "text": {"type": "mrkdwn", "text": f"`{command}`"}},
            {"type": "section", "text": {"type": "mrkdwn", "text": f"📋 *Result*:\n{result_text}"}}
        ]

    client.chat_update(channel=body["channel"]["id"], ts=body["message"]["ts"], text=f"{status_icon} 실행 완료", blocks=blocks)

@slack_app.action("reject_action")
def handle_rejection(ack, body, client):
    ack()
    user = body["user"]["username"]
    client.chat_update(channel=body["channel"]["id"], ts=body["message"]["ts"], text="Rejected",
        blocks=[{"type": "section", "text": {"type": "mrkdwn", "text": f"❌ *Rejected* (By @{user})"}}]
    )

def init_model():
    try: google.auth.default()
    except: pass
    vertexai.init(project=PROJECT_ID, location=LOCATION)
    tool = Tool(function_declarations=[FunctionDeclaration(name="execute_shell_command", description="Run kubectl", parameters={"type": "OBJECT", "properties": {"command": {"type": "STRING"}}, "required": ["command"]})])
    sys_prompt = load_system_prompt()
    return GenerativeModel(MODEL_NAME, tools=[tool], safety_settings=[SafetySetting(category=SafetySetting.HarmCategory.HARM_CATEGORY_DANGEROUS_CONTENT, threshold=SafetySetting.HarmBlockThreshold.BLOCK_NONE)], system_instruction=[sys_prompt])

model = init_model()
last_processed_time = {}

def fix_pod(pod, ns, error):
    now = time.time()
    if pod in last_processed_time and (now - last_processed_time[pod] < 60): return
    last_processed_time[pod] = now

    pod_key = f"{ns}/{pod}"
    if pod_key not in pod_states: pod_states[pod_key] = {"fail_count": 0, "last_cmd": "", "last_error": ""}
    state = pod_states[pod_key]

    print("\n" + "="*50)
    log("🚨", "장애 감지", f"{pod_key} ({error})")

    if state['fail_count'] >= 3:
        # [수정] 조치 불가로 인해 3회 이상(이미 한번 알림 보낸 후)이면 더 이상 메시지 보내지 않음
        # (너무 시끄러워서 silent 모드로 변경)
        return

    try:
        c_name, c_image, owner_kind, owner_name = get_pod_context(pod, ns)
        log("ℹ️", "정보 조회", f"Target: {owner_kind}/{owner_name}")
        k8s_events = get_k8s_events(pod, ns)
        pod_logs = get_pod_logs(pod, ns, c_name)
        log("📜", "로그 수집", f"{len(pod_logs)} bytes")

        allow_list = load_config_list("auto_fix_allowlist.txt")
        is_auto = any(a in error for a in allow_list)
        history_text = f"PREVIOUS FAILED: {state['last_error']}" if state['fail_count'] > 0 else "No previous failures."

        template = load_prompt()
        final_prompt = template.format(pod_name=pod, namespace=ns, error_reason=error, container_name=c_name, current_image=c_image, owner_kind=owner_kind, owner_name=owner_name, k8s_events=k8s_events, pod_logs=pod_logs, history_context=history_text)
        
        log("⏳", "AI 요청 중", "...")
        current_sys = load_system_prompt()
        dynamic_model = GenerativeModel(MODEL_NAME, tools=[model._tools[0]], safety_settings=model._safety_settings, system_instruction=[current_sys])
        chat = dynamic_model.start_chat()
        response = chat.send_message(final_prompt)
        
        explanation = ""
        cmd = ""
        if response.candidates:
            for part in response.candidates[0].content.parts:
                try: 
                    if part.text: explanation += part.text
                    if part.function_call: cmd = part.function_call.args["command"]
                except: pass
        
        if not cmd and explanation:
            log("🔎", "텍스트 파싱", "...")
            cmd = extract_command_from_text(explanation)

        ai_msg = clean_markdown(explanation.strip()) if explanation.strip() else "No analysis provided."
        
        if not cmd or cmd.strip() == "kubectl":
            log("⚠️", "조치 불가", "...")
            
            # [핵심 수정] 조치 불가 시 fail_count를 3으로 설정하여 다음 루프부터 침묵(Ignore) 처리
            state['fail_count'] = 3
            
            try: slack_app.client.chat_postMessage(channel=SLACK_CHANNEL_ID, text="Cannot fix", blocks=[
                {"type": "header", "text": {"type": "plain_text", "text": "⚠️ 조치 불가 (AI 판단)", "emoji": True}},
                {"type": "section", "text": {"type": "mrkdwn", "text": f"{ai_msg}"}},
                {"type": "context", "elements": [{"type": "mrkdwn", "text": f"(Target: `{owner_kind}/{owner_name}`)"}]}
            ])
            except: pass
            return
        
        block_list = load_config_list("blocked_commands.txt")
        if any(b in cmd for b in block_list): return

        if is_auto:
            try: slack_app.client.chat_postMessage(channel=SLACK_CHANNEL_ID, text="Auto Fix", blocks=[
                {"type": "header", "text": {"type": "plain_text", "text": "🤖 자동 조치", "emoji": True}},
                {"type": "section", "text": {"type": "mrkdwn", "text": f"{ai_msg}"}},
                {"type": "section", "text": {"type": "mrkdwn", "text": f"🚀 *실행*: `{cmd}`"}}
            ])
            except: pass
            
            out = exec_kubectl(cmd)
            status_icon = "❌" if "FAILED" in out else "✅"
            result_text = f"```{out[:300]}```"
            
            if "FAILED" in out:
                state['fail_count'] += 1
                state['last_cmd'] = cmd
                state['last_error'] = out.replace("\n", " ")[:200]
            else:
                state['fail_count'] = 0
                verify_out = verify_fix(ns, owner_name)
                result_text += f"\n\n🔍 *상태 검증*\n```{verify_out}```"
                
            try: slack_app.client.chat_postMessage(channel=SLACK_CHANNEL_ID, text="Result", blocks=[
                {"type": "section", "text": {"type": "mrkdwn", "text": f"📋 *Result*: {status_icon}\n{result_text}"}}
            ])
            except: pass
        else:
            btn_value = f"{pod_key}|{owner_name}|{cmd}"
            try: slack_app.client.chat_postMessage(channel=SLACK_CHANNEL_ID, text="Approval Needed", blocks=[
                    {"type": "header", "text": {"type": "plain_text", "text": "🚨 승인 필요", "emoji": True}},
                    {"type": "section", "text": {"type": "mrkdwn", "text": f"{ai_msg}"}},
                    {"type": "divider"},
                    {"type": "section", "text": {"type": "mrkdwn", "text": f"**제안 명령어:**\n`{cmd}`"}},
                    {"type": "actions", "elements": [
                        {"type": "button", "text": {"type": "plain_text", "text": "✅ 승인 & 실행"}, "style": "primary", "value": btn_value, "action_id": "approve_action"},
                        {"type": "button", "text": {"type": "plain_text", "text": "❌ 거절"}, "style": "danger", "value": "reject", "action_id": "reject_action"}
                    ]}])
            except: pass
    except Exception as e:
        log("❌", "Logic Error", str(e))
        traceback.print_exc()
        try: slack_app.client.chat_postMessage(channel=SLACK_CHANNEL_ID, text=f"⚠️ *Internal Error:* {str(e)}")
        except: pass

def check_pod_status(pod):
    if "ai-sre" in (pod.metadata.name or ""): return
    status = pod.status
    if not status.container_statuses: return
    for c in status.container_statuses:
        reason = None
        if c.state.waiting and c.state.waiting.reason in ["CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull"]: reason = c.state.waiting.reason
        elif c.last_state.terminated and c.last_state.terminated.reason == "OOMKilled": reason = "OOMKilled"
        if reason: fix_pod(pod.metadata.name, pod.metadata.namespace, reason)

def k8s_watcher_loop():
    print(f"Watcher started. Target Channel: {SLACK_CHANNEL_ID}")
    try:
        pods = v1.list_pod_for_all_namespaces().items
        for pod in pods: check_pod_status(pod)
    except: pass
    w = watch.Watch()
    while True:
        try:
            for event in w.stream(v1.list_pod_for_all_namespaces):
                check_pod_status(event['object'])
                time.sleep(1)
        except: time.sleep(5)

if __name__ == "__main__":
    if SLACK_APP_TOKEN:
        handler = SocketModeHandler(slack_app, SLACK_APP_TOKEN)
        t = threading.Thread(target=handler.start, daemon=True)
        t.start()
    k8s_watcher_loop()
