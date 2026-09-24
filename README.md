# Registro App

Aplicação simples de login e registro.

- **API**: Node.js + Express, senhas com bcrypt, autenticação via JWT
- **Banco**: PostgreSQL 16
- **Front**: HTML/CSS/JS puro servido por nginx (faz proxy de `/api` para a API)

## Rodando

```bash
docker compose up --build
```

- Front: http://localhost:8080
- API: http://localhost:3000

Para customizar credenciais/segredo, copie `.env.example` para `.env` e ajuste.

## Endpoints

| Método | Rota            | Corpo                         | Descrição                        |
|--------|-----------------|-------------------------------|----------------------------------|
| POST   | `/api/register` | `{ name, email, password }`   | Cria usuário e retorna token     |
| POST   | `/api/login`    | `{ email, password }`         | Autentica e retorna token        |
| GET    | `/api/me`       | — (header `Authorization: Bearer <token>`) | Dados do usuário logado |
| GET    | `/api/health`   | —                             | Health check                     |

## Deploy na AWS (laboratório)

Decisões, custo e arquitetura: [`docs/deploy-decisions.md`](docs/deploy-decisions.md).

```bash
# Provisionamento explícito + primeira publicação (local)
scripts/deploy.sh --env lab-pedro --region sa-east-1 --account 969479836714 \
  --profile lab-pedro-deployer --github-repo pperdigo/registro_app --owner pedro

# Depois disso, cada push na main publica automaticamente (.github/workflows/pipeline.yml)

# Encerramento (apaga também os dados de teste). --yes pula a confirmação interativa.
scripts/destroy.sh --env lab-pedro --region sa-east-1 --account 969479836714 \
  --profile lab-pedro-deployer --github-repo pperdigo/registro_app
```

### Logs e recuperação

- Logs da API e das migrations: `aws logs tail /ecs/registro-lab-pedro --follow --region sa-east-1`
- Estado do rollout: `aws ecs describe-services --cluster registro-lab-pedro --services registro-lab-pedro-api --query 'services[0].deployments'`
- Deploy com falha: o circuit breaker mantém a versão anterior. Corrija e faça novo push, ou
  reexecute o workflow de um commit bom (Actions → pipeline → Run workflow).
- Migration com falha: o serviço não é atualizado. Reverter a aplicação não desfaz migrations
  nem restaura dados; escreva uma nova migration corretiva.
- Task substituída fora de um deploy (IP novo): reexecute o workflow para regenerar o `config.js`.
