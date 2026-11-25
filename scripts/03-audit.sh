#!/usr/bin/env bash
# 在两端 CloudTrail 中查询最近的跨 partition 事件，并用 webIdentityTokenId 关联。
# 用法: scripts/03-audit.sh [起始时间, 默认 1 小时前, 例如 2026-11-25T05:00:00Z]
source "$(dirname "$0")/lib.sh"
clear_creds
START="${1:-$(date -u -d '-1 hour' +%FT%TZ)}"

events() { # $1=profile $2=region $3=event_name
  aws cloudtrail lookup-events --profile "$1" --region "$2" \
    --lookup-attributes "AttributeKey=EventName,AttributeValue=$3" \
    --start-time "$START" --query 'Events[].CloudTrailEvent' --output json \
  | jq -r '.[]' | jq -c 'select(.errorCode == null)'
}

show_pair() { # $1=src_profile $2=src_region $3=dst_profile $4=dst_region $5=title
  log "$5"
  local issued exchanged
  issued=$(events "$1" "$2" GetWebIdentityToken | jq -c '{id: .responseElements.webIdentityTokenId, time: .eventTime, who: .userIdentity.arn}')
  exchanged=$(events "$3" "$4" AssumeRoleWithWebIdentity | jq -c 'select(.additionalEventData.crossPartitionData != null) | {id: .requestParameters.webIdentityTokenId, time: .eventTime, session: .requestParameters.roleSessionName, source: .additionalEventData.crossPartitionData}')
  if [[ -z "$exchanged" ]]; then
    echo "没有找到目标端事件。CloudTrail 通常有几分钟延迟，可稍后重试。"; return
  fi
  while read -r ex; do
    local id src
    id=$(jq -r .id <<<"$ex")
    src=$(grep -F "\"$id\"" <<<"$issued" || true)
    echo "webIdentityTokenId: $id"
    echo "  源端签发: ${src:-（源端事件未找到，可能尚未投递）}"
    echo "  目标端交换: $ex"
  done <<<"$exchanged"
}

show_pair "$GL_PROFILE" "$GL_REGION" "$CN_PROFILE" "$CN_REGION" "方向 1：Global 签发 → 中国区交换"
show_pair "$CN_PROFILE" "$CN_REGION" "$GL_PROFILE" "$GL_REGION" "方向 2：中国区签发 → Global 交换"
