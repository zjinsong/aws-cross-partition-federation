#!/usr/bin/env bash
# 公共函数，由其他脚本 source。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$REPO_ROOT/config.env"
OUT_DIR="$REPO_ROOT/.out"

[[ -f "$CONFIG" ]] || { echo "缺少 $CONFIG，请先执行: cp config.env.example config.env 并填写"; exit 1; }
set -a; source "$CONFIG"; set +a
mkdir -p "$OUT_DIR"

for bin in aws jq envsubst; do
  command -v "$bin" >/dev/null || { echo "缺少依赖: $bin"; exit 1; }
done

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
pass() { printf '\033[1;32m[PASS]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; FAILED=$((FAILED+1)); }
FAILED=0

# 把 policies/ 下的模板渲染到 .out/，只替换 config.env 中定义的变量
render() {
  local name="$1"
  local vars='${CN_ACCOUNT_ID}${GL_ACCOUNT_ID}${CN_REGION}${GL_REGION}${AUDIENCE}${TOKEN_DURATION}${CALLER_ROLE}${TARGET_ROLE}${CN_BUCKET}${CN_CALLER_PRINCIPAL}${GL_CALLER_PRINCIPAL}${CN_ISSUER_HOST}${GL_ISSUER_HOST}'
  if grep -q '_ISSUER_HOST' "$REPO_ROOT/policies/$name" && [[ -z "${CN_ISSUER_HOST:-}" || -z "${GL_ISSUER_HOST:-}" ]]; then
    echo "模板 $name 需要 issuer，但 CN_ISSUER_HOST/GL_ISSUER_HOST 为空" >&2; exit 1
  fi
  envsubst "$vars" < "$REPO_ROOT/policies/$name" > "$OUT_DIR/$name"
  jq empty "$OUT_DIR/$name"
  echo "file://$OUT_DIR/$name"
}

# 清除环境变量中的凭证，避免误用上一步的身份
clear_creds() { unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE; }

# 从 JSON（含 AccessKeyId/SecretAccessKey/SessionToken）导出凭证
export_creds() {
  local json="$1"
  AWS_ACCESS_KEY_ID=$(jq -r .AccessKeyId <<<"$json")
  AWS_SECRET_ACCESS_KEY=$(jq -r .SecretAccessKey <<<"$json")
  AWS_SESSION_TOKEN=$(jq -r .SessionToken <<<"$json")
  [[ "$AWS_ACCESS_KEY_ID" != null && -n "$AWS_ACCESS_KEY_ID" ]] || { echo "未取得凭证"; exit 1; }
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
}

# 以 profile 身份 assume 本端 Caller 角色，模拟工作负载的执行角色
assume_caller() { # $1=profile $2=region $3=partition $4=account
  clear_creds
  local creds
  creds=$(aws sts assume-role --profile "$1" --region "$2" \
    --role-arn "arn:$3:iam::$4:role/$CALLER_ROLE" \
    --role-session-name cross-partition-demo \
    --query Credentials --output json)
  export_creds "$creds"
}

# 用当前凭证申请 JWT，输出 token 字符串
get_jwt() { # $1=region [$2=audience] [$3=duration]
  aws sts get-web-identity-token --region "$1" \
    --audience "${2:-$AUDIENCE}" \
    --signing-algorithm ES384 \
    --duration-seconds "${3:-$TOKEN_DURATION}" \
    --query WebIdentityToken --output text
}

# 解码 JWT payload（不验签，仅用于查看声明）
decode_jwt() {
  local p; p=$(cut -d. -f2 <<<"$1" | tr '_-' '/+')
  while (( ${#p} % 4 )); do p="$p="; done
  base64 -d <<<"$p" | jq .
}

# 在目标端用 JWT 换取凭证。请求不需要签名
exchange_jwt() { # $1=region $2=role_arn $3=session_name $4=jwt
  clear_creds
  aws sts assume-role-with-web-identity --region "$1" --no-sign-request \
    --role-arn "$2" --role-session-name "$3" \
    --web-identity-token "$4" --output json
}

# 期望命令失败且输出包含指定错误码
expect_error() { # $1=desc $2=error_code $3...=command
  local desc="$1" code="$2"; shift 2
  local out
  if out=$("$@" 2>&1); then
    fail "$desc：预期 $code，实际成功"
  elif grep -q "$code" <<<"$out"; then
    pass "$desc → $code"
  else
    fail "$desc：预期 $code，实际 $(tail -1 <<<"$out")"
  fi
}
