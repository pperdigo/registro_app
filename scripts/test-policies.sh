#!/usr/bin/env bash
# Valida as políticas IAM e S3 geradas por scripts/lib/common.sh, sem acessar a AWS.
# Uso: scripts/test-policies.sh
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
require_cmds jq

set_names lab-teste sa-east-1 123456789012
SUB="repo:dono@1/repo@2"
FAILS=0
assert() {
  if jq -e "$2" <<<"$3" >/dev/null; then echo "ok   - $1"; else echo "FAIL - $1"; FAILS=$((FAILS + 1)); fi
}

deploy=$(github_deploy_policy)
trust=$(github_trust_policy "$SUB")
exec_trust=$(ecs_exec_trust_policy)
secrets=$(ecs_exec_secrets_policy)
site=$(site_bucket_policy)

# Ações que a AWS só aceita com Resource "*" (sem ARN de recurso).
WILDCARD_OK='["ecr:GetAuthorizationToken","ecs:RegisterTaskDefinition","ecs:DescribeTaskDefinition","ecs:ListTasks","ecs:DescribeTasks","ec2:DescribeNetworkInterfaces"]'

assert "deploy: nenhuma ação curinga" '[.Statement[].Action[] | select(test("\\*"))] | length == 0' "$deploy"
assert "deploy: Resource * só para ações sem suporte a ARN" \
  "[.Statement[] | select(.Resource == \"*\") | .Action[] | select(IN(${WILDCARD_OK}[]) | not)] | length == 0" "$deploy"
assert "deploy: não cria nem apaga infraestrutura" \
  '[.Statement[].Action[] | select(test("^(ec2:(Create|Delete|Run)|rds:|iam:(Create|Delete|Put|Attach)|ecs:(Create|Delete)|s3:(Create|DeleteBucket|PutBucket))"))] | length == 0' "$deploy"
assert "deploy: PassRole restrito à execution role e ao ECS" \
  '.Statement[] | select(.Action == ["iam:PassRole"]) |
   (.Resource | endswith(":role/registro-lab-teste-ecs-exec")) and
   .Condition.StringEquals["iam:PassedToService"] == "ecs-tasks.amazonaws.com"' "$deploy"
assert "deploy: RunTask condicionado ao cluster do ambiente" \
  '.Statement[] | select(.Action == ["ecs:RunTask"]) | .Condition.ArnEquals["ecs:cluster"] | endswith(":cluster/registro-lab-teste")' "$deploy"
assert "deploy: recursos com ARN pertencem ao ambiente" \
  '[.Statement[].Resource | select(. != "*") | select(test("registro-lab-teste|/registro/lab-teste") | not)] | length == 0' "$deploy"

assert "trust GitHub: subject exato do environment (sem curinga)" \
  ".Statement[0].Condition.StringEquals[\"token.actions.githubusercontent.com:sub\"] == \"$SUB:environment:lab\"" "$trust"
assert "trust GitHub: audience sts.amazonaws.com" \
  '.Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"' "$trust"
assert "trust GitHub: sem StringLike" '.Statement[0].Condition | has("StringLike") | not' "$trust"

assert "trust ECS: só ecs-tasks com SourceAccount" \
  '.Statement[0].Principal.Service == "ecs-tasks.amazonaws.com" and .Statement[0].Condition.StringEquals["aws:SourceAccount"] == "123456789012"' "$exec_trust"
assert "segredos: só os dois parâmetros do ambiente" \
  '.Statement[0].Action == ["ssm:GetParameters"] and (.Statement[0].Resource | length == 2) and
   all(.Statement[0].Resource[]; test(":parameter/registro/lab-teste/(db-password|jwt-secret)$"))' "$secrets"

assert "site: leitura pública só de objetos" \
  '(.Statement | length == 1) and .Statement[0].Action == "s3:GetObject" and (.Statement[0].Resource | endswith("/*"))' "$site"

# O deploy.sh bloqueia ACLs públicas no bucket e cria o RDS sem acesso público.
assert_file() {
  if grep -q "$2" "$ROOT/scripts/deploy.sh"; then echo "ok   - $1"; else echo "FAIL - $1"; FAILS=$((FAILS + 1)); fi
}
assert_file "bucket mantém ACLs públicas bloqueadas" 'BlockPublicAcls=true,IgnorePublicAcls=true'
assert_file "RDS criado sem acesso público" 'PubliclyAccessible: false'

((FAILS == 0)) || { echo "$FAILS verificação(ões) falharam"; exit 1; }
echo "Todas as políticas conferem"
