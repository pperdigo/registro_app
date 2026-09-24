#!/usr/bin/env bash
# Remove todos os recursos exclusivos de um ambiente do laboratório, INCLUINDO
# o banco e os dados de teste (sem snapshot final e sem backups retidos).
#
# Uso:
#   scripts/destroy.sh --env lab-pedro --region sa-east-1 --account 969479836714 \
#     [--profile lab-pedro-deployer] [--github-repo pperdigo/registro_app] [--yes]
#
# Sem --yes, pede que o nome do ambiente seja digitado para confirmar.
# --yes é a opção não interativa, para o agente usar depois de a pessoa
# confirmar o encerramento na conversa.
#
# Preserva recursos compartilhados: o provedor OIDC do GitHub da conta e
# qualquer recurso sem as tags deste ambiente. Tolera recursos já removidos.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }

ENV_ARG="" REGION_ARG="" ACCOUNT_ARG="" YES=false GITHUB_REPO=""
while (($#)); do
  case $1 in
    --env) ENV_ARG=${2:?}; shift 2 ;;
    --region) REGION_ARG=${2:?}; shift 2 ;;
    --account) ACCOUNT_ARG=${2:?}; shift 2 ;;
    --profile) export AWS_PROFILE=${2:?}; shift 2 ;;
    --github-repo) GITHUB_REPO=${2:?}; shift 2 ;;
    --yes) YES=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage; die "Argumento desconhecido: $1" ;;
  esac
done
[[ -n $ENV_ARG && -n $REGION_ARG && -n $ACCOUNT_ARG ]] || { usage; die "--env, --region e --account são obrigatórios"; }

require_cmds aws jq
[[ -z $GITHUB_REPO ]] || require_cmds gh
export AWS_DEFAULT_REGION=$REGION_ARG AWS_PAGER=""
set_names "$ENV_ARG" "$REGION_ARG" "$ACCOUNT_ARG"
check_account

warn "Isto remove o ambiente '$ENV_NAME' em $REGION, incluindo o banco $DB_ID e TODOS os dados de teste."
if [[ $YES != true ]]; then
  read -r -p "Digite o nome do ambiente para confirmar: " answer
  [[ $answer == "$ENV_NAME" ]] || die "Confirmação não confere; nada foi removido"
fi

FAILURES=()
# Executa uma remoção; "não encontrado" conta como já removido.
try() {
  local what=$1 out
  shift
  if out=$("$@" 2>&1); then
    log "removido: $what"
  elif grep -qiE 'not ?found|does not exist|NoSuch|InvalidGroup.NotFound|InvalidVpcID|InvalidSubnetID|ClusterNotFound|ServiceNotFound|RepositoryNotFound|ParameterNotFound|DBInstanceNotFound|DBSubnetGroupNotFound|ResourceNotFound|InvalidInternetGatewayID|InvalidRouteTableID' <<<"$out"; then
    log "já ausente: $what"
  else
    warn "falha ao remover $what: $out"
    FAILURES+=("$what")
  fi
}

ec2_ids() {
  aws ec2 "describe-$1" --filters "Name=tag:env,Values=$ENV_NAME" "Name=tag:app,Values=$APP" "${@:3}" \
    --query "$2" --output text | tr '\t' '\n' | sed '/^None$/d;/^$/d'
}

# 1. GitHub: sem variáveis, os workflows informam que o laboratório está encerrado.
if [[ -n $GITHUB_REPO ]]; then
  for k in AWS_ROLE_ARN AWS_REGION AWS_ACCOUNT_ID APP_ENV; do
    try "variável GitHub $k" gh variable delete "$k" --repo "$GITHUB_REPO" --env "$GH_ENVIRONMENT"
  done
fi

# 2. ECS: serviço, tasks avulsas, task definitions e cluster.
if [[ $(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query 'services[0].status' \
  --output text 2>/dev/null) == ACTIVE ]]; then
  aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --desired-count 0 >/dev/null
  try "serviço ECS $SERVICE" aws ecs delete-service --cluster "$CLUSTER" --service "$SERVICE" --force
  aws ecs wait services-inactive --cluster "$CLUSTER" --services "$SERVICE" || true
fi
for t in $(aws ecs list-tasks --cluster "$CLUSTER" --query 'taskArns' --output text 2>/dev/null | sed 's/^None$//'); do
  try "task ${t##*/}" aws ecs stop-task --cluster "$CLUSTER" --task "$t"
done
mapfile -t tds < <(aws ecs list-task-definitions --family-prefix "$TASK_FAMILY" --query 'taskDefinitionArns' \
  --output text | tr '\t' '\n' | sed '/^$/d')
mapfile -t tds_inactive < <(aws ecs list-task-definitions --family-prefix "$TASK_FAMILY" --status INACTIVE \
  --query 'taskDefinitionArns' --output text | tr '\t' '\n' | sed '/^$/d')
for td in "${tds[@]}"; do
  try "registro da task definition ${td##*/}" aws ecs deregister-task-definition --task-definition "$td"
done
all_tds=("${tds[@]}" "${tds_inactive[@]}")
for ((i = 0; i < ${#all_tds[@]}; i += 10)); do
  try "task definitions (lote $((i / 10 + 1)))" aws ecs delete-task-definitions --task-definitions "${all_tds[@]:i:10}"
done
try "cluster ECS $CLUSTER" aws ecs delete-cluster --cluster "$CLUSTER"

# 3. RDS: sem snapshot final e sem backups automáticos retidos.
if aws rds describe-db-instances --db-instance-identifier "$DB_ID" >/dev/null 2>&1; then
  try "banco RDS $DB_ID" aws rds delete-db-instance --db-instance-identifier "$DB_ID" \
    --skip-final-snapshot --delete-automated-backups
  log "Aguardando a remoção do banco (alguns minutos)"
  aws rds wait db-instance-deleted --db-instance-identifier "$DB_ID" || FAILURES+=("espera do RDS")
else
  log "já ausente: banco RDS $DB_ID"
fi
try "grupo de sub-redes $DB_SUBNET_GROUP" aws rds delete-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP"

# 4. Site, imagens, logs e parâmetros.
if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  aws s3 rm "s3://$BUCKET" --recursive >/dev/null
  # Remove também versões e marcadores, caso o versionamento tenha sido ligado.
  aws s3api list-object-versions --bucket "$BUCKET" --output json |
    jq -c '[(.Versions // [])[], (.DeleteMarkers // [])[] | {Key, VersionId}] | select(length > 0) | {Objects: .}' |
    while read -r batch; do aws s3api delete-objects --bucket "$BUCKET" --delete "$batch" >/dev/null; done
  try "bucket $BUCKET" aws s3api delete-bucket --bucket "$BUCKET"
else
  log "já ausente: bucket $BUCKET"
fi
try "repositório ECR $ECR_REPO" aws ecr delete-repository --repository-name "$ECR_REPO" --force
try "log group $LOG_GROUP" aws logs delete-log-group --log-group-name "$LOG_GROUP"
for p in db-password jwt-secret outputs; do
  try "parâmetro SSM $SSM_PREFIX/$p" aws ssm delete-parameter --name "$SSM_PREFIX/$p"
done

# 5. IAM: roles do ambiente (o provedor OIDC da conta é preservado).
delete_role() {
  local role=$1 p
  aws iam get-role --role-name "$role" >/dev/null 2>&1 || { log "já ausente: role $role"; return 0; }
  for p in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames' --output text); do
    aws iam delete-role-policy --role-name "$role" --policy-name "$p"
  done
  for p in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-role-policy --role-name "$role" --policy-arn "$p"
  done
  try "role $role" aws iam delete-role --role-name "$role"
}
delete_role "$GH_ROLE"
delete_role "$EXEC_ROLE"

# 6. Rede: espera as ENIs das tasks sumirem antes de apagar SGs e sub-redes.
VPC_ID=$(ec2_ids vpcs 'Vpcs[].VpcId' "Name=tag:Name,Values=$PREFIX-vpc" | head -1)
if [[ -n $VPC_ID ]]; then
  for ((i = 0; i < 30; i++)); do
    enis=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" \
      --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)
    [[ -z $enis ]] && break
    sleep 10
  done
  [[ -z $enis ]] || warn "ENIs ainda presentes na VPC: $enis"
  for sg in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:env,Values=$ENV_NAME" \
    --query 'SecurityGroups[].GroupId' --output text); do
    # Remove as regras cruzadas antes (o SG do banco referencia o da API).
    aws ec2 revoke-security-group-ingress --group-id "$sg" --ip-permissions \
      "$(aws ec2 describe-security-groups --group-ids "$sg" --query 'SecurityGroups[0].IpPermissions' --output json)" \
      >/dev/null 2>&1 || true
  done
  for sg in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:env,Values=$ENV_NAME" \
    --query 'SecurityGroups[].GroupId' --output text); do
    try "security group $sg" aws ec2 delete-security-group --group-id "$sg"
  done
  for subnet in $(ec2_ids subnets 'Subnets[].SubnetId' "Name=vpc-id,Values=$VPC_ID"); do
    try "sub-rede $subnet" aws ec2 delete-subnet --subnet-id "$subnet"
  done
  for rt in $(ec2_ids route-tables 'RouteTables[].RouteTableId' "Name=vpc-id,Values=$VPC_ID"); do
    for a in $(aws ec2 describe-route-tables --route-table-ids "$rt" \
      --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' --output text); do
      aws ec2 disassociate-route-table --association-id "$a" || true
    done
    try "tabela de rotas $rt" aws ec2 delete-route-table --route-table-id "$rt"
  done
  for igw in $(ec2_ids internet-gateways 'InternetGateways[].InternetGatewayId'); do
    aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$VPC_ID" >/dev/null 2>&1 || true
    try "internet gateway $igw" aws ec2 delete-internet-gateway --internet-gateway-id "$igw"
  done
  try "VPC $VPC_ID" aws ec2 delete-vpc --vpc-id "$VPC_ID"
else
  log "já ausente: VPC $PREFIX-vpc"
fi

# 7. Conferência por identificador.
log "Conferindo recursos remanescentes"
LEFT=()
remains() { LEFT+=("$1"); warn "  remanescente: $1"; }
! aws rds describe-db-instances --db-instance-identifier "$DB_ID" >/dev/null 2>&1 || remains "RDS $DB_ID"
[[ -z $(aws rds describe-db-snapshots --db-instance-identifier "$DB_ID" --query 'DBSnapshots[].DBSnapshotIdentifier' \
  --output text 2>/dev/null) ]] || remains "snapshots do RDS $DB_ID"
[[ -z $(aws rds describe-db-instance-automated-backups --db-instance-identifier "$DB_ID" \
  --query 'DBInstanceAutomatedBackups[].DbiResourceId' --output text 2>/dev/null) ]] || remains "backups retidos do RDS"
[[ $(aws ecs describe-clusters --clusters "$CLUSTER" --query 'clusters[0].status' --output text 2>/dev/null) != ACTIVE ]] ||
  remains "cluster ECS $CLUSTER"
! aws ecr describe-repositories --repository-names "$ECR_REPO" >/dev/null 2>&1 || remains "ECR $ECR_REPO"
! aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1 || remains "bucket $BUCKET"
[[ -z $(aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --query 'logGroups[].logGroupName' --output text) ]] ||
  remains "log group $LOG_GROUP"
[[ -z $(aws ssm get-parameters-by-path --path "$SSM_PREFIX" --query 'Parameters[].Name' --output text) ]] ||
  remains "parâmetros SSM em $SSM_PREFIX"
for r in "$GH_ROLE" "$EXEC_ROLE"; do ! aws iam get-role --role-name "$r" >/dev/null 2>&1 || remains "role $r"; done
[[ -z $(ec2_ids vpcs 'Vpcs[].VpcId') ]] || remains "VPC do ambiente"
[[ -z $(ec2_ids network-interfaces 'NetworkInterfaces[].NetworkInterfaceId') ]] || remains "ENIs do ambiente"
[[ -z $(aws ec2 describe-addresses --filters "Name=tag:env,Values=$ENV_NAME" --query 'Addresses[].PublicIp' --output text) ]] ||
  remains "Elastic IPs do ambiente"
log "Preservado (compartilhado): provedor OIDC token.actions.githubusercontent.com"

if ((${#FAILURES[@]} + ${#LEFT[@]} > 0)); then
  die "Encerramento incompleto. Falhas: ${FAILURES[*]:-nenhuma}. Remanescentes: ${LEFT[*]:-nenhum}"
fi
log "Ambiente '$ENV_NAME' removido. Cobranças podem aparecer no faturamento com atraso de algumas horas."
