#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
scenario=${1-}
runtime=${2-}
asset=${3-}
case "$scenario" in
  meeting|receipt) ;;
  *) echo "usage: $0 meeting|receipt system|mlx|litert [/absolute/model-path] [receipt-image]" >&2; exit 2 ;;
esac
export APPLELOCALAI_RESPONSE_FORMAT=json
export APPLELOCALAI_MAX_TOKENS=512
if [ "$scenario" = meeting ]; then
unset APPLELOCALAI_MODEL_IMAGE
export APPLELOCALAI_MODEL_PROMPT='다음 회의 메모에서 확정된 업무만 JSON으로 정리하세요. 설명이나 코드 펜스 없이 {"tasks":[{"owner":"이름","task":"업무","due":"YYYY-MM-DD"}],"budget_approved":false} 형식으로 답하세요. 메모 순서를 유지하고 추측하지 마세요. 회의일은 2026-09-17입니다. 메모: 민지는 9월 21일까지 로그인 오류 수정. 준호는 9월 22일까지 회귀 테스트. 홍보 일정은 아직 미정이며 담당자도 정하지 않음. 추가 예산은 요청했지만 승인되지 않음.'
export APPLELOCALAI_MODEL_EXPECTED='{"tasks":[{"owner":"민지","task":"로그인 오류 수정","due":"2026-09-21"},{"owner":"준호","task":"회귀 테스트","due":"2026-09-22"}],"budget_approved":false}'
export APPLELOCALAI_FOLLOWUP_PROMPT='준호의 기한만 2026-09-24로 변경됐습니다. 직전 결과의 다른 내용은 그대로 유지해서 같은 JSON 형식의 전체 결과를 반환하세요.'
export APPLELOCALAI_FOLLOWUP_EXPECTED='{"tasks":[{"owner":"민지","task":"로그인 오류 수정","due":"2026-09-21"},{"owner":"준호","task":"회귀 테스트","due":"2026-09-24"}],"budget_approved":false}'
else
export APPLELOCALAI_MODEL_PROMPT='Extract this receipt for expense reporting. Return only a JSON object with merchant, date (YYYY-MM-DD), receipt_id, currency, subtotal, discount, tax, total, payment. Use JSON numbers for amounts. Use payment value "corporate_card".'
export APPLELOCALAI_MODEL_EXPECTED='{"merchant":"HARBOR OFFICE SUPPLY","date":"2026-09-16","receipt_id":"H-1842","currency":"USD","subtotal":35,"discount":5,"tax":3,"total":33,"payment":"corporate_card"}'
export APPLELOCALAI_FOLLOWUP_PROMPT='Using the receipt above, verify whether subtotal minus discount plus tax equals the charged total. Return only JSON with computed_total (number), charged_total (number), matches (boolean), and employee_reimbursement (number). Company policy: corporate-card expenses are not reimbursed to the employee.'
export APPLELOCALAI_FOLLOWUP_EXPECTED='{"computed_total":33,"charged_total":33,"matches":true,"employee_reimbursement":0}'
  : "${4:?Provide the receipt image generated from Tests/Fixtures/expense-receipt.txt}"
  export APPLELOCALAI_MODEL_IMAGE="$4"
fi
if [ "$runtime" = system ]; then
  exec ./script/verify_model.sh system
fi
exec ./script/verify_model.sh "$runtime" "$asset"
