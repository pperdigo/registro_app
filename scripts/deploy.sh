#!/usr/bin/env bash
# Cria/atualiza o ambiente do laboratório na AWS e publica a aplicação.
#
# Uso:
#   Provisionamento explícito + publicação (local, credencial IAM/SSO):
#     scripts/deploy.sh --env lab-pedro --region sa-east-1 --account 969479836714 \
#       [--profile lab-pedro-deployer] [--github-repo pperdigo/registro_app] [--owner pedro]
#
#   Só publicação de uma imagem já validada (usado pelo GitHub Actions):
#     scripts/deploy.sh --env lab-pedro --region sa-east-1 --account 969479836714 \
#       --release-only --local-image registro-api:<sha> [--commit <sha>]
#
# --release-only nunca cria infraestrutura. Se o ambiente não estiver ativo
# (sem o parâmetro SSM de saídas), termina com código 3 e não recria nada.
# Este script nunca destrói recursos; para isso use scripts/destroy.sh.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }

ENV_ARG="" REGION_ARG="" ACCOUNT_ARG="" RELEASE_ONLY=false LOCAL_IMAGE="" COMMIT="" GITHUB_REPO=""
while (($#)); do
  case $1 in
    --env) ENV_ARG=${2:?}; shift 2 ;;
    --region) REGION_ARG=${2:?}; shift 2 ;;
    --account) ACCOUNT_ARG=${2:?}; shift 2 ;;
    --profile) export AWS_PROFILE=${2:?}; shift 2 ;;
    --owner) export OWNER=${2:?}; shift 2 ;;
    --github-repo) GITHUB_REPO=${2:?}; shift 2 ;;
    --release-only) RELEASE_ONLY=true; shift ;;
    --local-image) LOCAL_IMAGE=${2:?}; shift 2 ;;
    --commit) COMMIT=${2:?}; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage; die "Argumento desconhecido: $1" ;;
  esac
done
[[ -n $ENV_ARG && -n $REGION_ARG && -n $ACCOUNT_ARG ]] || { usage; die "--env, --region e --account são obrigatórios"; }
[[ $RELEASE_ONLY == false || -n $LOCAL_IMAGE ]] || die "--release-only exige --local-image"

require_cmds aws jq curl docker openssl
[[ $RELEASE_ONLY == true || -z $GITHUB_REPO ]] || require_cmds gh
export AWS_DEFAULT_REGION=$REGION_ARG AWS_PAGER=""
set_names "$ENV_ARG" "$REGION_ARG" "$ACCOUNT_ARG"
check_account
COMMIT=${COMMIT:-$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo manual)}

trap 'die "Falha na linha $LINENO: $BASH_COMMAND"' ERR

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

tag_spec() { printf 'ResourceType=%s,Tags=[{Key=Name,Value=%s},{Key=env,Value=%s},{Key=app,Value=%s},{Key=owner,Value=%s}]' \
  "$1" "$2" "$ENV_NAME" "$APP" "${OWNER:-lab}"; }

# Busca um recurso EC2 pelo par Name/env; imprime o id ou vazio.
ec2_find() {
  local kind=$1 query=$2 name=$3
  aws ec2 "describe-$kind" --filters "Name=tag:Name,Values=$name" "Name=tag:env,Values=$ENV_NAME" \
    --query "$query" --output text | sed 's/^None$//'
}

# ---------------------------------------------------------------- provisionamento

ensure_network() {
  log "Rede (VPC, sub-redes, internet gateway, security groups)"
  VPC_ID=$(ec2_find vpcs 'Vpcs[0].VpcId' "$PREFIX-vpc")
  if [[ -z $VPC_ID ]]; then
    VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" --tag-specifications "$(tag_spec vpc "$PREFIX-vpc")" \
      --query Vpc.VpcId --output text)
    aws ec2 wait vpc-available --vpc-ids "$VPC_ID"
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames
  fi

  IGW_ID=$(ec2_find internet-gateways 'InternetGateways[0].InternetGatewayId' "$PREFIX-igw")
  if [[ -z $IGW_ID ]]; then
    IGW_ID=$(aws ec2 create-internet-gateway --tag-specifications "$(tag_spec internet-gateway "$PREFIX-igw")" \
      --query InternetGateway.InternetGatewayId --output text)
  fi
  local attached
  attached=$(aws ec2 describe-internet-gateways --internet-gateway-ids "$IGW_ID" \
    --query 'InternetGateways[0].Attachments[0].VpcId' --output text)
  [[ $attached == "$VPC_ID" ]] || aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"

  local azs
  mapfile -t azs < <(aws ec2 describe-availability-zones --filters Name=state,Values=available \
    --query 'AvailabilityZones[].ZoneName' --output text | tr '\t' '\n' | sort)
  ((${#azs[@]} >= 2)) || die "A região precisa de pelo menos 2 AZs para o grupo de sub-redes do RDS"

  PUBLIC_SUBNET=$(ensure_subnet "$PREFIX-public-a" 10.42.0.0/24 "${azs[0]}")
  aws ec2 modify-subnet-attribute --subnet-id "$PUBLIC_SUBNET" --map-public-ip-on-launch
  PRIVATE_SUBNET_A=$(ensure_subnet "$PREFIX-private-a" 10.42.10.0/24 "${azs[0]}")
  PRIVATE_SUBNET_B=$(ensure_subnet "$PREFIX-private-b" 10.42.11.0/24 "${azs[1]}")

  # Tabela pública com rota para a internet; as privadas ficam na tabela principal (só rota local).
  local rt
  rt=$(ec2_find route-tables 'RouteTables[0].RouteTableId' "$PREFIX-public-rt")
  if [[ -z $rt ]]; then
    rt=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --tag-specifications "$(tag_spec route-table "$PREFIX-public-rt")" \
      --query RouteTable.RouteTableId --output text)
  fi
  aws ec2 create-route --route-table-id "$rt" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null 2>&1 ||
    aws ec2 replace-route --route-table-id "$rt" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID"
  local assoc
  assoc=$(aws ec2 describe-route-tables --route-table-ids "$rt" \
    --query "RouteTables[0].Associations[?SubnetId=='$PUBLIC_SUBNET'].RouteTableAssociationId" --output text)
  [[ -n $assoc ]] || aws ec2 associate-route-table --route-table-id "$rt" --subnet-id "$PUBLIC_SUBNET" >/dev/null

  API_SG=$(ensure_sg "$PREFIX-api-sg" "API do registro ($ENV_NAME): porta $API_PORT publica")
  DB_SG=$(ensure_sg "$PREFIX-db-sg" "Banco do registro ($ENV_NAME): so a partir das tasks")
  aws ec2 authorize-security-group-ingress --group-id "$API_SG" \
    --ip-permissions "IpProtocol=tcp,FromPort=$API_PORT,ToPort=$API_PORT,IpRanges=[{CidrIp=0.0.0.0/0,Description=api-publica}]" \
    >/dev/null 2>&1 || true
  aws ec2 authorize-security-group-ingress --group-id "$DB_SG" \
    --ip-permissions "IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs=[{GroupId=$API_SG,Description=tasks-api}]" \
    >/dev/null 2>&1 || true
}

ensure_subnet() {
  local name=$1 cidr=$2 az=$3 id
  id=$(ec2_find subnets 'Subnets[0].SubnetId' "$name")
  if [[ -z $id ]]; then
    id=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$cidr" --availability-zone "$az" \
      --tag-specifications "$(tag_spec subnet "$name")" --query Subnet.SubnetId --output text)
  fi
  echo "$id"
}

ensure_sg() {
  local name=$1 desc=$2 id
  id=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$name" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text | sed 's/^None$//')
  if [[ -z $id ]]; then
    id=$(aws ec2 create-security-group --group-name "$name" --description "$desc" --vpc-id "$VPC_ID" \
      --tag-specifications "$(tag_spec security-group "$name")" --query GroupId --output text)
  fi
  echo "$id"
}

ssm_param_exists() { aws ssm get-parameter --name "$1" >/dev/null 2>&1; }

ensure_secrets() {
  log "Segredos no SSM Parameter Store (SecureString)"
  local name
  for name in db-password jwt-secret; do
    if ! ssm_param_exists "$SSM_PREFIX/$name"; then
      aws ssm put-parameter --name "$SSM_PREFIX/$name" --type SecureString \
        --value "$(openssl rand -hex 24)" --tags "${TAGS_CLI[@]}" >/dev/null
    fi
  done
}

ensure_database() {
  log "RDS PostgreSQL ($DB_ID, db.t4g.micro, Single-AZ, privado)"
  if ! aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP" >/dev/null 2>&1; then
    aws rds create-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP" \
      --db-subnet-group-description "Sub-redes privadas do banco ($ENV_NAME)" \
      --subnet-ids "$PRIVATE_SUBNET_A" "$PRIVATE_SUBNET_B" --tags "${TAGS_CLI[@]}" >/dev/null
  fi

  local status
  status=$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
    --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo absent)
  if [[ $status == absent ]]; then
    local version
    version=$(aws rds describe-orderable-db-instance-options --engine postgres --db-instance-class db.t4g.micro \
      --query "OrderableDBInstanceOptions[?starts_with(EngineVersion,'16.')].EngineVersion" --output text |
      tr '\t' '\n' | sort -uV | tail -1)
    [[ -n $version ]] || die "PostgreSQL 16 indisponível em db.t4g.micro nesta região"
    # A senha vai por arquivo (0600), não pela linha de comando.
    jq -n --arg id "$DB_ID" --arg v "$version" --arg user "$DB_USER" --arg db "$DB_NAME" \
      --arg pw "$(aws ssm get-parameter --name "$SSM_PREFIX/db-password" --with-decryption --query Parameter.Value --output text)" \
      --arg sng "$DB_SUBNET_GROUP" --arg sg "$DB_SG" --arg env "$ENV_NAME" --arg app "$APP" --arg owner "${OWNER:-lab}" '
      {DBInstanceIdentifier: $id, Engine: "postgres", EngineVersion: $v, DBInstanceClass: "db.t4g.micro",
       AllocatedStorage: 20, StorageType: "gp3", StorageEncrypted: true, MultiAZ: false,
       MasterUsername: $user, MasterUserPassword: $pw, DBName: $db,
       DBSubnetGroupName: $sng, VpcSecurityGroupIds: [$sg], PubliclyAccessible: false,
       BackupRetentionPeriod: 0, DeletionProtection: false, AutoMinorVersionUpgrade: true,
       Tags: [{Key: "env", Value: $env}, {Key: "app", Value: $app}, {Key: "owner", Value: $owner}]}' \
      >"$TMP/db.json"
    chmod 600 "$TMP/db.json"
    aws rds create-db-instance --cli-input-json "file://$TMP/db.json" >/dev/null
    rm -f "$TMP/db.json"
    log "Aguardando o banco ficar disponível (5 a 10 minutos)"
  fi
  aws rds wait db-instance-available --db-instance-identifier "$DB_ID"
  DB_HOST=$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
    --query 'DBInstances[0].Endpoint.Address' --output text)
}

ensure_exec_role() {
  log "IAM: execution role das tasks ($EXEC_ROLE)"
  if ! aws iam get-role --role-name "$EXEC_ROLE" >/dev/null 2>&1; then
    aws iam create-role --role-name "$EXEC_ROLE" --assume-role-policy-document "$(ecs_exec_trust_policy)" \
      --tags "${TAGS_CLI[@]}" >/dev/null
  fi
  aws iam attach-role-policy --role-name "$EXEC_ROLE" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
  aws iam put-role-policy --role-name "$EXEC_ROLE" --policy-name read-secrets \
    --policy-document "$(ecs_exec_secrets_policy)"
}

ensure_registry_and_cluster() {
  log "ECR, logs e cluster ECS"
  if ! aws ecr describe-repositories --repository-names "$ECR_REPO" >/dev/null 2>&1; then
    aws ecr create-repository --repository-name "$ECR_REPO" --image-scanning-configuration scanOnPush=true \
      --image-tag-mutability IMMUTABLE --tags "${TAGS_CLI[@]}" >/dev/null
  fi
  aws ecr put-lifecycle-policy --repository-name "$ECR_REPO" --lifecycle-policy-text \
    '{"rules":[{"rulePriority":1,"description":"mantem 10 imagens","selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":10},"action":{"type":"expire"}}]}' >/dev/null

  aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --query 'logGroups[].logGroupName' --output text |
    tr '\t' '\n' | grep -qx "$LOG_GROUP" || aws logs create-log-group --log-group-name "$LOG_GROUP" \
    --tags "env=$ENV_NAME,app=$APP"
  aws logs put-retention-policy --log-group-name "$LOG_GROUP" --retention-in-days 1

  local cstatus
  cstatus=$(aws ecs describe-clusters --clusters "$CLUSTER" --query 'clusters[0].status' --output text)
  [[ $cstatus == ACTIVE ]] || aws ecs create-cluster --cluster-name "$CLUSTER" --tags "key=env,value=$ENV_NAME" \
    "key=app,value=$APP" >/dev/null
}

ensure_site_bucket() {
  log "Bucket do site ($BUCKET, S3 Static Website Hosting)"
  if ! aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
    aws s3api create-bucket --bucket "$BUCKET" --create-bucket-configuration "LocationConstraint=$REGION" \
      --object-ownership BucketOwnerEnforced >/dev/null
  fi
  aws s3api put-bucket-tagging --bucket "$BUCKET" \
    --tagging "TagSet=[{Key=env,Value=$ENV_NAME},{Key=app,Value=$APP},{Key=owner,Value=${OWNER:-lab}}]"
  # ACLs continuam bloqueadas; só a policy de leitura pública é permitida.
  aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false
  aws s3api put-bucket-policy --bucket "$BUCKET" --policy "$(site_bucket_policy)"
  aws s3api put-bucket-website --bucket "$BUCKET" \
    --website-configuration '{"IndexDocument":{"Suffix":"index.html"},"ErrorDocument":{"Key":"index.html"}}'
}

ensure_github() {
  [[ -n $GITHUB_REPO ]] || return 0
  log "GitHub Actions: role OIDC ($GH_ROLE) e variáveis do environment '$GH_ENVIRONMENT'"
  local provider=arn:aws:iam::$ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com
  # Provedor compartilhado da conta: reutiliza, e o destroy.sh nunca o remove.
  if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$provider" >/dev/null 2>&1; then
    aws iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com \
      --client-id-list sts.amazonaws.com >/dev/null
  fi
  local sub_prefix
  sub_prefix=$(gh api "repos/$GITHUB_REPO/actions/oidc/customization/sub" --jq '.sub_claim_prefix // empty')
  [[ -n $sub_prefix ]] || sub_prefix="repo:$GITHUB_REPO"
  if aws iam get-role --role-name "$GH_ROLE" >/dev/null 2>&1; then
    aws iam update-assume-role-policy --role-name "$GH_ROLE" --policy-document "$(github_trust_policy "$sub_prefix")"
  else
    aws iam create-role --role-name "$GH_ROLE" --assume-role-policy-document "$(github_trust_policy "$sub_prefix")" \
      --max-session-duration 3600 --tags "${TAGS_CLI[@]}" >/dev/null
  fi
  aws iam put-role-policy --role-name "$GH_ROLE" --policy-name deploy --policy-document "$(github_deploy_policy)"

  gh api -X PUT "repos/$GITHUB_REPO/environments/$GH_ENVIRONMENT" \
    -F 'deployment_branch_policy[protected_branches]=false' -F 'deployment_branch_policy[custom_branch_policies]=true' >/dev/null
  gh api -X POST "repos/$GITHUB_REPO/environments/$GH_ENVIRONMENT/deployment-branch-policies" \
    -f name=main -f type=branch >/dev/null 2>&1 || true
  local k v
  for k in AWS_ROLE_ARN AWS_REGION AWS_ACCOUNT_ID APP_ENV; do
    case $k in
      AWS_ROLE_ARN) v=arn:aws:iam::$ACCOUNT_ID:role/$GH_ROLE ;;
      AWS_REGION) v=$REGION ;;
      AWS_ACCOUNT_ID) v=$ACCOUNT_ID ;;
      APP_ENV) v=$ENV_NAME ;;
    esac
    gh variable set "$k" --repo "$GITHUB_REPO" --env "$GH_ENVIRONMENT" --body "$v"
  done
}

save_outputs() {
  jq -n --arg subnet "$PUBLIC_SUBNET" --arg sg "$API_SG" --arg dbhost "$DB_HOST" \
    '{publicSubnet: $subnet, apiSecurityGroup: $sg, dbHost: $dbhost}' >"$TMP/outputs.json"
  aws ssm put-parameter --name "$SSM_OUTPUTS" --type String --overwrite \
    --value "file://$TMP/outputs.json" >/dev/null
}

# ---------------------------------------------------------------- publicação

load_outputs() {
  local out
  if ! out=$(aws ssm get-parameter --name "$SSM_OUTPUTS" --query Parameter.Value --output text 2>/dev/null); then
    warn "Ambiente '$ENV_NAME' não está ativo (laboratório encerrado ou nunca provisionado)."
    warn "Nada foi criado. Para provisionar, execute scripts/deploy.sh localmente sem --release-only."
    exit 3
  fi
  PUBLIC_SUBNET=$(jq -r .publicSubnet <<<"$out")
  API_SG=$(jq -r .apiSecurityGroup <<<"$out")
  DB_HOST=$(jq -r .dbHost <<<"$out")
}

push_image() {
  local registry=$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com source=$LOCAL_IMAGE
  if [[ -z $source ]]; then
    source=$PREFIX-api:$COMMIT
    log "Build da imagem da API ($source, linux/amd64)"
    docker build --platform linux/amd64 -t "$source" "$ROOT/api"
  fi
  local target=$registry/$ECR_REPO:$COMMIT
  log "Publicando $source no ECR como $target"
  aws ecr get-login-password | docker login --username AWS --password-stdin "$registry" >/dev/null
  if aws ecr describe-images --repository-name "$ECR_REPO" --image-ids "imageTag=$COMMIT" >/dev/null 2>&1; then
    log "Tag $COMMIT já existe no ECR (tags imutáveis); reutilizando"
  else
    docker tag "$source" "$target"
    docker push "$target" >/dev/null
  fi
  local digest
  digest=$(aws ecr describe-images --repository-name "$ECR_REPO" --image-ids "imageTag=$COMMIT" \
    --query 'imageDetails[0].imageDigest' --output text)
  IMAGE_URI=$registry/$ECR_REPO@$digest
}

register_task_def() {
  log "Registrando task definition com $IMAGE_URI"
  jq -n --arg family "$TASK_FAMILY" --arg image "$IMAGE_URI" --arg exec "arn:aws:iam::$ACCOUNT_ID:role/$EXEC_ROLE" \
    --arg logs "$LOG_GROUP" --arg region "$REGION" --arg dbhost "$DB_HOST" --arg db "$DB_NAME" --arg user "$DB_USER" \
    --arg origin "$SITE_URL" --arg ssm "arn:aws:ssm:$REGION:$ACCOUNT_ID:parameter$SSM_PREFIX" \
    --arg commit "$COMMIT" --argjson port "$API_PORT" '
    {family: $family, networkMode: "awsvpc", requiresCompatibilities: ["FARGATE"],
     cpu: "256", memory: "512", executionRoleArn: $exec,
     runtimePlatform: {cpuArchitecture: "X86_64", operatingSystemFamily: "LINUX"},
     containerDefinitions: [{
       name: "api", image: $image, essential: true,
       portMappings: [{containerPort: $port, protocol: "tcp"}],
       environment: [
         {name: "PORT", value: ($port|tostring)}, {name: "NODE_ENV", value: "production"},
         {name: "PGHOST", value: $dbhost}, {name: "PGPORT", value: "5432"},
         {name: "PGDATABASE", value: $db}, {name: "PGUSER", value: $user},
         {name: "DB_SSL", value: "true"}, {name: "CORS_ORIGIN", value: $origin},
         {name: "APP_COMMIT", value: $commit}],
       secrets: [
         {name: "PGPASSWORD", valueFrom: "\($ssm)/db-password"},
         {name: "JWT_SECRET", valueFrom: "\($ssm)/jwt-secret"}],
       healthCheck: {command: ["CMD-SHELL", "wget -qO- http://127.0.0.1:\($port)/api/health || exit 1"],
                     interval: 10, timeout: 3, retries: 3, startPeriod: 10},
       logConfiguration: {logDriver: "awslogs", options: {
         "awslogs-group": $logs, "awslogs-region": $region, "awslogs-stream-prefix": "api"}}
     }]}' >"$TMP/taskdef.json"
  TASK_DEF_ARN=$(aws ecs register-task-definition --cli-input-json "file://$TMP/taskdef.json" \
    --query taskDefinition.taskDefinitionArn --output text)
}

network_config() {
  printf 'awsvpcConfiguration={subnets=[%s],securityGroups=[%s],assignPublicIp=ENABLED}' "$PUBLIC_SUBNET" "$API_SG"
}

run_migrations() {
  log "Migrations em task única (mesma imagem)"
  local task exit_code reason
  task=$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$TASK_DEF_ARN" --launch-type FARGATE \
    --network-configuration "$(network_config)" --started-by "migrate-$COMMIT" \
    --overrides '{"containerOverrides":[{"name":"api","command":["node","src/migrate.js"]}]}' \
    --query 'tasks[0].taskArn' --output text)
  [[ $task == arn:* ]] || die "Não foi possível iniciar a task de migration"
  aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$task"
  exit_code=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$task" \
    --query 'tasks[0].containers[0].exitCode' --output text)
  reason=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$task" --query 'tasks[0].stoppedReason' --output text)
  if [[ $exit_code != 0 ]]; then
    warn "Logs da migration:"
    aws logs get-log-events --log-group-name "$LOG_GROUP" --log-stream-name "api/api/${task##*/}" \
      --query 'events[].message' --output text 2>/dev/null | tr '\t' '\n' >&2 || true
    die "Migration falhou (exit=$exit_code, motivo: $reason). Serviço não foi atualizado."
  fi
  log "Migrations concluídas"
}

deploy_service() {
  local status
  status=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
    --query 'services[0].status' --output text 2>/dev/null || echo MISSING)
  if [[ $status == ACTIVE ]]; then
    log "Atualizando o serviço ECS"
    aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --task-definition "$TASK_DEF_ARN" \
      --desired-count 1 >/dev/null
  else
    [[ $RELEASE_ONLY == false ]] || die "Serviço ECS ausente; provisione localmente antes"
    log "Criando o serviço ECS"
    aws ecs create-service --cluster "$CLUSTER" --service-name "$SERVICE" --task-definition "$TASK_DEF_ARN" \
      --desired-count 1 --launch-type FARGATE --network-configuration "$(network_config)" \
      --deployment-configuration 'minimumHealthyPercent=100,maximumPercent=200,deploymentCircuitBreaker={enable=true,rollback=true}' \
      --tags "key=env,value=$ENV_NAME" "key=app,value=$APP" >/dev/null
  fi

  # services-stable pode retornar antes do fim do rollout: acompanha o rolloutState.
  log "Aguardando o rollout (COMPLETED ou FAILED)"
  local i state primary
  for ((i = 0; i < 90; i++)); do
    read -r state primary < <(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
      --query "services[0].deployments[?status=='PRIMARY'] | [0].[rolloutState, taskDefinition]" --output text)
    case $state in
      COMPLETED) break ;;
      FAILED) die "Rollout FAILED; o circuit breaker mantém a versão anterior. Veja os logs em $LOG_GROUP" ;;
    esac
    sleep 10
  done
  [[ $state == COMPLETED ]] || die "Rollout não concluiu em 15 minutos (estado: $state)"
  [[ $primary == "$TASK_DEF_ARN" ]] || die "Revisão primária é $primary, não a nova ($TASK_DEF_ARN): houve rollback"
}

discover_api_url() {
  local task eni
  task=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" --desired-status RUNNING \
    --query 'taskArns' --output json |
    jq -r '.[]' | while read -r t; do
      aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$t" \
        --query "tasks[?taskDefinitionArn=='$TASK_DEF_ARN' && lastStatus=='RUNNING' && healthStatus=='HEALTHY'].taskArn" \
        --output text
    done | head -1)
  [[ -n $task ]] || die "Nenhuma task saudável da nova revisão encontrada"
  eni=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$task" \
    --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value" --output text)
  API_IP=$(aws ec2 describe-network-interfaces --network-interface-ids "$eni" \
    --query 'NetworkInterfaces[0].Association.PublicIp' --output text)
  [[ $API_IP =~ ^[0-9.]+$ ]] || die "Task sem IPv4 público"
  API_URL=http://$API_IP:$API_PORT
}

publish_frontend() {
  log "Publicando o frontend em $SITE_URL"
  mkdir -p "$TMP/site"
  cp "$ROOT/frontend/index.html" "$ROOT/frontend/style.css" "$ROOT/frontend/app.js" "$TMP/site/"
  jq -n --arg api "$API_URL" --arg v "$COMMIT" '{apiBaseUrl: $api, version: $v}' |
    sed '1s/^/window.APP_CONFIG = /; $s/$/;/' >"$TMP/site/config.js"
  # Sem CDN na frente: no-cache faz o navegador revalidar e ver a versão nova.
  aws s3 sync "$TMP/site" "s3://$BUCKET/" --delete --cache-control "no-cache, max-age=0" >/dev/null
}

smoke_test() {
  log "Verificação funcional"
  local email body token failures=0
  check() {
    if eval "$2"; then log "  ok: $1"; else warn "  FALHOU: $1"; failures=$((failures + 1)); fi
  }
  check "API /api/health" "curl -fsS --max-time 10 '$API_URL/api/health' | grep -q '\"ok\":true'"
  check "site serve index.html" "curl -fsS --max-time 10 '$SITE_URL/' | grep -q 'config.js'"
  check "site aponta para a API nova" "curl -fsS --max-time 10 '$SITE_URL/config.js' | grep -q '$API_URL'"
  check "CORS libera a origem do site" \
    "curl -fsS -o /dev/null -D - -H 'Origin: $SITE_URL' '$API_URL/api/health' | grep -qi 'access-control-allow-origin: $SITE_URL'"
  email="smoke-$(date +%s)@lab.invalid"
  body=$(curl -sS --max-time 10 -H 'Content-Type: application/json' -X POST "$API_URL/api/register" \
    -d "{\"name\":\"Smoke $COMMIT\",\"email\":\"$email\",\"password\":\"smoke-$RANDOM-ok\"}" || true)
  token=$(jq -r '.token // empty' <<<"$body" 2>/dev/null || true)
  check "cadastro persiste no banco" "[[ -n '$token' ]]"
  check "/api/me lê o registro" \
    "curl -fsS --max-time 10 -H 'Authorization: Bearer $token' '$API_URL/api/me' | grep -q '$email'"
  SMOKE_FAILURES=$failures
}

summary() {
  local result=$1
  local text
  text=$(
    cat <<EOF
### Deploy \`$ENV_NAME\` — $result

| Item | Valor |
| --- | --- |
| Commit | \`$COMMIT\` |
| Site | $SITE_URL |
| API | $API_URL |
| Imagem | \`$IMAGE_URI\` |
| Task definition | \`${TASK_DEF_ARN##*/}\` |
| Falhas na verificação | ${SMOKE_FAILURES:-?} |

Logs: \`aws logs tail $LOG_GROUP --follow --region $REGION\`
EOF
  )
  echo "$text"
  [[ -z ${GITHUB_STEP_SUMMARY:-} ]] || echo "$text" >>"$GITHUB_STEP_SUMMARY"
}

# ---------------------------------------------------------------- main

if [[ $RELEASE_ONLY == true ]]; then
  load_outputs
else
  warn "O site e a API usam HTTP sem TLS: aceitável só com os dados sintéticos do laboratório."
  ensure_network
  ensure_secrets
  ensure_exec_role
  ensure_registry_and_cluster
  ensure_site_bucket
  ensure_database
  ensure_github
  save_outputs
fi

push_image
register_task_def
run_migrations
deploy_service
discover_api_url
publish_frontend
smoke_test

if ((SMOKE_FAILURES > 0)); then
  summary "FALHOU"
  die "$SMOKE_FAILURES verificação(ões) falharam após o deploy"
fi
summary "OK"
log "Aplicação disponível em $SITE_URL"
