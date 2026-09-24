# Decisões de deploy — ambiente `lab-pedro`

Registro para retomar o trabalho sem repetir a entrevista. Sem segredos.
Última atualização: 24/09/2026.

## Restrições confirmadas

| Item | Valor | Origem |
| --- | --- | --- |
| Conta AWS | `969479836714` | responsável |
| Região | `sa-east-1` (São Paulo) | responsável (difere da proposta `us-east-1`) |
| Ambiente / grupo | `lab-pedro` (prefixo `registro-lab-pedro-*`, tag `env=lab-pedro`) | responsável |
| Credencial local | usuário IAM `lab-pedro-deployer` (perfil `lab-pedro-deployer`); root descartado | responsável |
| Repositório | `pperdigo/registro_app` (fork; OIDC com subject imutável) | `gh api` |
| Orçamento | meta de US$ 0,50 por sessão | DEPLOY.md |
| Riscos aceitos | HTTP sem TLS com dados sintéticos; breve indisponibilidade a cada deploy | responsável |
| Encerramento | só após confirmação explícita da pessoa | DEPLOY.md |

## Fatos do código

- API: Node 22 + Express, porta 3000, health `GET /api/health`, JWT (`JWT_SECRET`), bcrypt.
- Banco: PostgreSQL 16; migrations SQL em `api/migrations`, aplicadas por `src/migrate.js`
  (transação por arquivo, tabela `schema_migrations`, idempotente).
- Conexão: `DATABASE_URL` ou variáveis `PG*`; `DB_SSL=true` usa o CA do RDS embutido na imagem.
- Frontend: HTML/CSS/JS sem build. URL da API vem de `config.js` (gerado no deploy).
- Sem uploads, WebSockets ou tarefas em segundo plano. Uso: poucas pessoas, sem pico.

## Arquitetura

- ECS Fargate: 1 task, 0,25 vCPU / 512 MiB, x86_64, sub-rede pública com IPv4 público, porta 3000.
  Circuit breaker com rollback; health check do container.
- RDS PostgreSQL 16 `db.t4g.micro`, Single-AZ, 20 GiB gp3 criptografado, privado,
  retenção de backup 0, acesso só pelo SG das tasks.
- S3 Static Website Hosting (HTTP), ACLs bloqueadas, leitura pública só `s3:GetObject`,
  `Cache-Control: no-cache`.
- ECR privado com tags imutáveis (tag = commit); deploy usa o digest.
- Segredos: SSM Parameter Store SecureString (`/registro/lab-pedro/db-password`, `jwt-secret`).
- Logs: CloudWatch `/ecs/registro-lab-pedro`, retenção de 1 dia.
- Sem ALB, NAT, API Gateway, CloudFront, Route 53 (custo/bloqueio de conta nova).

## CI/CD

- `.github/workflows/pipeline.yml`: PR e push na `main` → lint (ESLint), formatação (Prettier),
  testes da API e do frontend (node:test + jsdom), integração com PostgreSQL descartável,
  `bash -n` + `shellcheck` + `scripts/test-policies.sh`, build e checagem da imagem.
- Deploy só na `main`, depois de todos os jobs, no environment `lab`, com OIDC e concorrência única.
- A role do GitHub (`registro-lab-pedro-github-deploy`) só publica: não cria infraestrutura.
- Provisionamento inicial: explícito, local, `scripts/deploy.sh` sem `--release-only`.
- Mudanças só em `docs/` ou `*.md` pulam o deploy, mas não as validações.
- Não se aplica: verificação de tipos (JavaScript sem TypeScript; coberto por ESLint e testes);
  build do frontend (arquivos estáticos; o deploy só gera `config.js`).

## Custo estimado (AWS Price List API, sa-east-1, 24/09/2026)

| Recurso | Tarifa | US$/h |
| --- | --- | --- |
| Fargate 0,25 vCPU + 0,5 GB | 0,0696 vCPU-h, 0,0076 GB-h | 0,0212 |
| RDS db.t4g.micro Single-AZ | 0,034/h | 0,0340 |
| RDS gp3 20 GiB | 0,219 GB-mês | 0,0060 |
| IPv4 público | 0,005/h | 0,0050 |
| ECR, S3, Logs (0,90/GB ingerido), SSM Standard | uso mínimo | < 0,01 total |
| **Total** | | **≈ 0,066** |

2 h ≈ US$ 0,13; com margem (3 h, migrations, sobreposição de tasks) ≈ US$ 0,20; 24 h ≈ US$ 1,59.
Não inclui GitHub Actions nem o agente de IA. Alerta de orçamento não desliga recursos.

## Pendências e hipóteses

- A task nova tem outro IP: se o ECS substituir a task fora de um deploy, o site só volta a
  achar a API após nova execução do pipeline (`workflow_dispatch`).
- Após o laboratório: remover o usuário IAM `lab-pedro-deployer` e sua chave (manual, fora do destroy.sh).
