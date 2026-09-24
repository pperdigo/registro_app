# shellcheck shell=bash disable=SC2034
# Funções e nomes compartilhados por deploy.sh, destroy.sh e pelo CI.
# Carregado com `source`; não executa nada por conta própria.

APP=registro

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[aviso]\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31m[erro]\033[0m %s\n' "$*" >&2
  exit 1
}

require_cmds() {
  local c missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  ((${#missing[@]} == 0)) || die "Ferramentas ausentes: ${missing[*]}"
}

# Define todos os nomes a partir do ambiente, região e conta.
# Um ambiente por grupo: nomes e tags nunca colidem entre pessoas na mesma conta.
set_names() {
  local env=$1 region=$2 account=$3
  [[ $env =~ ^[a-z0-9-]{3,20}$ ]] || die "Ambiente inválido: '$env' (use a-z, 0-9 e '-', 3 a 20 caracteres)"
  ENV_NAME=$env
  REGION=$region
  ACCOUNT_ID=$account
  PREFIX="$APP-$env"
  VPC_CIDR=10.42.0.0/16
  CLUSTER=$PREFIX
  SERVICE="$PREFIX-api"
  TASK_FAMILY="$PREFIX-api"
  ECR_REPO="$PREFIX-api"
  LOG_GROUP="/ecs/$PREFIX"
  DB_ID=$PREFIX
  DB_SUBNET_GROUP="$PREFIX-db"
  DB_NAME=registro
  DB_USER=app
  BUCKET="$PREFIX-site-$account"
  SITE_URL="http://$BUCKET.s3-website-$region.amazonaws.com"
  SSM_PREFIX="/$APP/$env"
  SSM_OUTPUTS="$SSM_PREFIX/outputs"
  EXEC_ROLE="$PREFIX-ecs-exec"
  GH_ROLE="$PREFIX-github-deploy"
  GH_ENVIRONMENT=lab
  API_PORT=3000
  TAGS_CLI=("Key=env,Value=$env" "Key=app,Value=$APP" "Key=owner,Value=${OWNER:-lab}")
}

# Confere a identidade autenticada antes de qualquer alteração.
check_account() {
  local actual arn
  actual=$(aws sts get-caller-identity --query Account --output text) || die "Sem credenciais AWS válidas"
  arn=$(aws sts get-caller-identity --query Arn --output text)
  [[ $actual == "$ACCOUNT_ID" ]] || die "Conta autenticada $actual difere da esperada $ACCOUNT_ID"
  [[ $arn == *":root" ]] && die "Credencial root detectada; use um usuário/role IAM"
  log "Conta $ACCOUNT_ID, identidade $arn, região $REGION"
}

# Política da role do GitHub Actions: só publica versões num ambiente já
# provisionado (ECR, task definition, migration, serviço, site). Não cria
# infraestrutura; o provisionamento é explícito e local.
github_deploy_policy() {
  jq -n \
    --arg region "$REGION" --arg acct "$ACCOUNT_ID" --arg repo "$ECR_REPO" \
    --arg cluster "$CLUSTER" --arg service "$SERVICE" --arg family "$TASK_FAMILY" \
    --arg bucket "$BUCKET" --arg ssm "$SSM_PREFIX" --arg exec "$EXEC_ROLE" --arg logs "$LOG_GROUP" '
  {
    Version: "2012-10-17",
    Statement: [
      {Sid: "EcrAuth", Effect: "Allow", Action: ["ecr:GetAuthorizationToken"], Resource: "*"},
      {Sid: "EcrPush", Effect: "Allow",
       Action: ["ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
                "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:DescribeImages"],
       Resource: "arn:aws:ecr:\($region):\($acct):repository/\($repo)"},
      {Sid: "EcsTaskDefs", Effect: "Allow",
       Action: ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition", "ecs:ListTasks", "ecs:DescribeTasks"],
       Resource: "*"},
      {Sid: "EcsRunMigration", Effect: "Allow", Action: ["ecs:RunTask"],
       Resource: "arn:aws:ecs:\($region):\($acct):task-definition/\($family):*",
       Condition: {ArnEquals: {"ecs:cluster": "arn:aws:ecs:\($region):\($acct):cluster/\($cluster)"}}},
      {Sid: "EcsService", Effect: "Allow", Action: ["ecs:UpdateService", "ecs:DescribeServices"],
       Resource: "arn:aws:ecs:\($region):\($acct):service/\($cluster)/\($service)"},
      {Sid: "PassExecRole", Effect: "Allow", Action: ["iam:PassRole"],
       Resource: "arn:aws:iam::\($acct):role/\($exec)",
       Condition: {StringEquals: {"iam:PassedToService": "ecs-tasks.amazonaws.com"}}},
      {Sid: "ReadNetwork", Effect: "Allow", Action: ["ec2:DescribeNetworkInterfaces"], Resource: "*"},
      {Sid: "SiteList", Effect: "Allow", Action: ["s3:ListBucket"], Resource: "arn:aws:s3:::\($bucket)"},
      {Sid: "SiteObjects", Effect: "Allow", Action: ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
       Resource: "arn:aws:s3:::\($bucket)/*"},
      {Sid: "ReadOutputs", Effect: "Allow", Action: ["ssm:GetParameter"],
       Resource: "arn:aws:ssm:\($region):\($acct):parameter\($ssm)/outputs"},
      {Sid: "ReadMigrationLogs", Effect: "Allow", Action: ["logs:GetLogEvents"],
       Resource: "arn:aws:logs:\($region):\($acct):log-group:\($logs):*"}
    ]
  }'
}

# Trust da role do GitHub: só o environment de deploy deste repositório.
# sub_prefix vem de repos/<owner>/<repo>/actions/oidc/customization/sub.
github_trust_policy() {
  local sub_prefix=$1
  jq -n --arg acct "$ACCOUNT_ID" --arg sub "$sub_prefix:environment:$GH_ENVIRONMENT" '
  {
    Version: "2012-10-17",
    Statement: [{
      Effect: "Allow",
      Principal: {Federated: "arn:aws:iam::\($acct):oidc-provider/token.actions.githubusercontent.com"},
      Action: "sts:AssumeRoleWithWebIdentity",
      Condition: {StringEquals: {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub": $sub
      }}
    }]
  }'
}

ecs_exec_trust_policy() {
  jq -n --arg acct "$ACCOUNT_ID" '
  {
    Version: "2012-10-17",
    Statement: [{
      Effect: "Allow",
      Principal: {Service: "ecs-tasks.amazonaws.com"},
      Action: "sts:AssumeRole",
      Condition: {StringEquals: {"aws:SourceAccount": $acct}}
    }]
  }'
}

# Leitura dos segredos do ambiente pela execution role (injeção no container).
ecs_exec_secrets_policy() {
  jq -n --arg region "$REGION" --arg acct "$ACCOUNT_ID" --arg ssm "$SSM_PREFIX" '
  {
    Version: "2012-10-17",
    Statement: [{
      Effect: "Allow",
      Action: ["ssm:GetParameters"],
      Resource: [
        "arn:aws:ssm:\($region):\($acct):parameter\($ssm)/db-password",
        "arn:aws:ssm:\($region):\($acct):parameter\($ssm)/jwt-secret"
      ]
    }]
  }'
}

# Leitura pública só dos objetos do site.
site_bucket_policy() {
  jq -n --arg bucket "$BUCKET" '
  {
    Version: "2012-10-17",
    Statement: [{
      Sid: "PublicReadSite", Effect: "Allow", Principal: "*",
      Action: "s3:GetObject", Resource: "arn:aws:s3:::\($bucket)/*"
    }]
  }'
}
