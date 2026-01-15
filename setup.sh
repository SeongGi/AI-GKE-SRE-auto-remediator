#!/bin/bash

# ==============================================================================
# GKE AI-SRE Operator
==============================================================================

set -e
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== GKE AI-SRE Operator v43.0 (Loop Fix) ===${NC}"

# ==============================================================================
# [Step 1] 환경 설정 입력
# ==============================================================================
echo -e "\n${YELLOW}[1] 환경 설정 입력${NC}"

# Slack Token
read -p "👉 Slack Bot Token (xoxb-...): " INPUT_BOT_TOKEN
SLACK_BOT_TOKEN=${INPUT_BOT_TOKEN:-""}
read -p "👉 Slack App Token (xapp-...): " INPUT_APP_TOKEN
SLACK_APP_TOKEN=${INPUT_APP_TOKEN:-""}
read -p "👉 Slack 명령어 (기본값: /gke): " INPUT_CMD
SLACK_COMMAND=${INPUT_CMD:-"/gke"}

# Slack Channel ID
echo -e "\n${RED}[필독] 채널 ID(C...)를 입력해주세요.${NC}"
read -p "👉 Slack 채널 ID (예: C01234ABCDE): " INPUT_CHANNEL
SLACK_CHANNEL=${INPUT_CHANNEL:-""}
if [ -z "$SLACK_CHANNEL" ]; then echo "❌ 채널 ID 필수"; exit 1; fi

# 프로젝트
CURRENT_PROJECT=$(gcloud config get-value project 2>/dev/null)
echo -e "\n현재 프로젝트: ${BLUE}${CURRENT_PROJECT}${NC}"
read -p "👉 이 프로젝트를 사용하시겠습니까? (Y/n): " PROJ_INPUT
PROJ_INPUT=${PROJ_INPUT:-"Y"}

if [[ ! "$PROJ_INPUT" =~ ^[Yy]$ ]]; then
    read -p "👉 사용할 Project ID 입력: " PROJECT_ID
    gcloud config set project "$PROJECT_ID"
else
    PROJECT_ID=$CURRENT_PROJECT
fi

# 클러스터
echo -e "\n클러스터 목록 조회 중..."
readarray -t CL_NAMES < <(gcloud container clusters list --format="value(name)")
readarray -t CL_LOCS < <(gcloud container clusters list --format="value(location)")
COUNT=${#CL_NAMES[@]}

if [ "$COUNT" -eq 0 ]; then
    echo -e "${RED}❌ 클러스터가 없습니다.${NC}"
    exit 1
fi

echo "검색된 클러스터:"
for (( i=0; i<COUNT; i++ )); do
    echo -e "  [${BLUE}$((i+1))${NC}] ${CL_NAMES[$i]} (${CL_LOCS[$i]})"
done

while true; do
    read -p "👉 연결할 클러스터 번호 (1~$COUNT): " CL_IDX
    if [[ "$CL_IDX" =~ ^[0-9]+$ ]] && [ "$CL_IDX" -ge 1 ] && [ "$CL_IDX" -le "$COUNT" ]; then
        break
    else
        echo "⚠️  잘못된 번호입니다."
    fi
done

CLUSTER_NAME=${CL_NAMES[$((CL_IDX-1))]}
CLUSTER_LOC=${CL_LOCS[$((CL_IDX-1))]}

echo -e "${GREEN}✅ 설정 완료! 설치를 시작합니다...${NC}"

# ==============================================================================
# [Step 2] 클러스터 연결
# ==============================================================================
gcloud container clusters get-credentials "$CLUSTER_NAME" --location "$CLUSTER_LOC" > /dev/null 2>&1

# ==============================================================================
# [Step 3] ConfigMap 생성
# ==============================================================================
echo -e "\n${YELLOW}[3] ConfigMap 초기화${NC}"
cat <<EOF > prompt-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ai-sre-prompt-config
  namespace: default
data:
  auto_fix_allowlist.txt: |
    ImagePullBackOff
    ErrImagePull
  
  blocked_commands.txt: |
    delete namespace
    rm -rf
    --force

  system_prompt.txt: |
    You are a Senior Kubernetes SRE Assistant.
    Your goal is to decide whether the issue is an "Infrastructure Issue" (Fixable) or a "Code Bug" (Not Fixable).
    
    [DECISION RULES]
    1. **Infrastructure Issue**: OOMKilled, ImagePullBackOff, Missing Env Var.
       -> ACTION: Generate a 'kubectl' command to fix it.
    
    2. **Code Bug**: panic, segmentation fault, nil pointer, syntax error, python traceback, java stacktrace.
       -> ACTION: **DO NOT GENERATE ANY COMMAND**. Just provide a detailed analysis in Korean.
    
    [OUTPUT INSTRUCTION]
    - If it's a Code Bug, your output MUST NOT contain any kubectl command.
    - Start analysis with "🤖 분석:" and "📋 조치 계획:".
    - Explain WHY it cannot be fixed by infrastructure changes.

  user_prompt_template.txt: |
    [SITUATION]
    Pod: {pod_name} (NS: {namespace})
    Error: {error_reason}
    
    [TARGET INFO]
    - Workload: {owner_kind}/{owner_name}
    - Container: {container_name}
    - Image: {current_image}

    [K8S EVENTS]
    {k8s_events}

    [APP LOGS (Last 30 lines)]
    {pod_logs}

    [HISTORY]
    {history_context}
    
    [MISSION]
    1. Read the [APP LOGS] carefully.
    2. If you see 'panic' or 'error' in the application code, this is a CODE BUG.
       -> STOP. Do not generate a command. Explain the bug to the developer.
    3. If it is 'OOMKilled' or 'Env Var Missing', generate the fix command.
EOF
kubectl apply -f prompt-config.yaml > /dev/null

# ==============================================================================
# [Step 4] IAM 및 인증 키
# ==============================================================================
echo -e "\n${YELLOW}[4] IAM 설정 및 키 정리${NC}"
GCP_SA_NAME="ai-sre-gcp-sa"
GCP_SA_EMAIL="${GCP_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
KEY_FILE="ai-sre-key.json"

gcloud iam service-accounts create $GCP_SA_NAME --display-name "AI SRE Operator SA" > /dev/null 2>&1 || true
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:$GCP_SA_EMAIL" --role="roles/aiplatform.user" --condition=None > /dev/null 2>&1 || true

EXISTING_KEYS=$(gcloud iam service-accounts keys list --iam-account=$GCP_SA_EMAIL --managed-by=user --format="value(name)")
if [ -n "$EXISTING_KEYS" ]; then
    for key in $EXISTING_KEYS; do
        gcloud iam service-accounts keys delete $key --iam-account=$GCP_SA_EMAIL --quiet > /dev/null 2>&1 || true
    done
fi

rm -f $KEY_FILE
gcloud iam service-accounts keys create $KEY_FILE --iam-account=$GCP_SA_EMAIL > /dev/null 2>&1
kubectl delete secret google-sa-key --ignore-not-found=true > /dev/null 2>&1
kubectl create secret generic google-sa-key --from-file=key.json=$KEY_FILE
rm -f $KEY_FILE

# ==============================================================================
# [Step 5] 소스 코드 생성
# ==============================================================================
echo -e "\n${YELLOW}[5] 소스 코드 생성${NC}"

cat <<REQ > requirements.txt
kubernetes>=28.1.0
google-cloud-aiplatform>=1.38.0
google-generativeai>=0.3.0
google-auth>=2.0.0
slack_bolt>=1.18.0
REQ

cat <<'PY' > main.py
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
PY

# Dockerfile 생성
cat <<'EOF' > Dockerfile
FROM python:3.11-slim
RUN apt-get update && apt-get install -y curl && \
    curl -LO https://dl.k8s.io/release/v1.29.0/bin/linux/amd64/kubectl && \
    chmod +x kubectl && \
    mv kubectl /usr/local/bin/ && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .
CMD ["python", "-u", "main.py"]
EOF

# [6] Build & Deploy
echo "Building Container Image..."
IMAGE_NAME="gcr.io/$PROJECT_ID/ai-sre-operator:v43.0-loopfix"
docker build --platform linux/amd64 -q -t $IMAGE_NAME . > /dev/null
gcloud auth configure-docker --quiet > /dev/null
docker push $IMAGE_NAME > /dev/null

cat <<YAML > ai-sre-deploy.yaml
apiVersion: v1
kind: ServiceAccount
metadata: {name: ai-sre-sa, namespace: default}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: ai-sre-role}
rules:
- apiGroups: ["", "apps", "batch"]
  resources: ["pods", "pods/log", "deployments", "replicasets", "events", "configmaps"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: ai-sre-binding}
subjects: [{kind: ServiceAccount, name: ai-sre-sa, namespace: default}]
roleRef: {kind: ClusterRole, name: ai-sre-role, apiGroup: rbac.authorization.k8s.io}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: gke-ai-operator, namespace: default}
spec:
  replicas: 1
  selector: {matchLabels: {app: ai-sre-operator}}
  template:
    metadata: {labels: {app: ai-sre-operator}}
    spec:
      serviceAccountName: ai-sre-sa
      containers:
      - name: operator
        image: $IMAGE_NAME
        imagePullPolicy: Always
        env:
        - {name: GCP_PROJECT_ID, value: "$PROJECT_ID"}
        - {name: GCP_LOCATION, value: "global"}
        - {name: MODEL_NAME, value: "gemini-3-flash-preview"}
        - {name: GOOGLE_APPLICATION_CREDENTIALS, value: "/var/secrets/google/key.json"}
        - {name: SLACK_BOT_TOKEN, value: "$SLACK_BOT_TOKEN"}
        - {name: SLACK_APP_TOKEN, value: "$SLACK_APP_TOKEN"}
        - {name: SLACK_COMMAND, value: "$SLACK_COMMAND"}
        - {name: SLACK_CHANNEL, value: "$SLACK_CHANNEL"}
        volumeMounts:
        - name: google-cloud-key
          mountPath: /var/secrets/google
          readOnly: true
        - name: prompt-volume
          mountPath: /etc/ai-prompts
          readOnly: true
      volumes:
      - name: google-cloud-key
        secret:
          secretName: google-sa-key
      - name: prompt-volume
        configMap:
          name: ai-sre-prompt-config
YAML

kubectl delete deployment gke-ai-operator --ignore-not-found=true > /dev/null 2>&1
kubectl apply -f ai-sre-deploy.yaml

echo "Waiting for pod startup..."
sleep 5
kubectl wait --for=condition=available --timeout=90s deployment/gke-ai-operator -n default

# [Operations Guide]
echo "Installation Complete."
echo "================================================================"
echo " 📘 GKE AI-SRE Operator Operations Guide"
echo "================================================================"
echo " 1. Installation Path"
echo "    - Namespace: default"
echo "    - Deployment: gke-ai-operator"
echo ""
echo " 2. View Logs (Follow)"
echo "    kubectl logs -f deployment/gke-ai-operator -n default"
echo ""
echo " 3. Edit Prompts (Live)"
echo "    Type /gke in Slack -> Edit -> Save"
echo ""
echo " 4. Emergency Stop"
echo "    kubectl scale deployment gke-ai-operator --replicas=0 -n default"
echo "================================================================"