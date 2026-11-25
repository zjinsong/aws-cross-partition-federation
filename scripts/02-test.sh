#!/usr/bin/env bash
# 双向访问测试与负向用例。依赖 01-setup.sh 已完成。
source "$(dirname "$0")/lib.sh"
: "${CN_ISSUER_HOST:?请先运行 01-setup.sh}" "${GL_ISSUER_HOST:?请先运行 01-setup.sh}"

CN_TARGET_ARN="arn:aws-cn:iam::$CN_ACCOUNT_ID:role/$TARGET_ROLE"
GL_TARGET_ARN="arn:aws:iam::$GL_ACCOUNT_ID:role/$TARGET_ROLE"

# ------------------------------------------------------------------
log "方向 1：Global ($GL_REGION) → 中国区 ($CN_REGION)，访问 S3"
assume_caller "$GL_PROFILE" "$GL_REGION" aws "$GL_ACCOUNT_ID"
echo "源端身份: $(aws sts get-caller-identity --region "$GL_REGION" --query Arn --output text)"

JWT=$(get_jwt "$GL_REGION")
echo "JWT payload:"; decode_jwt "$JWT"

RESP=$(exchange_jwt "$CN_REGION" "$CN_TARGET_ARN" from-global "$JWT")
jq '{AssumedRoleUser: .AssumedRoleUser.Arn, SubjectFromWebIdentityToken, Audience, Provider, Expiration: .Credentials.Expiration}' <<<"$RESP"
export_creds "$(jq .Credentials <<<"$RESP")"

ARN=$(aws sts get-caller-identity --region "$CN_REGION" --query Arn --output text)
[[ "$ARN" == *":assumed-role/$TARGET_ROLE/from-global" ]] && pass "落地身份 $ARN" || fail "落地身份 $ARN"

aws s3 ls "s3://$CN_BUCKET/" --region "$CN_REGION" && pass "s3 ls" || fail "s3 ls"
aws s3 cp "s3://$CN_BUCKET/seed.txt" - --region "$CN_REGION" && pass "s3 get seed.txt" || fail "s3 get"
echo "written from Global at $(date -u +%FT%TZ)" \
  | aws s3 cp - "s3://$CN_BUCKET/from-global.txt" --region "$CN_REGION" && pass "s3 put from-global.txt" || fail "s3 put"
expect_error "越权: 列出所有存储桶" AccessDenied aws s3 ls --region "$CN_REGION"

# ------------------------------------------------------------------
log "方向 2：中国区 ($CN_REGION) → Global ($GL_REGION)，调用 STS/IAM"
assume_caller "$CN_PROFILE" "$CN_REGION" aws-cn "$CN_ACCOUNT_ID"
echo "源端身份: $(aws sts get-caller-identity --region "$CN_REGION" --query Arn --output text)"

JWT=$(get_jwt "$CN_REGION")
echo "JWT payload:"; decode_jwt "$JWT"

RESP=$(exchange_jwt "$GL_REGION" "$GL_TARGET_ARN" from-china "$JWT")
jq '{AssumedRoleUser: .AssumedRoleUser.Arn, SubjectFromWebIdentityToken, Audience, Provider, Expiration: .Credentials.Expiration}' <<<"$RESP"
export_creds "$(jq .Credentials <<<"$RESP")"

ARN=$(aws sts get-caller-identity --region "$GL_REGION" --query Arn --output text)
[[ "$ARN" == *":assumed-role/$TARGET_ROLE/from-china" ]] && pass "落地身份 $ARN" || fail "落地身份 $ARN"
aws iam get-role --region "$GL_REGION" --role-name "$TARGET_ROLE" --query Role.Arn --output text \
  && pass "iam get-role" || fail "iam get-role"
expect_error "越权: iam list-roles" AccessDenied aws iam list-roles --region "$GL_REGION" --max-items 1

# ------------------------------------------------------------------
log "负向用例"
assume_caller "$GL_PROFILE" "$GL_REGION" aws "$GL_ACCOUNT_ID"
expect_error "源端: 申请非约定 audience" AccessDenied get_jwt "$GL_REGION" wrong-aud
expect_error "源端: 申请超过上限的时长 (900s)" AccessDenied get_jwt "$GL_REGION" "$AUDIENCE" 900

OTHER_JWT=$(get_jwt "$GL_OTHER_REGION")
echo "其他区域 token 的 source_region: $(decode_jwt "$OTHER_JWT" | jq -r '."https://sts.amazonaws.com/".source_region')"
GOOD_JWT=$(get_jwt "$GL_REGION")

expect_error "目标端: source_region 不匹配" AccessDenied \
  exchange_jwt "$CN_REGION" "$CN_TARGET_ARN" neg-region "$OTHER_JWT"
expect_error "目标端: 换取未信任该 provider 的角色" AccessDenied \
  exchange_jwt "$CN_REGION" "arn:aws-cn:iam::$CN_ACCOUNT_ID:role/$CALLER_ROLE" neg-role "$GOOD_JWT"
expect_error "同一 partition 内交换" InvalidIdentityToken \
  exchange_jwt "$GL_REGION" "$GL_TARGET_ARN" neg-same "$GOOD_JWT"
clear_creds

# ------------------------------------------------------------------
log "结果"
if (( FAILED == 0 )); then pass "全部用例通过"; else fail "$FAILED 个用例未通过"; exit 1; fi
echo "CloudTrail 投递通常有几分钟延迟，稍后运行 scripts/03-audit.sh 查看两端事件关联。"
