# Aucta CRM — Servidor MCP

Servidor [MCP](https://modelcontextprotocol.io) (FastMCP) que permite conectar
assistentes de IA (ChatGPT, Claude etc.) ao Aucta CRM, com acesso **somente leitura** e
restrito a **admins** de lojas que habilitaram a integração.

Especificação completa: [docs/spec-v1.md](docs/spec-v1.md).

## Como funciona a segurança

- Login via OAuth 2.1 do Supabase Auth (`SupabaseProvider`). O token é validado pelo JWKS do projeto.
- Toda consulta ao banco usa o **JWT do próprio usuário** (`apikey` anon + `Bearer`).
  Este serviço **não** tem `service_role`.
- `AccessMiddleware` bloqueia quem não é admin, loja inativa ou loja sem o MCP habilitado,
  e esconde as ferramentas de conteúdo de chat quando a loja não permite.
- As funções SQL `mcp_*` repetem a checagem (`mcp_exigir_admin`).
- Toda chamada é registrada em `mcp_audit_log`.

## Setup local

```bash
uv sync
cp .env.example .env   # preencher SUPABASE_ANON_KEY
uv run uvicorn app.main:app --reload --port 8000
```

- Health check: `GET /health`
- Endpoint MCP: `POST /mcp` (Streamable HTTP, exige token)

## Testes

```bash
uv run pytest
```

## Banco

As migrations ficam em `supabase/migrations/` e são aplicadas manualmente no Supabase.
Para habilitar uma loja (até a tela do CRM existir):

```sql
insert into mcp_empresa_config (empresa_id, habilitado)
values ('<empresa_id>', true)
on conflict (empresa_id) do update set habilitado = excluded.habilitado, updated_at = now();
```

## Deploy (Easypanel)

App a partir do `Dockerfile`, porta 8000, domínio `mcp.auctatech.com.br` com HTTPS.
Variáveis: ver `.env.example` (`BASE_URL=https://mcp.auctatech.com.br`).

O OAuth só funciona depois dos pré-requisitos da fase 0 (chaves JWT ES256, OAuth Server e
DCR habilitados, tela `/oauth/consent` no CRM). Ver spec, seção 3.2.
